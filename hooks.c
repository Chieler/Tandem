#define _DARWIN_C_SOURCE
#define _GNU_SOURCE
#include "hooks.h"
#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#ifdef __APPLE__
#include <mach-o/dyld.h>
#endif

static const char *string_field(json_object *input, const char *key) {
    json_object *v = NULL;
    return input && json_object_object_get_ex(input, key, &v) && json_object_is_type(v, json_type_string) ? json_object_get_string(v) : "";
}
static int int_field(json_object *input, const char *key) {
    json_object *v = NULL;
    return input && json_object_object_get_ex(input, key, &v) ? json_object_get_int(v) : 0;
}
int hook_parse(const char *harness, const char *event, json_object *input, struct hook_event *out) {
    int codex = !strcmp(harness, "codex"), claude = !strcmp(harness, "claude") || codex, agy = !strcmp(harness, "agy");
    if ((!claude && !agy) || !input || !json_object_is_type(input, json_type_object)) return 0;
    const char *const c[] = {"SessionStart", "UserPromptSubmit", "Stop", "PermissionRequest", "PostToolUse", "PreToolUse", NULL};
    const char *const a[] = {"SessionStart", "PreInvocation", "Stop", "PostToolUse", NULL};
    const char *const x[] = {"UserPromptSubmit", "Stop", NULL};
    const char *const *allowed = codex ? x : claude ? c : a;
    int known = 0;
    for (int i = 0; allowed[i]; i++) if (!strcmp(allowed[i], event)) known = 1;
    if (!known) return 0;
    out->session = string_field(input, claude ? "session_id" : "conversationId");
    out->kind = event;
    out->prompt = string_field(input, claude ? "prompt" : "lastUserInput");
    out->reason = agy ? string_field(input, "terminationReason") : "";
    out->loop = claude ? int_field(input, "stop_hook_active") != 0 :
        (!strcmp(event, "PreInvocation") ? int_field(input, "invocationNum") > 0 : int_field(input, "executionNum") > 0);
    return *out->session != 0;
}
json_object *hook_answer(const char *harness, const char *event, enum hook_answer_kind kind, const char *text) {
    json_object *out = json_object_new_object();
    int codex = !strcmp(harness, "codex"), claude = !strcmp(harness, "claude") || codex, agy = !strcmp(harness, "agy");
    if ((!claude && !agy) || !text || kind == HOOK_NEUTRAL) return out;
    if (kind == HOOK_BLOCK && !strcmp(event, "Stop")) {
        json_object_object_add(out, "decision", json_object_new_string(claude ? "block" : "continue"));
        json_object_object_add(out, "reason", json_object_new_string(text));
    } else if (kind == HOOK_ATTACH && claude && ((!codex && !strcmp(event, "SessionStart")) || !strcmp(event, "UserPromptSubmit"))) {
        json_object *specific = json_object_new_object();
        json_object_object_add(specific, "hookEventName", json_object_new_string(event));
        json_object_object_add(specific, "additionalContext", json_object_new_string(text));
        json_object_object_add(out, "hookSpecificOutput", specific);
    } else if (kind == HOOK_ATTACH && agy && (!strcmp(event, "SessionStart") || !strcmp(event, "PreInvocation"))) {
        json_object *array = json_object_new_array(), *step = json_object_new_object(), *message = json_object_new_object();
        json_object_object_add(message, "systemMessage", json_object_new_string(text));
        json_object_object_add(step, "systemMessage", message);
        json_object_array_add(array, step);
        json_object_object_add(out, "injectSteps", array);
    }
    if (strlen(json_object_to_json_string_ext(out, JSON_C_TO_STRING_PLAIN)) > (claude ? 8192U : 40960U)) {
        json_object_put(out);
        return json_object_new_object();
    }
    return out;
}

/* ---- cntctr hooks install | remove | status (H10) ---- */

struct target { const char *name, *rel; const char *const *events; };
static const char *const CLAUDE_EVENTS[] = {"SessionStart", "UserPromptSubmit", "Stop", "PermissionRequest", "PostToolUse", NULL};
static const char *const CODEX_EVENTS[] = {"UserPromptSubmit", "Stop", NULL};
static const char *const AGY_EVENTS[] = {"PreInvocation", "Stop", NULL};   /* never PreToolUse: a hook printing {} denies every tool */
static const struct target TARGETS[] = {
    {"claude", ".claude/settings.json", CLAUDE_EVENTS},
    {"codex", ".codex/hooks.json", CODEX_EVENTS},
    {"agy", ".gemini/config/hooks.json", AGY_EVENTS},
};

static int self_path(char *out) {
    char raw[PATH_MAX];
#ifdef __APPLE__
    uint32_t n = sizeof raw;
    if (_NSGetExecutablePath(raw, &n)) return 0;
#else
    ssize_t n = readlink("/proc/self/exe", raw, sizeof raw - 1);
    if (n <= 0) return 0;
    raw[n] = 0;
#endif
    return realpath(raw, out) != NULL;
}

static char *quoted(const char *s) {
    int safe = *s != 0;
    for (const char *p = s; *p; p++) if (!isalnum((unsigned char)*p) && !strchr("/._-+=:,@%", *p)) safe = 0;
    if (safe) return strdup(s);
    char *out = malloc(strlen(s) * 4 + 3), *w = out;
    if (!out) return NULL;
    *w++ = '\'';
    for (const char *p = s; *p; p++) { if (*p == '\'') { memcpy(w, "'\\''", 4); w += 4; } else *w++ = *p; }
    *w++ = '\'';
    *w = 0;
    return out;
}

static char *command_for(const char *self, const char *harness, const char *event) {
    char *q = quoted(self), *out = NULL;
    if (q && asprintf(&out, "%s hook %s %s", q, harness, event) < 0) out = NULL;
    free(q);
    return out;
}

/* 1 when cmd is exactly `<absolute path ending in /cntctr> hook <harness> <event>`; the path goes to path[PATH_MAX]. */
static int parse_cmd(const char *cmd, const char *harness, const char *event, char *path) {
    size_t n = 0;
    const char *p = cmd;
    int closed = 1;
    if (*p == '\'') {
        closed = 0;
        for (p++; *p && n < PATH_MAX - 1; ) {
            if (*p == '\'') {
                if (!strncmp(p, "'\\''", 4)) { path[n++] = '\''; p += 4; }
                else { p++; closed = 1; break; }
            } else path[n++] = *p++;
        }
    } else while (*p && *p != ' ' && n < PATH_MAX - 1) path[n++] = *p++;
    path[n] = 0;
    char want[128];
    snprintf(want, sizeof want, " hook %s %s", harness, event);
    return closed && n >= 8 && path[0] == '/' && !strcmp(path + n - 7, "/cntctr") && !strcmp(p, want);
}

/* 0 read, 1 missing, -1 error */
static int read_file(const char *path, char **data, size_t *len) {
    FILE *f = fopen(path, "rb");
    if (!f) return errno == ENOENT ? 1 : -1;
    size_t cap = 4096, n = 0, got;
    char *buf = malloc(cap);
    while (buf && (got = fread(buf + n, 1, cap - n, f)) > 0) {
        n += got;
        if (n == cap) { if (cap >= (size_t)8 << 20) { n = 0; free(buf); buf = NULL; break; } buf = realloc(buf, cap *= 2); }
    }
    int bad = ferror(f) || !buf;
    fclose(f);
    if (bad) { free(buf); return -1; }
    *data = buf; *len = n;
    return 0;
}

static json_object *parse_strict(const char *data, size_t n) {
    json_tokener *tok = json_tokener_new();
    if (!tok) return NULL;
    json_tokener_set_flags(tok, JSON_TOKENER_STRICT);
    json_object *obj = n < INT_MAX ? json_tokener_parse_ex(tok, data, (int)n) : NULL;
    size_t end = json_tokener_get_parse_end(tok);
    while (end < n && isspace((unsigned char)data[end])) end++;
    if (json_tokener_get_error(tok) != json_tokener_success || end != n || !obj || !json_object_is_type(obj, json_type_object)) {
        if (obj) json_object_put(obj);
        obj = NULL;
    }
    json_tokener_free(tok);
    return obj;
}

enum sweep_mode { SWEEP_INSTALL, SWEEP_REMOVE, SWEEP_STATUS };
struct sweep { const struct target *t; enum sweep_mode mode; const char *self; int seen[8], changed; char path[PATH_MAX]; };

static int wanted_index(const struct sweep *s, const char *event) {
    for (int i = 0; s->t->events[i]; i++) if (!strcmp(s->t->events[i], event)) return i;
    return -1;
}

/* 1 when the command object is to be deleted */
static int sweep_entry(struct sweep *s, const char *event, json_object *c) {
    json_object *cmd;
    char path[PATH_MAX];
    if (!json_object_is_type(c, json_type_object) || !json_object_object_get_ex(c, "command", &cmd) || !json_object_is_type(cmd, json_type_string)) return 0;
    if (!parse_cmd(json_object_get_string(cmd), s->t->name, event, path)) return 0;
    int w = s->mode == SWEEP_REMOVE ? -1 : wanted_index(s, event);
    if (s->mode == SWEEP_STATUS) {
        if (w >= 0) s->seen[w] = 1;
        if (!*s->path) snprintf(s->path, sizeof s->path, "%s", path);
        return 0;
    }
    if (w < 0 || s->seen[w]) { s->changed = 1; return 1; }   /* removed, not wanted for this harness, or a duplicate */
    s->seen[w] = 1;
    if (strcmp(path, s->self)) {
        char *fresh = command_for(s->self, s->t->name, event);
        if (fresh) json_object_object_add(c, "command", json_object_new_string(fresh));
        free(fresh);
        s->changed = 1;
    }
    return 0;
}

static void sweep_array(struct sweep *s, const char *event, json_object *arr) {
    for (int i = (int)json_object_array_length(arr) - 1; i >= 0; i--) {
        json_object *elem = json_object_array_get_idx(arr, i), *inner;
        if (json_object_is_type(elem, json_type_object) && json_object_object_get_ex(elem, "hooks", &inner) && json_object_is_type(inner, json_type_array)) {
            size_t before = json_object_array_length(inner);
            for (int j = (int)before - 1; j >= 0; j--)
                if (sweep_entry(s, event, json_object_array_get_idx(inner, (size_t)j))) json_object_array_del_idx(inner, (size_t)j, 1);
            if (before && !json_object_array_length(inner)) json_object_array_del_idx(arr, (size_t)i, 1);
        } else if (sweep_entry(s, event, elem)) json_object_array_del_idx(arr, (size_t)i, 1);
    }
}

/* Visit every event array of an object keyed by event; drop keys that this sweep emptied. */
static void sweep_events(struct sweep *s, json_object *obj) {
    char *dead[64];
    int nd = 0;
    json_object_object_foreach(obj, key, val) {
        if (!json_object_is_type(val, json_type_array)) continue;
        size_t before = json_object_array_length(val);
        sweep_array(s, key, val);
        if (before && !json_object_array_length(val) && nd < 64) dead[nd++] = strdup(key);
    }
    for (int i = 0; i < nd; i++) { if (dead[i]) json_object_object_del(obj, dead[i]); free(dead[i]); }
}

static void sweep_root(struct sweep *s, json_object *root) {
    json_object *hooks;
    if (strcmp(s->t->name, "agy")) {
        if (json_object_object_get_ex(root, "hooks", &hooks) && json_object_is_type(hooks, json_type_object)) sweep_events(s, hooks);
        return;
    }
    char *dead[64];
    int nd = 0;
    json_object_object_foreach(root, key, val) {   /* agy: named hooks, each keyed by event */
        if (!json_object_is_type(val, json_type_object)) continue;
        size_t before = json_object_object_length(val);
        sweep_events(s, val);
        if (before && !json_object_object_length(val) && nd < 64) dead[nd++] = strdup(key);
    }
    for (int i = 0; i < nd; i++) { if (dead[i]) json_object_object_del(root, dead[i]); free(dead[i]); }
}

static json_object *child(json_object *parent, const char *key, json_type type) {
    json_object *v;
    if (json_object_object_get_ex(parent, key, &v)) return json_object_is_type(v, type) ? v : NULL;
    v = type == json_type_array ? json_object_new_array() : json_object_new_object();
    json_object_object_add(parent, key, v);
    return v;
}

/* 0 ok, -1 when the file's own structure is in the way */
static int add_missing(struct sweep *s, json_object *root) {
    int codex = !strcmp(s->t->name, "codex"), claude = strcmp(s->t->name, "agy") != 0;
    json_object *top = child(root, claude ? "hooks" : "cntctr", json_type_object);
    for (int i = 0; s->t->events[i]; i++) {
        if (s->seen[i]) continue;
        json_object *arr = top ? child(top, s->t->events[i], json_type_array) : NULL;
        char *cmd = command_for(s->self, s->t->name, s->t->events[i]);
        if (!arr || !cmd) { free(cmd); return -1; }
        json_object *entry = json_object_new_object();
        json_object_object_add(entry, "type", json_object_new_string("command"));
        json_object_object_add(entry, "command", json_object_new_string(cmd));
        if (codex) json_object_object_add(entry, "timeout", json_object_new_int(5));
        free(cmd);
        if (claude) {
            json_object *group = json_object_new_object(), *list = json_object_new_array();
            json_object_array_add(list, entry);
            json_object_object_add(group, "hooks", list);
            entry = group;
        }
        json_object_array_add(arr, entry);
        s->changed = 1;
    }
    return 0;
}

static char *render(json_object *root) {
    char *out = NULL;
    if (asprintf(&out, "%s\n", json_object_to_json_string_ext(root, JSON_C_TO_STRING_PRETTY | JSON_C_TO_STRING_NOSLASHESCAPE)) < 0) out = NULL;
    return out;
}

static void mkdirs(char *path) {
    for (char *p = path + 1; *p; p++)
        if (*p == '/') { *p = 0; mkdir(path, 0755); *p = '/'; }
}

static int write_all(int fd, const char *data, size_t n) {
    while (n) { ssize_t w = write(fd, data, n); if (w <= 0) return -1; data += w; n -= (size_t)w; }
    return 0;
}

/* Rename a temporary file over target only when target still holds what was read. */
static int write_atomic(const char *target, const char *orig, size_t orig_n, int existed, int backup, const char *text) {
    const char *pause = getenv("CNTCTR_HOOKS_PAUSE_MS");   /* test hook: widens the read-to-write window */
    if (pause && atoi(pause) > 0) { fprintf(stderr, "hooks: paused\n"); fflush(stderr); usleep((useconds_t)atoi(pause) * 1000); }
    char *now = NULL;
    size_t now_n = 0;
    int st = read_file(target, &now, &now_n);
    int same = existed ? st == 0 && now_n == orig_n && !memcmp(now, orig, orig_n) : st == 1;
    free(now);
    if (!same) { fprintf(stderr, "%s changed while cntctr was working; not overwritten, run the command again\n", target); return 1; }
    struct stat sb;
    mode_t mode = existed && stat(target, &sb) == 0 ? sb.st_mode & 07777 : 0600;
    char tmp[PATH_MAX + 32];
    if (!existed) { snprintf(tmp, sizeof tmp, "%s", target); mkdirs(tmp); }
    if (existed && backup) {
        snprintf(tmp, sizeof tmp, "%s.cntctr-backup", target);
        int fd = open(tmp, O_WRONLY | O_CREAT | O_EXCL, mode);   /* an existing backup is never overwritten */
        if (fd >= 0) {
            int bad = write_all(fd, orig, orig_n);
            if (close(fd) || bad) { unlink(tmp); fprintf(stderr, "cannot write %s\n", tmp); return 1; }
        } else if (errno != EEXIST) { fprintf(stderr, "cannot write %s: %s\n", tmp, strerror(errno)); return 1; }
    }
    snprintf(tmp, sizeof tmp, "%s.cntctr-tmp.%ld", target, (long)getpid());
    int fd = open(tmp, O_WRONLY | O_CREAT | O_EXCL, 0600);
    if (fd < 0 || write_all(fd, text, strlen(text)) || fsync(fd) || fchmod(fd, mode) || close(fd) || rename(tmp, target)) {
        fprintf(stderr, "cannot write %s: %s\n", target, strerror(errno));
        if (fd >= 0) close(fd);
        unlink(tmp);
        return 1;
    }
    return 0;
}

static void print_by_hand(const struct target *t, const char *self, int install) {
    if (!install) { fprintf(stderr, "remove the cntctr hook entries from it by hand\n"); return; }
    struct sweep s = {.t = t, .mode = SWEEP_INSTALL, .self = self};
    json_object *root = json_object_new_object();
    if (add_missing(&s, root) == 0) {
        char *text = render(root);
        printf("add these entries by hand:\n%s", text ? text : "");
        free(text);
    }
    json_object_put(root);
}

static int edit(const struct target *t, const char *home, const char *self, int install) {
    char path[PATH_MAX], real[PATH_MAX];
    snprintf(path, sizeof path, "%s/%s", home, t->rel);
    const char *target = realpath(path, real) ? real : path;   /* a symlinked file is edited in place */
    char *data = NULL;
    size_t n = 0;
    int st = read_file(target, &data, &n);
    if (st < 0) { fprintf(stderr, "cannot read %s: %s\n", target, strerror(errno)); return 1; }
    if (st == 1 && !install) { printf("%s: nothing to remove, %s does not exist\n", t->name, target); return 0; }
    json_object *root = st == 1 ? json_object_new_object() : parse_strict(data, n);
    if (!root) {
        fprintf(stderr, "%s is not strict JSON (comments, trailing commas, other extensions or not an object); not touched\n", target);
        print_by_hand(t, self, install);
        free(data);
        return 1;
    }
    struct sweep s = {.t = t, .mode = install ? SWEEP_INSTALL : SWEEP_REMOVE, .self = self};
    sweep_root(&s, root);
    if (install && add_missing(&s, root)) {
        fprintf(stderr, "%s has a structure cntctr cannot extend; not touched\n", target);
        print_by_hand(t, self, 1);
        json_object_put(root); free(data);
        return 1;
    }
    int rc = 0;
    if (!s.changed) printf("%s: %s is already %s\n", t->name, target, install ? "installed" : "free of cntctr hooks");
    else {
        char *text = render(root);
        rc = text ? write_atomic(target, data, n, st == 0, install, text) : 1;
        free(text);
        if (!rc) printf("%s: %s %s\n", t->name, install ? "installed in" : "removed from", target);
    }
    json_object_put(root);
    free(data);
    return rc;
}

static void status_one(const struct target *t, const char *home, const char *self, int (*seen)(const char *harness)) {
    char path[PATH_MAX], *data = NULL;
    size_t n = 0;
    snprintf(path, sizeof path, "%s/%s", home, t->rel);
    int st = read_file(path, &data, &n);
    struct sweep s = {.t = t, .mode = SWEEP_STATUS, .self = self};
    json_object *root = st == 0 ? parse_strict(data, n) : NULL;
    if (root) sweep_root(&s, root);
    char missing[128] = "";
    int have = 0;
    for (int i = 0; t->events[i]; i++) {
        if (s.seen[i]) have++;
        else { strncat(missing, *missing ? ", " : "", sizeof missing - strlen(missing) - 1); strncat(missing, t->events[i], sizeof missing - strlen(missing) - 1); }
    }
    printf("%s: installed %s", t->name, st == 0 && !root ? "unknown (file is not strict JSON)" : have == 0 ? "no" : *missing ? "no" : "yes");
    if (have && *missing) printf(" (missing: %s)", missing);
    printf("; seen running %s; binary ", seen && seen(t->name) ? "yes" : "no");
    if (!*s.path) puts("none");
    else {
        char a[PATH_MAX], b[PATH_MAX];
        int same = realpath(s.path, a) && realpath(self, b) ? !strcmp(a, b) : !strcmp(s.path, self);
        printf("%s (%sthis binary)\n", s.path, same ? "" : "not ");
    }
    if (root) json_object_put(root);
    free(data);
}

int hooks_admin(int argc, char **argv, int (*seen)(const char *harness)) {
    const char *verb = argc > 2 ? argv[2] : "", *harness = argc > 3 ? argv[3] : "";
    int status = !strcmp(verb, "status"), install = !strcmp(verb, "install");
    if (!status && !install && strcmp(verb, "remove")) { fprintf(stderr, "usage: cntctr hooks install|remove claude|agy|codex | cntctr hooks status\n"); return 2; }
    const char *home = getenv("HOME");
    if (!home || *home != '/') { fprintf(stderr, "HOME is not set to an absolute path\n"); return 1; }
    char self[PATH_MAX] = "";
    int have_self = self_path(self);
    if (status) {
        for (size_t i = 0; i < sizeof TARGETS / sizeof *TARGETS; i++) status_one(&TARGETS[i], home, have_self ? self : "", seen);
        return 0;
    }
    const struct target *t = NULL;
    for (size_t i = 0; i < sizeof TARGETS / sizeof *TARGETS; i++) if (!strcmp(TARGETS[i].name, harness)) t = &TARGETS[i];
    if (!t || argc != 4) { fprintf(stderr, "usage: cntctr hooks install|remove claude|agy|codex\n"); return 2; }
    size_t n = strlen(self);
    if (install && (!have_self || n < 8 || strcmp(self + n - 7, "/cntctr"))) {
        fprintf(stderr, "cntctr hooks install: the running binary (%s) must be named cntctr, or remove could not recognise its entries\n", have_self ? self : "unknown path");
        return 1;
    }
    int rc = edit(t, home, self, install);
    if (!rc && install && !strcmp(harness, "codex")) printf("Start codex once and trust the cntctr hooks on the Hooks need review screen.\n");
    return rc;
}
