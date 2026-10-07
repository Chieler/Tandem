/* cntctr: MCP stdio server that lets terminal agents (Claude Code, Codex, agy)
 * spawn, message, and reply to each other. All state lives in the tmux
 * server; this process keeps none between tool calls. */
#define _DARWIN_C_SOURCE
#define _GNU_SOURCE
#include <errno.h>
#include <ctype.h>
#include <fcntl.h>
#include <poll.h>
#include <pthread.h>
#include <regex.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
#include <json-c/json.h>
#include "kb.h"

static pthread_mutex_t out_mu = PTHREAD_MUTEX_INITIALIZER;   /* one JSON line at a time on stdout */
static pthread_mutex_t live_mu = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t live_cv = PTHREAD_COND_INITIALIZER;

/* A running tools/call. The client can cancel it; so does stdin EOF. */
struct call { json_object *req, *id; int cancelled; struct call *next; };
static struct call *calls;                                    /* guarded by live_mu */
static _Thread_local struct call *this_call;

/* Mark the call with JSON-RPC id `id` cancelled, or every call if `id` is NULL. */
static void cancel(json_object *id) {
    pthread_mutex_lock(&live_mu);
    for (struct call *c = calls; c; c = c->next)
        if (!id || json_object_equal(c->id, id)) c->cancelled = 1;
    pthread_mutex_unlock(&live_mu);
}

static int cancelled(void) {
    pthread_mutex_lock(&live_mu);
    int v = this_call && this_call->cancelled;
    pthread_mutex_unlock(&live_mu);
    return v;
}

static char client_name[64] = "agent";   /* clientInfo.name from initialize */
static char self_pane[32];               /* our tmux pane id, e.g. "%3"; empty outside tmux */
static char self_name[128];              /* our agent name (the pane's @cntctr_name) */
/* Who the current tool call is from: self_*, or the `from` argument when one shared
 * server (Codex) serves many panes. Set per call in dispatch. */
static _Thread_local char caller_pane[32], caller_name[128];
static pthread_mutex_t fork_mu = PTHREAD_MUTEX_INITIALIZER;   /* held from pipe() to fork() */

static char *fmt(const char *f, ...) {
    va_list ap;
    char *s;
    va_start(ap, f);
    if (vasprintf(&s, f, ap) < 0) abort();
    va_end(ap);
    return s;
}

/* Tool results: *res gets malloc'd text; the return value is MCP's isError. */
static int fail(char **res, char *text) { *res = text; return 1; }
static int ok(char **res, char *text) { *res = text; return 0; }

static const char *sarg(json_object *o, const char *key) {
    json_object *v;
    return json_object_object_get_ex(o, key, &v) && json_object_is_type(v, json_type_string)
        ? json_object_get_string(v) : NULL;
}

static int barg(json_object *o, const char *key) {
    json_object *v;
    return json_object_object_get_ex(o, key, &v) && json_object_get_boolean(v);
}

/* Blocking-wait timeout in seconds: default 600, clamped to 1 s .. 1 day. */
static int targ(json_object *o) {
    json_object *v;
    int t = json_object_object_get_ex(o, "timeout", &v) ? json_object_get_int(v) : 600;
    return t < 1 ? 1 : t > 86400 ? 86400 : t;
}

/* ---- processes ---- */

/* Close-on-exec pipe, so children forked by other threads don't inherit it and
 * hold our read ends open. Callers hold fork_mu until they have forked. */
static int cloexec_pipe(int p[2]) {
    if (pipe(p) < 0) return -1;
    fcntl(p[0], F_SETFD, FD_CLOEXEC);
    fcntl(p[1], F_SETFD, FD_CLOEXEC);
    return 0;
}

/* Fork and exec argv with stdin from `in` and stdout+stderr to `out` (-1 means
 * /dev/null). No shell is involved. Caller holds fork_mu. */
static pid_t start(const char **argv, int in, int out) {
    pid_t pid = fork();
    if (pid == 0) {
        int null = open("/dev/null", O_RDWR);
        dup2(in < 0 ? null : in, 0);
        dup2(out < 0 ? null : out, 1);
        dup2(out < 0 ? null : out, 2);
        execvp(argv[0], (char *const *)argv);
        _exit(127);
    }
    return pid;
}

static int reap(pid_t pid) {
    int status;
    while (waitpid(pid, &status, 0) < 0)
        if (errno != EINTR) return -1;
    return WIFEXITED(status) ? WEXITSTATUS(status) : -1;
}

static void write_all(int fd, const char *s) {
    size_t n = strlen(s);
    while (n > 0) {
        ssize_t w = write(fd, s, n);
        if (w < 0 && errno == EINTR) continue;
        if (w < 0) return;
        s += w;
        n -= (size_t)w;
    }
}

static char *read_all(int fd) {
    size_t len = 0, cap = 256;
    char *b = malloc(cap);
    for (;;) {
        if (cap - len < 2) b = realloc(b, cap *= 2);
        ssize_t n = read(fd, b + len, cap - len - 1);
        if (n > 0) len += (size_t)n;
        else if (n < 0 && errno == EINTR) continue;
        else break;
    }
    while (len > 0 && b[len - 1] == '\n') len--;
    b[len] = '\0';
    return b;
}

/* Run argv, feeding `in` (may be NULL) on stdin. *out gets stdout+stderr
 * (always malloc'd, trailing newlines dropped). Returns the exit status. */
static int run(const char *in, char **out, const char **argv) {
    int ip[2], op[2];
    pthread_mutex_lock(&fork_mu);
    if (cloexec_pipe(ip) < 0) {
        pthread_mutex_unlock(&fork_mu);
        *out = fmt("pipe: %s", strerror(errno));
        return -1;
    }
    if (cloexec_pipe(op) < 0) {
        pthread_mutex_unlock(&fork_mu);
        close(ip[0]);
        close(ip[1]);
        *out = fmt("pipe: %s", strerror(errno));
        return -1;
    }
    pid_t pid = start(argv, ip[0], op[1]);
    pthread_mutex_unlock(&fork_mu);
    close(ip[0]);
    close(op[1]);
    if (pid < 0) {
        close(ip[1]);
        close(op[0]);
        *out = fmt("fork: %s", strerror(errno));
        return -1;
    }
    if (in) write_all(ip[1], in);
    close(ip[1]);
    *out = read_all(op[0]);
    close(op[0]);
    int rc = reap(pid);
    if (rc == 127 && !**out) {
        free(*out);
        *out = fmt("cannot run %s", argv[0]);
    }
    return rc;
}

/* Run a tmux command: NULL on success, else its error text (caller frees). */
static char *tmux_do(const char *in, const char **argv) {
    char *out;
    if (run(in, &out, argv) == 0) {
        free(out);
        return NULL;
    }
    return out;
}

#define TMUX(in, out, ...) run((in), (out), (const char *[]){"tmux", __VA_ARGS__, NULL})
#define TMUXE(in, ...) tmux_do((in), (const char *[]){"tmux", __VA_ARGS__, NULL})

/* ---- identity ---- */

/* If `pid` is the root process of a pane in `panes` ("pid pane_id" lines), make it ours. */
static int match_pane(const char *panes, long pid) {
    long p;
    char id[32];
    int n;
    for (const char *s = panes; sscanf(s, "%ld %31s%n", &p, id, &n) == 2; s += n)
        if (p == pid) {
            snprintf(self_pane, sizeof self_pane, "%s", id);
            return 1;
        }
    return 0;
}

/* Parent of `pid` according to `procs` ("pid ppid" lines), or 0. */
static long parent_of(const char *procs, long pid) {
    long p, pp;
    int n;
    for (const char *s = procs; sscanf(s, "%ld %ld%n", &p, &pp, &n) == 2; s += n)
        if (p == pid) return pp;
    return 0;
}

/* Find our pane: $TMUX_PANE, else the nearest ancestor process that is a pane's
 * root process (Codex hides TMUX_PANE from MCP servers). Then take our name from
 * the pane's tag, tagging an untagged pane (e.g. a leader the user started by
 * hand) as <client>-<pane number>. */
static void find_self(void) {
    const char *env = getenv("TMUX_PANE");
    if (env && *env) {
        snprintf(self_pane, sizeof self_pane, "%s", env);
    } else {
        char *panes, *procs;
        int found = TMUX(NULL, &panes, "list-panes", "-a", "-F", "#{pane_pid} #{pane_id}") == 0;
        found = run(NULL, &procs, (const char *[]){"ps", "-A", "-o", "pid=,ppid=", NULL}) == 0 && found;
        for (long pid = getpid(); found && pid > 1 && !match_pane(panes, pid); pid = parent_of(procs, pid)) {}
        free(panes);
        free(procs);
    }
    if (!*self_pane) return;

    char *name;
    if (TMUX(NULL, &name, "show", "-pqv", "-t", self_pane, "@cntctr_name") == 0 && *name) {
        snprintf(self_name, sizeof self_name, "%s", name);
    } else {
        snprintf(self_name, sizeof self_name, "%s-%s", client_name, self_pane + 1);
        free(TMUXE(NULL, "set", "-p", "-t", self_pane, "@cntctr_name", self_name));
        free(TMUXE(NULL, "set", "-p", "-t", self_pane, "@cntctr_harness", client_name));
    }
    free(name);
}

/* ---- knowledge ---- */

static sqlite3 *kb(char **err) {
    const char *path = getenv("CNTCTR_DB"), *home = getenv("HOME");
    char def[4096];
    if (!path || !*path) {
        home = home ? home : ".";
        snprintf(def, sizeof def, "%s/.local", home);
        mkdir(def, 0755);
        snprintf(def, sizeof def, "%s/.local/share", home);
        mkdir(def, 0755);
        snprintf(def, sizeof def, "%s/.local/share/cntctr", home);
        mkdir(def, 0700);
        snprintf(def, sizeof def, "%s/.local/share/cntctr/kb.db", home);
        path = def;
    }
    char *why = NULL;
    sqlite3 *db = kb_open(path, &why);
    if (!db) *err = fmt("knowledge store unavailable: %s", why);
    free(why);
    return db;
}

struct project { char root[4096], key[1024], base[256]; };

static void normalize_remote(const char *url, char *out, size_t n) {
    const char *s = strstr(url, "://");
    int scp = !s;
    s = s ? s + 3 : url;
    const char *at = strchr(s, '@'), *slash = strchr(s, '/');
    if (at && (!slash || at < slash)) s = at + 1;
    snprintf(out, n, "%s", s);
    char *colon = strchr(out, ':'), *sl = strchr(out, '/');
    if (scp && colon && (!sl || colon < sl)) *colon = '/';
    size_t len = strlen(out);
    while (len && out[len - 1] == '/') out[--len] = '\0';
    if (len > 4 && strcmp(out + len - 4, ".git") == 0) out[len -= 4] = '\0';
    while (len && out[len - 1] == '/') out[--len] = '\0';
    for (char *c = out; *c && *c != '/'; c++) *c = (char)tolower((unsigned char)*c);
}

static void resolve_project(sqlite3 *db, const char *pane, struct project *p) {
    char *out = NULL, cwd[4096];
    if (pane && *pane && TMUX(NULL, &out, "display", "-p", "-t", pane, "#{pane_current_path}") == 0 && *out)
        snprintf(cwd, sizeof cwd, "%s", out);
    else if (!getcwd(cwd, sizeof cwd))
        snprintf(cwd, sizeof cwd, ".");
    free(out);
    if (run(NULL, &out, (const char *[]){"git", "-C", cwd, "rev-parse", "--show-toplevel", NULL}) == 0 && *out)
        snprintf(p->root, sizeof p->root, "%s", out);
    else
        snprintf(p->root, sizeof p->root, "%s", cwd);
    free(out);
    const char *slash = strrchr(p->root, '/');
    snprintf(p->base, sizeof p->base, "%s", slash && slash[1] ? slash + 1 : p->root);
    char *key = kb_project_get(db, p->root);
    if (key) {
        snprintf(p->key, sizeof p->key, "%s", key);
        free(key);
        return;
    }
    if (run(NULL, &out, (const char *[]){"git", "-C", p->root, "remote", "get-url", "origin", NULL}) == 0 && *out)
        normalize_remote(out, p->key, sizeof p->key);
    else
        snprintf(p->key, sizeof p->key, "%s", p->root);
    free(out);
}

static char *first_line(const char *text, size_t max) {
    size_t n = strcspn(text, "\n");
    if (n > max)
        for (n = max; n > 0 && (text[n] & 0xC0) == 0x80; n--) {}
    return fmt("%.*s", (int)n, text);
}

/* The agent name of `pane` (caller frees), or NULL. */
static char *pane_name(const char *pane) {
    char *name;
    if (!pane || !*pane) return NULL;
    if (TMUX(NULL, &name, "show", "-pqv", "-t", pane, "@cntctr_name") == 0 && *name) return name;
    free(name);
    return NULL;
}

/* Log a task or reply as private history in the project of the agent in `pane`. Never fails. */
static void log_history(const char *pane, const char *title, const char *text) {
    char *err = NULL, id[64];
    sqlite3 *db = kb(&err);
    free(err);
    if (!db) return;
    struct project p;
    resolve_project(db, pane, &p);
    char *summary = first_line(text, 200);
    struct kb_entry e = {.layer = "history", .scope = p.key, .title = title, .summary = summary, .body = text,
                         .author = getenv("USER"), .agent = caller_name, .visibility = "private"};
    kb_put(db, &e, id);
    free(summary);
    sqlite3_close(db);
}

/* Up to 5 stored entries matching `text`, as an envelope block; "" if none. */
static char *knowledge_hints(const char *text) {
    char *err = NULL;
    sqlite3 *db = kb(&err);
    free(err);
    if (!db) return strdup("");
    struct project p;
    resolve_project(db, caller_pane, &p);
    char *lines = kb_search(db, p.key, "global", text, NULL, 0, 5);
    sqlite3_close(db);
    if (!*lines) return lines;
    char *block = fmt("[cntctr knowledge: call recall for more]\n%s\n", lines);
    free(lines);
    return block;
}

/* claude-mem mirror: best effort; a failure never fails the caller. */
static const char *mem_url(void) {
    const char *u = getenv("CNTCTR_MEM_URL");
    return u ? u : "http://127.0.0.1:37701";
}

/* Save an entry as a claude-mem observation under `project` (a directory basename,
 * as claude-mem names projects). Returns the observation id, or 0. */
static long long mem_save(const char *project, const char *id, const char *layer, const char *scope,
                          const char *title, const char *summary, const char *body) {
    if (!*mem_url()) return 0;
    json_object *req = json_object_new_object(), *meta = json_object_new_object(), *resp, *v;
    char *text = fmt("%s\n\n%s", summary, body ? body : ""), *url = fmt("%s/api/memory/save", mem_url()), *out;
    json_object_object_add(meta, "cntctr_id", json_object_new_string(id));
    json_object_object_add(meta, "layer", json_object_new_string(layer));
    json_object_object_add(meta, "scope", json_object_new_string(scope));
    json_object_object_add(req, "title", json_object_new_string(title));
    json_object_object_add(req, "text", json_object_new_string(text));
    json_object_object_add(req, "project", json_object_new_string(project));
    json_object_object_add(req, "metadata", meta);
    long long mem = 0;
    if (run(json_object_to_json_string_ext(req, JSON_C_TO_STRING_PLAIN | JSON_C_TO_STRING_NOSLASHESCAPE), &out,
            (const char *[]){"curl", "-s", "-m", "2", "-X", "POST", "-H", "Content-Type: application/json",
                             "--data-binary", "@-", url, NULL}) == 0 && (resp = json_tokener_parse(out))) {
        if (json_object_object_get_ex(resp, "id", &v)) mem = json_object_get_int64(v);
        json_object_put(resp);
    }
    free(out);
    free(url);
    free(text);
    json_object_put(req);
    return mem;
}

static void mem_delete(long long mem) {
    if (!mem || !*mem_url()) return;
    char *url = fmt("%s/api/observation/%lld", mem_url(), mem), *out;
    run(NULL, &out, (const char *[]){"curl", "-s", "-m", "2", "-X", "DELETE", url, NULL});
    free(out);
    free(url);
}

/* claude-mem observation search: its markdown table text, or NULL. Observations only:
 * /api/search mixes in session and prompt ids. */
static char *mem_search(const char *query, const char *project, int limit) {
    if (!*mem_url()) return NULL;
    char *q = fmt("query=%s", query), *pr = fmt("project=%s", project), *lim = fmt("limit=%d", limit);
    char *url = fmt("%s/api/search/observations", mem_url()), *out, *text = NULL;
    json_object *resp, *content, *item, *t;
    if (run(NULL, &out, (const char *[]){"curl", "-s", "-m", "2", "-G", "--data-urlencode", q, "--data-urlencode", pr,
                                          "--data-urlencode", lim, url, NULL}) == 0 && (resp = json_tokener_parse(out))) {
        if (json_object_object_get_ex(resp, "content", &content) && json_object_is_type(content, json_type_array)
            && (item = json_object_array_get_idx(content, 0)) && json_object_object_get_ex(item, "text", &t))
            text = strdup(json_object_get_string(t));
        json_object_put(resp);
    }
    free(out);
    free(url);
    free(lim);
    free(pr);
    free(q);
    return text;
}

/* Append claude-mem hits (rows "| #<id> | time | type | title | ..." of `table`) to `out`:
 * as the cntctr entry mirrored there, else as "claude-mem #<id> <title>". Frees `out`. */
static char *merge_mem(sqlite3 *db, char *out, const char *table) {
    if (!table) return out;
    char *copy = strdup(table), *save;
    for (char *row = strtok_r(copy, "\n", &save); row; row = strtok_r(NULL, "\n", &save)) {
        long long mem;
        if (sscanf(row, "| #%lld |", &mem) != 1) continue;
        char *line = kb_by_mem(db, mem), *add = NULL, idsp[72];
        if (line) {
            snprintf(idsp, sizeof idsp, "%.*s ", (int)strcspn(line, " "), line);
            if (!strstr(out, idsp)) add = line, line = NULL;
        } else {
            char *t = row, *end;
            for (int i = 0; i < 3 && t; i++) t = strchr(t + 1, '|');
            if (t && (end = strchr(t + 1, '|'))) {
                for (t++; *t == ' '; t++) {}
                while (end > t && end[-1] == ' ') end--;
                add = fmt("claude-mem #%lld %.*s", mem, (int)(end - t), t);
            }
        }
        if (add) {
            char *n = fmt(*out ? "%s\n%s" : "%s%s", out, add);
            free(out);
            out = n;
            free(add);
        }
        free(line);
    }
    free(copy);
    return out;
}

/* ---- agents and delivery ---- */

/* Pane id of the agent called `name` (caller frees), or NULL. */
static char *find_agent(const char *name) {
    char *out, *pane = NULL, *save;
    if (TMUX(NULL, &out, "list-panes", "-a", "-F", "#{pane_id}\t#{@cntctr_name}") == 0)
        for (char *line = strtok_r(out, "\n", &save); line; line = strtok_r(NULL, "\n", &save)) {
            char *tab = strchr(line, '\t');
            if (tab && strcmp(tab + 1, name) == 0) {
                *tab = '\0';
                pane = strdup(line);
                break;
            }
        }
    free(out);
    return pane;
}

/* Text of harness permission dialogs. Enter on one of these accepts its default
 * choice, so nothing may be pasted while one is showing. Matched case-insensitively
 * against the last 15 lines of the pane. */
static const char *PROMPTS[] = {
    "Do you want to (proceed|make this edit|create|allow)",
    "Would you like to (run|make|allow)",
    "Allow (once|always|command|this)",
    "enter to confirm",
};
static regex_t prompt_re[sizeof PROMPTS / sizeof *PROMPTS];

static int awaiting_permission(const char *pane) {
    char *screen;
    if (TMUX(NULL, &screen, "capture-pane", "-p", "-t", pane) != 0) {
        free(screen);
        return 0;   /* a missing pane fails later, in paste-buffer */
    }
    char *tail = screen + strlen(screen);   /* run() already dropped trailing blank lines */
    for (int lines = 0; tail > screen; tail--)
        if (tail[-1] == '\n' && ++lines == 15) break;
    int hit = 0;
    for (size_t i = 0; i < sizeof PROMPTS / sizeof *PROMPTS && !hit; i++)
        hit = regexec(&prompt_re[i], tail, 0, NULL, 0) == 0;
    free(screen);
    return hit;
}

static int enter_delay_ms = 150;   /* CNTCTR_ENTER_DELAY_MS: pause between paste and Enter */

/* Write `text` to `pane`'s program through a temporary buffer, bracketed or raw. */
static char *paste(const char *pane, const char *text, int bracketed) {
    char buf[32], *err;
    snprintf(buf, sizeof buf, "cntctr-in-%08x", arc4random());
    if ((err = TMUXE(text, "load-buffer", "-b", buf, "-"))) return err;
    if ((err = bracketed ? TMUXE(NULL, "paste-buffer", "-p", "-d", "-b", buf, "-t", pane)
                         : TMUXE(NULL, "paste-buffer", "-d", "-b", buf, "-t", pane)))
        free(TMUXE(NULL, "delete-buffer", "-b", buf));
    return err;
}

/* Paste `text` into `pane` as one bracketed paste, then press Enter.
 * `who` names the pane in errors. Returns NULL or an error (caller frees). */
static char *inject(const char *pane, const char *who, const char *text) {
    if (awaiting_permission(pane)) return fmt("%s awaiting permission prompt; retry later", who);
    size_t n = strlen(text);
    /* Claude reads backslash + Enter as "new line", not "submit". */
    char *body = n && text[n - 1] == '\\' ? fmt("%s\n", text) : NULL, *err;
    err = paste(pane, body ? body : text, 1);
    free(body);
    if (err) return err;
    struct timespec pause = {enter_delay_ms / 1000, (enter_delay_ms % 1000) * 1000000L};
    nanosleep(&pause, NULL);
    /* Enter as a raw CR paste: send-keys would go to copy-mode if the user is scrolled back. */
    return paste(pane, "\r", 0);
}

static void new_id(char id[9]) { snprintf(id, 9, "%08x", arc4random()); }

/* Record that we sent message `id`, and whether we block on its reply. */
static void track(const char *id, int wait) {
    char opt[48];
    snprintf(opt, sizeof opt, "@cntctr_from_%s", id);
    free(TMUXE(NULL, "set", "-s", opt, caller_pane));
    if (wait) {
        snprintf(opt, sizeof opt, "@cntctr_wait_%s", id);
        free(TMUXE(NULL, "set", "-s", opt, "1"));
    }
}

/* Record which pane message `id` went to, so reply can name the replier
 * without knowing its own pane (Codex runs one shared server outside any pane). */
static void track_to(const char *id, const char *pane) {
    char opt[48];
    snprintf(opt, sizeof opt, "@cntctr_to_%s", id);
    free(TMUXE(NULL, "set", "-s", opt, pane));
}

static void untrack(const char *id) {
    char opt[48];
    snprintf(opt, sizeof opt, "@cntctr_from_%s", id);
    free(TMUXE(NULL, "set", "-su", opt));
    snprintf(opt, sizeof opt, "@cntctr_to_%s", id);
    free(TMUXE(NULL, "set", "-su", opt));
    snprintf(opt, sizeof opt, "@cntctr_wait_%s", id);
    free(TMUXE(NULL, "set", "-su", opt));
}

static char *envelope(const char *id, const char *text, const char *you) {
    char *hints = knowledge_hints(text);
    char *env = fmt("[cntctr from=%s id=%s]\n%s\n%s[when done: call the reply tool of the cntctr MCP server with id=%s and your answer, "
                    "plus insights=[...] with durable facts other agents should know; it is an MCP tool, not a shell command. "
                    "Your agent name is %s: pass from=%s when you call send, spawn or kill]",
                    caller_name, id, text, hints, id, you, you);
    free(hints);
    return env;
}

/* Nonzero if `pane` exists and its process is still running. */
static int pane_alive(const char *pane) {
    char *out;
    int alive = TMUX(NULL, &out, "display", "-p", "-t", pane, "#{pane_dead}") == 0 && strcmp(out, "0") == 0;
    free(out);
    return alive;
}

/* Value of server option `name` (caller frees), or NULL if unset. */
static char *sopt_get(const char *name) {
    char *out;
    if (TMUX(NULL, &out, "show", "-sv", name) == 0) return out;
    free(out);
    return NULL;
}

/* Block until channel `chan` is signalled (1) or `secs` pass (0). */
static int wait_signal(const char *chan, int secs) {
    int p[2];
    pthread_mutex_lock(&fork_mu);
    if (cloexec_pipe(p) < 0) {
        pthread_mutex_unlock(&fork_mu);
        return 0;
    }
    pid_t pid = start((const char *[]){"tmux", "wait-for", chan, NULL}, -1, p[1]);
    pthread_mutex_unlock(&fork_mu);
    close(p[1]);
    struct pollfd pfd = {p[0], POLLIN, 0};
    int ready;
    while ((ready = poll(&pfd, 1, secs * 1000)) < 0 && errno == EINTR) {}
    close(p[0]);
    if (pid < 0) return 0;
    if (ready == 0) kill(pid, SIGTERM);   /* its pipe closes only when it exits, so silence means still waiting */
    return reap(pid) == 0 && ready > 0;
}

static int buffer_exists(const char *buf) {
    char *err = TMUXE(NULL, "show-buffer", "-b", buf);
    free(err);
    return err == NULL;
}

/* Read and delete a paste buffer. The delete is the claim: when a timed-out
 * waiter and a replier race for one reply, only the side whose delete-buffer
 * succeeds delivers it, so every reply arrives exactly once. */
static char *buffer_take(const char *buf) {
    char *text, *err;
    if (TMUX(NULL, &text, "show-buffer", "-b", buf) != 0) {
        free(text);
        return NULL;
    }
    if ((err = TMUXE(NULL, "delete-buffer", "-b", buf))) {
        free(err);
        free(text);
        return NULL;
    }
    return text;
}

#define WAIT_SLICE 5   /* seconds between checks for a lost signal or a dead worker */

/* Block for the reply to message `id`, sent to agent `who` in `pane`. */
static int await_reply(const char *id, const char *pane, const char *who, int timeout, char **res) {
    char chan[32], buf[40], opt[48];
    snprintf(chan, sizeof chan, "cntctr-%s", id);
    snprintf(buf, sizeof buf, "cntctr-reply-%s", id);
    snprintf(opt, sizeof opt, "@cntctr_wait_%s", id);
    int gone = 0;
    for (time_t end = time(NULL) + timeout;;) {
        int left = (int)(end - time(NULL));
        if (left <= 0) break;
        /* tmux keeps a killed wait-for queued, and it can swallow a later signal,
         * so the buffer is checked after every slice as well. */
        if (wait_signal(chan, left < WAIT_SLICE ? left : WAIT_SLICE) || buffer_exists(buf)) break;
        if ((gone = !pane_alive(pane)) || cancelled()) break;
    }
    free(TMUXE(NULL, "set", "-su", opt));   /* stop repliers from signalling us, then claim */
    char *text = buffer_take(buf);
    if (text && cancelled()) {   /* nobody reads our result anymore: type the reply into our pane */
        char *env = fmt("[cntctr reply from=%s id=%s]\n%s", who, id, text), *err = inject(caller_pane, "your pane", env);
        free(env);
        free(text);
        if (err) return fail(res, err);
        untrack(id);
        return ok(res, fmt("cancelled; reply delivered to your pane (id=%s)", id));
    }
    if (text) {
        untrack(id);
        return ok(res, text);
    }
    if (gone) {
        untrack(id);
        return fail(res, fmt("agent %s exited before replying (id=%s)", who, id));
    }
    return ok(res, fmt("timed out; reply will arrive in your pane (id=%s)", id));
}

/* ---- tools ---- */

static int tool_list(json_object *args, char **res) {
    (void)args;
    char *out;
    if (TMUX(NULL, &out, "list-panes", "-a", "-F",
             "#{@cntctr_name} #{@cntctr_harness} #{pane_id} #{?pane_dead,dead,alive}") != 0)
        return fail(res, out);
    char *list = calloc(1, strlen(out) + 2), *save;
    for (char *line = strtok_r(out, "\n", &save); line; line = strtok_r(NULL, "\n", &save))
        if (*line != ' ') {   /* untagged panes have an empty name, so the line starts with a space */
            strcat(list, line);
            strcat(list, "\n");
        }
    free(out);
    if (!*list) {
        free(list);
        return ok(res, fmt("no agents"));
    }
    list[strlen(list) - 1] = '\0';
    return ok(res, list);
}

static int tool_send(json_object *a, char **res) {
    const char *to = sarg(a, "to"), *text = sarg(a, "text");
    if (!to || !text) return fail(res, fmt("send needs 'to' and 'text'"));
    char *pane = find_agent(to);
    if (!pane) return fail(res, fmt("agent %s not found", to));
    int wait = barg(a, "wait");
    char id[9], *env, *err;
    new_id(id);
    track(id, wait);
    track_to(id, pane);
    env = envelope(id, text, to);
    err = inject(pane, to, env);
    free(env);
    if (err) {
        untrack(id);
        free(pane);
        return fail(res, err);
    }
    char *title = fmt("task %s %s→%s", id, caller_name, to);
    log_history(caller_pane, title, text);
    free(title);
    int r = wait ? await_reply(id, pane, to, targ(a), res) : ok(res, fmt("sent id=%s", id));
    free(pane);
    return r;
}

/* Store a reply as history in the sender's project, and its insights in the replier's.
 * ponytail: a reply retried after a failed delivery is stored again; the librarian merges duplicates. */
static void remember_reply(const char *id, const char *to, const char *sender, const char *text, json_object *a) {
    char *me = pane_name(to), *them = pane_name(sender), *title = fmt("reply %s %s→%s", id, me ? me : "?", them ? them : "?");
    log_history(sender, title, text);
    json_object *ins = NULL;
    char *err = NULL;
    sqlite3 *db = json_object_object_get_ex(a, "insights", &ins) && json_object_is_type(ins, json_type_array) ? kb(&err) : NULL;
    free(err);
    if (db) {
        struct project p;
        resolve_project(db, to ? to : caller_pane, &p);
        for (size_t i = 0; i < json_object_array_length(ins); i++) {
            const char *s = json_object_get_string(json_object_array_get_idx(ins, i));
            if (!s || !*s) continue;
            char *t = first_line(s, 80), *sum = first_line(s, 300), eid[64];
            struct kb_entry e = {.layer = "insight", .scope = p.key, .title = t, .summary = sum, .body = s, .refs = id,
                                 .author = getenv("USER"), .agent = me ? me : caller_name, .visibility = "shared"};
            if (kb_put(db, &e, eid) == 0) {
                long long mem = mem_save(p.base, eid, "insight", p.key, t, sum, s);
                if (mem) kb_set_mem(db, eid, mem);
            }
            free(t);
            free(sum);
        }
        sqlite3_close(db);
    }
    free(me);
    free(them);
    free(title);
}

static int tool_reply(json_object *a, char **res) {
    const char *id = sarg(a, "id"), *text = sarg(a, "text");
    if (!id || !text) return fail(res, fmt("reply needs 'id' and 'text'"));
    char opt[48], buf[40], chan[32], *sender = NULL, *to, *waiting, *env, *err;
    snprintf(opt, sizeof opt, "@cntctr_from_%s", id);
    if (strlen(id) != 8 || strspn(id, "0123456789abcdef") != 8 || !(sender = sopt_get(opt)))
        return fail(res, fmt("unknown id %s", id));
    snprintf(opt, sizeof opt, "@cntctr_to_%s", id);
    to = sopt_get(opt);
    remember_reply(id, to, sender, text, a);

    /* Write the buffer before checking the wait flag; await_reply clears the flag
     * before claiming. That ordering means no reply is lost. */
    snprintf(buf, sizeof buf, "cntctr-reply-%s", id);
    if ((err = TMUXE(text, "load-buffer", "-b", buf, "-"))) {
        free(sender);
        free(to);
        return fail(res, err);
    }
    snprintf(opt, sizeof opt, "@cntctr_wait_%s", id);
    if ((waiting = sopt_get(opt))) {   /* sender is blocked in await_reply: wake it */
        free(waiting);
        free(sender);
        free(to);
        snprintf(chan, sizeof chan, "cntctr-%s", id);
        free(TMUXE(NULL, "wait-for", "-S", chan));
        return ok(res, fmt("ok"));
    }
    /* Nobody waiting: type the reply into the sender's pane, unless a timed-out
     * waiter claimed the buffer first. */
    if ((err = TMUXE(NULL, "delete-buffer", "-b", buf))) {
        free(err);
        free(sender);
        free(to);
        return ok(res, fmt("ok"));
    }
    if (!pane_alive(sender)) {
        free(sender);
        free(to);
        untrack(id);
        return fail(res, fmt("sender gone"));
    }
    char *me = pane_name(to);
    env = fmt("[cntctr reply from=%s id=%s]\n%s", me && *me ? me : *self_name ? self_name : client_name, id, text);
    free(me);
    free(to);
    err = inject(sender, "sender", env);
    free(env);
    free(sender);
    if (err) return fail(res, err);   /* still tracked, so the replier can retry */
    untrack(id);
    return ok(res, fmt("ok"));
}

static int tool_spawn(json_object *a, char **res) {
    const char *harness = sarg(a, "harness"), *name = sarg(a, "name"), *task = sarg(a, "task"), *cwd = sarg(a, "cwd");
    if (!harness || !name || !*name || !task) return fail(res, fmt("spawn needs 'harness', 'name' and 'task'"));
    int agy = strcmp(harness, "agy") == 0;
    if (!agy && strcmp(harness, "claude") != 0 && strcmp(harness, "codex") != 0)
        return fail(res, fmt("unknown harness %s", harness));
    char *pane = find_agent(name);
    if (pane) {
        free(pane);
        return fail(res, fmt("agent %s already exists", name));
    }
    char dir[4096];
    if (!cwd) cwd = getcwd(dir, sizeof dir) ? dir : ".";
    int wait = barg(a, "wait");
    char id[9];
    new_id(id);
    track(id, wait);
    char *env = envelope(id, task, name);
    /* Separate argv entries, so tmux execs the harness without a shell. agy takes
     * its first prompt through -i; claude and codex take it as a plain argument. */
    int rc = run(NULL, &pane, (const char *[]){"tmux", "new-window", "-d", "-n", name, "-c", cwd, "-P", "-F", "#{pane_id}",
                                              harness, agy ? "-i" : env, agy ? env : NULL, NULL});
    free(env);
    if (rc != 0) {
        untrack(id);
        return fail(res, pane);
    }
    /* ponytail: a worker that calls cntctr before these tags land names itself
     * <client>-<n>. Real harnesses take seconds to start; tag via new-window -e if that changes. */
    track_to(id, pane);
    free(TMUXE(NULL, "set", "-p", "-t", pane, "@cntctr_name", name));
    free(TMUXE(NULL, "set", "-p", "-t", pane, "@cntctr_harness", harness));
    char *title = fmt("task %s %s→%s", id, caller_name, name);
    log_history(caller_pane, title, task);
    free(title);
    int r = wait ? await_reply(id, pane, name, targ(a), res) : ok(res, fmt("spawned %s in %s id=%s", name, pane, id));
    free(pane);
    return r;
}

static int tool_kill(json_object *a, char **res) {
    const char *name = sarg(a, "name");
    char *pane = name ? find_agent(name) : NULL, *err;
    if (!pane) return fail(res, fmt("agent %s not found", name ? name : "(none)"));
    if (strcmp(pane, caller_pane) == 0) {
        free(pane);
        return fail(res, fmt("cannot kill yourself"));
    }
    err = TMUXE(NULL, "kill-pane", "-t", pane);
    free(pane);
    return err ? fail(res, err) : ok(res, fmt("ok"));
}

/* ---- knowledge tools ---- */

static sqlite3 *kb_for_caller(struct project *p, char **res) {
    sqlite3 *db = kb(res);
    if (db) resolve_project(db, caller_pane, p);
    return db;
}

static int is_layer(const char *l) {
    return l && (strcmp(l, "insight") == 0 || strcmp(l, "skill") == 0 || strcmp(l, "doc") == 0);
}

static int tool_note(json_object *a, char **res) {
    const char *layer = sarg(a, "layer"), *title = sarg(a, "title"), *summary = sarg(a, "summary");
    const char *body = sarg(a, "body"), *scope = sarg(a, "scope");
    if (!is_layer(layer) || !title || !*title || !summary || !*summary)
        return fail(res, fmt("note needs layer (insight, skill or doc), title and summary"));
    json_object *sup = NULL;
    json_object_object_get_ex(a, "supersedes", &sup);
    size_t nsup = json_object_is_type(sup, json_type_array) ? json_object_array_length(sup) : 0;
    struct project p;
    sqlite3 *db = kb_for_caller(&p, res);
    if (!db) return 1;
    for (size_t i = 0; i < nsup; i++) {
        const char *old = json_object_get_string(json_object_array_get_idx(sup, i));
        char l[16];
        long long mem;
        int bad = !old || kb_lookup(db, old, l, &mem) != 0;
        if (bad || strcmp(l, "history") == 0) {
            sqlite3_close(db);
            return fail(res, bad ? fmt("entry %s not found", old ? old : "(none)") : fmt("history entries cannot be superseded"));
        }
    }
    int global = scope && strcmp(scope, "global") == 0;
    char *line = first_line(summary, 300), id[64];
    struct kb_entry e = {.layer = layer, .scope = global ? "global" : p.key, .title = title, .summary = line,
                         .body = body, .tags = sarg(a, "tags"), .refs = sarg(a, "refs"),
                         .author = getenv("USER"), .agent = caller_name, .visibility = "shared"};
    if (kb_put(db, &e, id) != 0) {
        char *err = fmt("note failed: %s", sqlite3_errmsg(db));
        free(line);
        sqlite3_close(db);
        return fail(res, err);
    }
    for (size_t i = 0; i < nsup; i++) {
        const char *old = json_object_get_string(json_object_array_get_idx(sup, i));
        char l[16];
        long long mem = 0;
        kb_lookup(db, old, l, &mem);
        mem_delete(mem);
        kb_supersede(db, old, id);
    }
    long long mem = mem_save(global ? "cntctr-global" : p.base, id, layer, e.scope, title, line, body);
    if (mem) kb_set_mem(db, id, mem);
    free(line);
    sqlite3_close(db);
    return ok(res, fmt("noted %s", id));
}

static int tool_read(json_object *a, char **res) {
    const char *id = sarg(a, "id");
    if (!id) return fail(res, fmt("read needs 'id'"));
    sqlite3 *db = kb(res);
    if (!db) return 1;
    char *text = kb_show(db, id);
    sqlite3_close(db);
    return text ? ok(res, text) : fail(res, fmt("entry %s not found", id));
}

static int tool_project(json_object *a, char **res) {
    const char *key = sarg(a, "key");
    struct project p;
    sqlite3 *db = kb_for_caller(&p, res);
    if (!db) return 1;
    if (key) {
        kb_project_set(db, p.root, key);
        resolve_project(db, caller_pane, &p);
    }
    sqlite3_close(db);
    return ok(res, fmt("project %s (root %s)", p.key, p.root));
}

static int tool_recall(json_object *a, char **res) {
    const char *query = sarg(a, "query"), *layer = sarg(a, "layer"), *scope = sarg(a, "scope"), *since = sarg(a, "since");
    json_object *v;
    int limit = json_object_object_get_ex(a, "limit", &v) ? json_object_get_int(v) : 20;
    limit = limit < 1 ? 1 : limit > 200 ? 200 : limit;
    if (layer && !*layer) layer = NULL;
    struct project p;
    sqlite3 *db = kb_for_caller(&p, res);
    if (!db) return 1;
    const char *s1 = p.key, *s2 = "global";
    if (scope && strcmp(scope, "global") == 0) s1 = "global", s2 = NULL;
    else if (scope && strcmp(scope, "project") == 0) s2 = NULL;
    char *out;
    if (query && *query) {
        char *table = mem_search(query, strcmp(s1, "global") == 0 ? "cntctr-global" : p.base, limit);
        out = merge_mem(db, kb_search(db, s1, s2, query, layer, 1, limit), table);
        free(table);
    } else {
        out = kb_index(db, s1, s2, layer, since, limit);
    }
    sqlite3_close(db);
    if (*out) return ok(res, out);
    free(out);
    return ok(res, fmt("no entries"));
}

static int tool_forget(json_object *a, char **res) {
    const char *id = sarg(a, "id");
    if (!id) return fail(res, fmt("forget needs 'id'"));
    sqlite3 *db = kb(res);
    if (!db) return 1;
    char layer[16];
    long long mem = 0;
    int found = kb_lookup(db, id, layer, &mem) == 0, history = found && strcmp(layer, "history") == 0;
    if (found && !history) {
        mem_delete(mem);
        kb_supersede(db, id, "forgotten");
    }
    sqlite3_close(db);
    if (!found) return fail(res, fmt("entry %s not found", id));
    if (history) return fail(res, fmt("history entries cannot be forgotten"));
    return ok(res, fmt("forgot %s", id));
}

/* ---- dispatch ---- */

typedef int (*tool_fn)(json_object *args, char **res);
static const struct { const char *name; tool_fn fn; int needs_pane; } TOOL_FNS[] = {
    {"list", tool_list, 0},
    {"send", tool_send, 1},
    {"reply", tool_reply, 0},
    {"spawn", tool_spawn, 1},
    {"kill", tool_kill, 1},
    {"note", tool_note, 0},
    {"read", tool_read, 0},
    {"project", tool_project, 0},
    {"recall", tool_recall, 0},
    {"forget", tool_forget, 0},
    {NULL, NULL, 0},
};

/* Set caller_* from the `from` argument: an agent name, or a pane id ($TMUX_PANE) for a
 * leader started by hand, which is tagged on first use. Returns an error or NULL. */
static char *resolve_from(const char *from) {
    char *pane = *from == '%' ? strdup(from) : find_agent(from);
    if (!pane || !pane_alive(pane)) {
        free(pane);
        return fmt("from=%s is not a live agent or pane", from);
    }
    char *name;
    snprintf(caller_pane, sizeof caller_pane, "%s", pane);
    if (TMUX(NULL, &name, "show", "-pqv", "-t", pane, "@cntctr_name") == 0 && *name) {
        snprintf(caller_name, sizeof caller_name, "%s", name);
    } else {
        snprintf(caller_name, sizeof caller_name, "agent-%s", pane + 1);
        free(TMUXE(NULL, "set", "-p", "-t", pane, "@cntctr_name", caller_name));
    }
    free(name);
    free(pane);
    return NULL;
}

static int dispatch(const char *name, json_object *args, char **res) {
    for (int i = 0; TOOL_FNS[i].name; i++) {
        if (strcmp(TOOL_FNS[i].name, name ? name : "") != 0) continue;
        snprintf(caller_pane, sizeof caller_pane, "%s", self_pane);
        snprintf(caller_name, sizeof caller_name, "%s", self_name);
        const char *from = sarg(args, "from");
        if (from && *from) {
            char *err = resolve_from(from);
            if (err) return fail(res, err);
        }
        if (TOOL_FNS[i].needs_pane && !*caller_pane)
            return fail(res, fmt("cntctr cannot tell which pane you are in; pass from=<your agent name, or your $TMUX_PANE if you were started by hand>"));
        return TOOL_FNS[i].fn(args, res);
    }
    return fail(res, fmt("unknown tool %s", name ? name : "(none)"));
}

#define KFROM "\"from\":{\"type\":\"string\",\"description\":\"Your agent name. Needed from Codex, whose cntctr runs outside your pane, to find your project\"}"

static const char TOOLS[] =
    "{\"tools\":["
    "{\"name\":\"spawn\",\"description\":\"Start a new agent (claude, codex or agy) in its own tmux window with a first task. "
    "The worker answers with reply. Returns the message id at once, or with wait=true blocks until the reply arrives.\","
    "\"inputSchema\":{\"type\":\"object\",\"properties\":{"
    "\"harness\":{\"type\":\"string\",\"enum\":[\"claude\",\"codex\",\"agy\"]},"
    "\"name\":{\"type\":\"string\",\"description\":\"Unique agent name; other agents use it as 'to'\"},"
    "\"task\":{\"type\":\"string\"},"
    "\"cwd\":{\"type\":\"string\",\"description\":\"Working directory; defaults to yours\"},"
    "\"from\":{\"type\":\"string\",\"description\":\"Who you are, if this fails with a pane error (Codex): your agent name, or $TMUX_PANE\"},"
    "\"wait\":{\"type\":\"boolean\"},"
    "\"timeout\":{\"type\":\"integer\",\"description\":\"Seconds to block when wait=true (default 600)\"}},"
    "\"required\":[\"harness\",\"name\",\"task\"]}},"
    "{\"name\":\"send\",\"description\":\"Send a message to another agent's terminal. Returns the message id at once. "
    "With wait=true, blocks until the receiver calls reply; if the timeout passes first, the reply arrives in your terminal later.\","
    "\"inputSchema\":{\"type\":\"object\",\"properties\":{"
    "\"to\":{\"type\":\"string\"},\"text\":{\"type\":\"string\"},\"wait\":{\"type\":\"boolean\"},"
    "\"from\":{\"type\":\"string\",\"description\":\"Who you are, if this fails with a pane error (Codex): your agent name, or $TMUX_PANE\"},"
    "\"timeout\":{\"type\":\"integer\",\"description\":\"Seconds to block when wait=true (default 600)\"}},"
    "\"required\":[\"to\",\"text\"]}},"
    "{\"name\":\"reply\",\"description\":\"Answer a message you received. Use the id from its [cntctr from=... id=...] header. "
    "Always reply when you finish a task another agent gave you.\","
    "\"inputSchema\":{\"type\":\"object\",\"properties\":{\"id\":{\"type\":\"string\"},\"text\":{\"type\":\"string\"},"
    "\"insights\":{\"type\":\"array\",\"items\":{\"type\":\"string\"},\"description\":\"Durable facts other agents should know; each is stored in the shared knowledge store\"}},"
    "\"required\":[\"id\",\"text\"]}},"
    "{\"name\":\"list\",\"description\":\"List agents: name, harness, tmux pane, alive or dead.\","
    "\"inputSchema\":{\"type\":\"object\",\"properties\":{}}},"
    "{\"name\":\"kill\",\"description\":\"Close an agent's tmux pane.\","
    "\"inputSchema\":{\"type\":\"object\",\"properties\":{\"name\":{\"type\":\"string\"},\"from\":{\"type\":\"string\",\"description\":\"Who you are, if this fails with a pane error (Codex): your agent name, or $TMUX_PANE\"}},\"required\":[\"name\"]}}"
    ",{\"name\":\"note\",\"description\":\"Store durable knowledge for all agents: insight (a 1-5 line fact or decision), "
    "skill (a reusable how-to) or doc (long text). Point at code as file:symbol instead of copying it. "
    "To replace or merge entries, pass their ids in supersedes.\","
    "\"inputSchema\":{\"type\":\"object\",\"properties\":{"
    "\"layer\":{\"type\":\"string\",\"enum\":[\"insight\",\"skill\",\"doc\"]},"
    "\"title\":{\"type\":\"string\"},"
    "\"summary\":{\"type\":\"string\",\"description\":\"One line; the index shows only this\"},"
    "\"body\":{\"type\":\"string\"},"
    "\"tags\":{\"type\":\"string\",\"description\":\"Extra search words, e.g. synonyms\"},"
    "\"refs\":{\"type\":\"string\",\"description\":\"Source entry or message ids, code pointers\"},"
    "\"scope\":{\"type\":\"string\",\"enum\":[\"project\",\"global\"],\"description\":\"global for knowledge not tied to this repo\"},"
    "\"supersedes\":{\"type\":\"array\",\"items\":{\"type\":\"string\"}}," KFROM "},"
    "\"required\":[\"layer\",\"title\",\"summary\"]}},"
    "{\"name\":\"read\",\"description\":\"Read one knowledge entry in full.\","
    "\"inputSchema\":{\"type\":\"object\",\"properties\":{\"id\":{\"type\":\"string\"}},\"required\":[\"id\"]}},"
    "{\"name\":\"project\",\"description\":\"Show the project key your knowledge is filed under, or set key to override it for this repo (empty key removes the override).\","
    "\"inputSchema\":{\"type\":\"object\",\"properties\":{\"key\":{\"type\":\"string\"}," KFROM "}}}"
    ",{\"name\":\"recall\",\"description\":\"Read the shared knowledge store before you explore. Without query: the index, "
    "one line per entry, this project first, then global. With query: search, including work history. Use read for an entry's full text.\","
    "\"inputSchema\":{\"type\":\"object\",\"properties\":{\"query\":{\"type\":\"string\"},"
    "\"layer\":{\"type\":\"string\",\"enum\":[\"insight\",\"skill\",\"doc\",\"history\"]},"
    "\"scope\":{\"type\":\"string\",\"enum\":[\"project\",\"global\"]},"
    "\"since\":{\"type\":\"string\",\"description\":\"UTC 'YYYY-MM-DD HH:MM:SS'; index only\"},"
    "\"limit\":{\"type\":\"integer\",\"description\":\"Default 20, at most 200\"}," KFROM "}}},"
    "{\"name\":\"forget\",\"description\":\"Retire a stale or wrong knowledge entry (history cannot be forgotten).\","
    "\"inputSchema\":{\"type\":\"object\",\"properties\":{\"id\":{\"type\":\"string\"}},\"required\":[\"id\"]}}"
    "]}";

/* ---- MCP protocol ---- */

static void emit(json_object *msg) {
    const char *s = json_object_to_json_string_ext(msg, JSON_C_TO_STRING_PLAIN | JSON_C_TO_STRING_NOSLASHESCAPE);
    pthread_mutex_lock(&out_mu);
    fputs(s, stdout);
    fputc('\n', stdout);
    fflush(stdout);
    pthread_mutex_unlock(&out_mu);
    json_object_put(msg);
}

static json_object *rpc_msg(json_object *id) {
    json_object *m = json_object_new_object();
    json_object_object_add(m, "jsonrpc", json_object_new_string("2.0"));
    json_object_object_add(m, "id", json_object_get(id));
    return m;
}

static void respond(json_object *id, json_object *result) {
    json_object *m = rpc_msg(id);
    json_object_object_add(m, "result", result);
    emit(m);
}

static void respond_error(json_object *id, int code, const char *message) {
    json_object *m = rpc_msg(id), *e = json_object_new_object();
    json_object_object_add(e, "code", json_object_new_int(code));
    json_object_object_add(e, "message", json_object_new_string(message));
    json_object_object_add(m, "error", e);
    emit(m);
}

static const char GUIDE[] =
    "cntctr keeps a knowledge store shared by all agents (Claude, Codex, agy) across sessions. "
    "Before exploring a codebase or problem, call recall: no query lists the index, a query searches; read shows an entry in full. "
    "When you learn something durable (a fact, decision, gotcha, procedure, or the summary of a long analysis), store it with note: "
    "layer insight (1-5 lines), skill (a how-to) or doc (long text); point at code as file:symbol instead of copying it. "
    "When you reply to a task, add insights=[...].";

/* Usage guide plus the knowledge index: our project's and global entries, or only
 * global ones for a server outside any pane (Codex), capped at 40 lines and 4 KB. */
static char *instructions(void) {
    char *err = NULL;
    sqlite3 *db = kb(&err);
    free(err);
    if (!db) return strdup(GUIDE);
    struct project p;
    resolve_project(db, self_pane, &p);
    char *index = *self_pane ? kb_index(db, p.key, "global", NULL, NULL, 40) : kb_index(db, "global", NULL, NULL, NULL, 40);
    sqlite3_close(db);
    if (strlen(index) > 4096) {
        index[4096] = '\0';
        char *nl = strrchr(index, '\n');
        if (nl) *nl = '\0';
    }
    char *r = fmt("%s%s\n\nKnowledge index (%s):\n%s", GUIDE,
                  *self_pane ? "" : " This cntctr runs outside your tmux pane: pass from=<your agent name> to the knowledge tools.",
                  *self_pane ? p.key : "global only", *index ? index : "(empty)");
    free(index);
    return r;
}

static json_object *initialize(json_object *params) {
    json_object *info = NULL;
    const char *name = json_object_object_get_ex(params, "clientInfo", &info) ? sarg(info, "name") : NULL;
    const char *version = sarg(params, "protocolVersion");
    if (name && *name) snprintf(client_name, sizeof client_name, "%s", name);
    find_self();

    json_object *r = json_object_new_object(), *caps = json_object_new_object(), *server = json_object_new_object();
    json_object_object_add(caps, "tools", json_object_new_object());
    json_object_object_add(server, "name", json_object_new_string("cntctr"));
    json_object_object_add(server, "version", json_object_new_string("0.1.0"));
    json_object_object_add(r, "protocolVersion", json_object_new_string(version ? version : "2025-06-18"));
    json_object_object_add(r, "capabilities", caps);
    json_object_object_add(r, "serverInfo", server);
    char *guide = instructions();
    json_object_object_add(r, "instructions", json_object_new_string(guide));
    free(guide);
    return r;
}

static void *call_thread(void *arg) {
    this_call = arg;
    json_object *req = this_call->req, *id = this_call->id, *params = NULL, *args = NULL;
    if (json_object_object_get_ex(req, "params", &params)) json_object_object_get_ex(params, "arguments", &args);

    char *text = NULL;
    int is_error = dispatch(sarg(params, "name"), args, &text);

    json_object *item = json_object_new_object(), *content = json_object_new_array(), *result = json_object_new_object();
    json_object_object_add(item, "type", json_object_new_string("text"));
    json_object_object_add(item, "text", json_object_new_string(text));
    json_object_array_add(content, item);
    json_object_object_add(result, "content", content);
    json_object_object_add(result, "isError", json_object_new_boolean(is_error));
    respond(id, result);
    free(text);

    pthread_mutex_lock(&live_mu);
    struct call **p = &calls;
    while (*p != this_call) p = &(*p)->next;
    *p = this_call->next;
    if (!calls) pthread_cond_signal(&live_cv);
    pthread_mutex_unlock(&live_mu);
    json_object_put(req);
    free(this_call);
    return NULL;
}

/* Run a tools/call on its own thread so a blocking send doesn't hold up other calls. */
static void start_call(json_object *req) {
    pthread_t thread;
    struct call *c = calloc(1, sizeof *c);
    c->req = req;
    json_object_object_get_ex(req, "id", &c->id);
    pthread_mutex_lock(&live_mu);
    c->next = calls;
    calls = c;
    pthread_mutex_unlock(&live_mu);
    if (pthread_create(&thread, NULL, call_thread, c) == 0) pthread_detach(thread);
    else call_thread(c);   /* out of threads: run it inline */
}

static void handle(const char *line) {
    json_object *req = json_tokener_parse(line), *id = NULL, *params = NULL;
    if (!json_object_is_type(req, json_type_object)) {
        json_object_put(req);
        respond_error(NULL, -32700, "parse error");
        return;
    }
    json_object_object_get_ex(req, "id", &id);
    json_object_object_get_ex(req, "params", &params);
    const char *method = sarg(req, "method");
    if (method && strcmp(method, "tools/call") == 0) { start_call(req); return; }   /* the thread owns req now */

    if (!method) respond_error(id, -32600, "invalid request");
    else if (strcmp(method, "initialize") == 0) respond(id, initialize(params));
    else if (strcmp(method, "ping") == 0) respond(id, json_object_new_object());
    else if (strcmp(method, "tools/list") == 0) respond(id, json_tokener_parse(TOOLS));
    else if (strcmp(method, "notifications/cancelled") == 0) {
        json_object *rid = NULL;
        if (json_object_object_get_ex(params, "requestId", &rid) && rid) cancel(rid);
    }
    else if (id) respond_error(id, -32601, "method not found");   /* notifications need no answer */
    json_object_put(req);
}

int main(void) {
    signal(SIGPIPE, SIG_IGN);
    const char *delay = getenv("CNTCTR_ENTER_DELAY_MS");
    if (delay) enter_delay_ms = atoi(delay);
    for (size_t i = 0; i < sizeof PROMPTS / sizeof *PROMPTS; i++)
        regcomp(&prompt_re[i], PROMPTS[i], REG_EXTENDED | REG_ICASE | REG_NOSUB);
    char *line = NULL;
    size_t cap = 0;
    while (getline(&line, &cap, stdin) > 0) handle(line);
    free(line);
    /* Client gone: blocking sends stop within one wait slice and their replies
     * go to the pane instead. */
    cancel(NULL);
    pthread_mutex_lock(&live_mu);
    while (calls) pthread_cond_wait(&live_cv, &live_mu);
    pthread_mutex_unlock(&live_mu);
    return 0;
}
