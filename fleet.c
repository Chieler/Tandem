/* The fleet tool runner: sandbox profile, environment, and one poll loop for a tool's
 * stdin, stdout, stderr and composition socket. Knows nothing about tmux, MCP or the
 * knowledge store. cntctr ignores SIGPIPE, so writes to a gone child fail with EPIPE. */
#define _DARWIN_C_SOURCE
#define _GNU_SOURCE
#include "fleet.h"
#include <errno.h>
#include <fcntl.h>
#include <ftw.h>
#include <limits.h>
#include <poll.h>
#include <signal.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#define OUT_CAP (256 * 1024)
#define ERR_CAP (16 * 1024)
#define ERR_SHOWN 4096     /* how much of stderr's tail an error carries */
#define LINE_CAP (1 << 20)

extern char **environ;

static char *fmt(const char *f, ...) {
    va_list ap;
    char *s;
    va_start(ap, f);
    if (vasprintf(&s, f, ap) < 0) abort();
    va_end(ap);
    return s;
}

struct buf { char *p; size_t len, cap; };

static void put(struct buf *b, const char *s, size_t n) {
    if (b->len + n + 1 > b->cap) b->p = realloc(b->p, b->cap = (b->len + n + 1) * 2);
    memcpy(b->p + b->len, s, n);
    b->p[b->len += n] = '\0';
}

/* ---- paths ---- */

static void mkdirs(const char *path) {
    char *p = strdup(path);
    for (char *c = p + 1; *c; c++)
        if (*c == '/') {
            *c = '\0';
            mkdir(p, 0755);
            *c = '/';
        }
    mkdir(p, 0755);
    free(p);
}

static char *canon(const char *path) {
    char buf[PATH_MAX];
    return realpath(path, buf) ? strdup(buf) : NULL;
}

char *fleet_cache_dir(const char *root) {
    uint64_t h = 1469598103934665603ULL;   /* FNV-1a */
    for (const char *c = root; *c; c++) h = (h ^ (unsigned char)*c) * 1099511628211ULL;
    const char *slash = strrchr(root, '/'), *home = getenv("HOME");
    char *dir = fmt("%s/.cache/cntctr/tools/%s-%016llx", home && *home ? home : ".",
                    slash && slash[1] ? slash + 1 : "root", (unsigned long long)h);
    mkdirs(dir);
    char *real = canon(dir);
    free(dir);
    return real;
}

static int rm_entry(const char *path, const struct stat *sb, int flag, struct FTW *ftw) {
    (void)sb, (void)flag, (void)ftw;
    remove(path);
    return 0;
}

static void rm_rf(const char *path) { nftw(path, rm_entry, 16, FTW_DEPTH | FTW_PHYS); }

static int on_path(const char *cmd) {
    char *dirs = strdup(getenv("PATH") ? getenv("PATH") : ""), *save = NULL;
    int found = 0;
    for (char *d = strtok_r(dirs, ":", &save); d && !found; d = strtok_r(NULL, ":", &save)) {
        char *f = fmt("%s/%s", d, cmd);
        found = access(f, X_OK) == 0;
        free(f);
    }
    free(dirs);
    return found;
}

/* ---- text ---- */

/* Copy of b[0..n) with each invalid UTF-8 sequence, and each NUL, replaced by U+FFFD. */
static char *utf8_clean(const char *b, size_t n) {
    struct buf o = {0};
    put(&o, "", 0);
    for (size_t i = 0; i < n;) {
        unsigned char c = (unsigned char)b[i], d = i + 1 < n ? (unsigned char)b[i + 1] : 0;
        size_t len = c < 0x80 ? 1 : c >= 0xC2 && c < 0xE0 ? 2 : c >= 0xE0 && c < 0xF0 ? 3 : c >= 0xF0 && c < 0xF5 ? 4 : 0;
        int good = len && c != 0 && i + len <= n;
        for (size_t k = 1; good && k < len; k++) good = ((unsigned char)b[i + k] & 0xC0) == 0x80;
        if (good && len == 3) good = !(c == 0xE0 && d < 0xA0) && !(c == 0xED && d >= 0xA0);   /* overlong, surrogate */
        if (good && len == 4) good = !(c == 0xF0 && d < 0x90) && !(c == 0xF4 && d >= 0x90);
        if (good) {
            put(&o, b + i, len);
            i += len;
        } else {
            put(&o, "\xEF\xBF\xBD", 3);
            i++;
        }
    }
    return o.p;
}

/* Cleaned text with trailing newlines removed. */
static char *result_text(const char *b, size_t n) {
    char *s = utf8_clean(b, n);
    size_t len = strlen(s);
    while (len && s[len - 1] == '\n') s[--len] = '\0';
    return s;
}

/* `head`, then the tail of stderr if there is any. */
static char *error_with(const char *head, const struct buf *err) {
    size_t from = err->len > ERR_SHOWN ? err->len - ERR_SHOWN : 0;
    char *tail = result_text(err->p ? err->p + from : "", err->len - from), *s;
    s = *tail ? fmt("%s\n%s", head, tail) : fmt("%s", head);
    free(tail);
    return s;
}

/* ---- sandbox ---- */

/* A path as an SBPL string literal. */
static char *sbpl_str(const char *path) {
    struct buf b = {0};
    put(&b, "\"", 1);
    for (const char *c = path; *c; c++) {
        if (*c == '"' || *c == '\\') put(&b, "\\", 1);
        put(&b, c, 1);
    }
    put(&b, "\"", 1);
    return b.p;
}

static char *sbpl(const char *root, const char *tmp, const char *cache, int net) {
    char *git = fmt("%s/.git", root), *q[] = {sbpl_str(root), sbpl_str(tmp), sbpl_str(cache), sbpl_str(git)};
    char *p = fmt("(version 1)(allow default)(deny file-write*)"
                  "(allow file-write* (subpath %s) (subpath %s) (subpath %s) (subpath \"/dev\"))"
                  "(deny file-write* (subpath %s) (literal %s))%s",
                  q[0], q[1], q[2], q[3], q[3], net ? "" : "(deny network*)");
    for (int i = 0; i < 4; i++) free(q[i]);
    free(git);
    return p;
}

/* argv for the sandbox around `<interp> <tmp>/tool`; NULL-terminated, strings malloc'd. */
static char **sandbox_argv(const struct fleet_run *r, const char *root, const char *tmp, const char *cache,
                           const char *tool) {
    char **v = calloc(40, sizeof *v);
    int n = 0;
    if (on_path("sandbox-exec")) {
        v[n++] = strdup("sandbox-exec");
        v[n++] = strdup("-p");
        v[n++] = sbpl(root, tmp, cache, r->net);
    } else if (on_path("bwrap")) {
        char *git = fmt("%s/.git", root);
        struct stat sb;
        const char *fixed[] = {"bwrap", "--ro-bind", "/", "/", "--dev", "/dev", "--proc", "/proc"};
        for (size_t i = 0; i < sizeof fixed / sizeof *fixed; i++) v[n++] = strdup(fixed[i]);
        v[n++] = strdup("--bind"), v[n++] = strdup(root), v[n++] = strdup(root);
        if (lstat(git, &sb) == 0) v[n++] = strdup("--ro-bind"), v[n++] = strdup(git), v[n++] = strdup(git);
        v[n++] = strdup("--bind"), v[n++] = strdup(tmp), v[n++] = strdup(tmp);
        v[n++] = strdup("--bind"), v[n++] = strdup(cache), v[n++] = strdup(cache);
        v[n++] = strdup("--unshare-pid"), v[n++] = strdup("--die-with-parent"), v[n++] = strdup("--new-session");
        if (!r->net) v[n++] = strdup("--unshare-net");
        v[n++] = strdup("--");
        free(git);
    } else {
        free(v);
        return NULL;
    }
    v[n++] = strdup(r->interpreter);
    v[n++] = strdup(tool);
    return v;
}

static void free_strv(char **v) {
    for (char **c = v; *c; c++) free(*c);
    free(v);
}

/* ---- environment ---- */

static int dropped(const char *kv) {
    static const char *names[] = {"TMUX", "TMUX_PANE", "SSH_AUTH_SOCK", "TMPDIR", "XDG_CACHE_HOME", "npm_config_cache",
                                  "PIP_CACHE_DIR", "GOCACHE", "CNTCTR_FD", "CNTCTR_ROOT"};
    static const char *tails[] = {"_KEY", "_TOKEN", "_SECRET"};
    size_t n = strcspn(kv, "=");
    for (size_t i = 0; i < sizeof names / sizeof *names; i++)
        if (strlen(names[i]) == n && strncmp(kv, names[i], n) == 0) return 1;
    for (size_t i = 0; i < sizeof tails / sizeof *tails; i++) {
        size_t t = strlen(tails[i]);
        if (n >= t && strncmp(kv + n - t, tails[i], t) == 0) return 1;
    }
    return 0;
}

static char **tool_env(const char *root, const char *tmp, const char *cache) {
    size_t n = 0;
    while (environ[n]) n++;
    char **v = calloc(n + 12, sizeof *v);
    size_t k = 0;
    for (size_t i = 0; i < n; i++)
        if (!dropped(environ[i])) v[k++] = strdup(environ[i]);
    v[k++] = fmt("TMPDIR=%s", tmp);
    v[k++] = fmt("XDG_CACHE_HOME=%s/xdg", cache);
    v[k++] = fmt("npm_config_cache=%s/npm", cache);
    v[k++] = fmt("PIP_CACHE_DIR=%s/pip", cache);
    v[k++] = fmt("GOCACHE=%s/go", cache);
    v[k++] = strdup("CNTCTR_FD=3");
    v[k++] = fmt("CNTCTR_ROOT=%s", root);
    return v;
}

/* ---- the run ---- */

static void set_nonblock(int fd) { fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK); }

static void close_fd(int *fd) {
    if (*fd >= 0) close(*fd);
    *fd = -1;
}

static long long now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (long long)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

/* Read what is available into `b`, up to `cap` bytes. Closes *fd at EOF. Returns 1 if it hit the cap. */
static int drain(int *fd, struct buf *b, size_t cap) {
    char tmp[8192];
    while (*fd >= 0) {
        ssize_t n = read(*fd, tmp, sizeof tmp);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) {
            if (n < 0 && errno == EAGAIN) return 0;
            close_fd(fd);
            return 0;
        }
        if (b->len + (size_t)n > cap) {
            put(b, tmp, cap - b->len);
            return 1;
        }
        put(b, tmp, (size_t)n);
    }
    return 0;
}

/* Answer each complete request line in `in` and queue the replies on `outq`. */
static void serve_lines(const struct fleet_run *r, struct buf *in, struct buf *outq) {
    char *nl;
    while (in->len && (nl = memchr(in->p, '\n', in->len))) {
        *nl = '\0';
        char *reply = r->serve ? r->serve(r->ctx, in->p) : strdup("{\"error\":\"not available\"}");
        put(outq, reply, strlen(reply));
        put(outq, "\n", 1);
        free(reply);
        size_t used = (size_t)(nl - in->p) + 1;
        memmove(in->p, in->p + used, in->len - used);
        in->p[in->len -= used] = '\0';
    }
}

/* Child side of fork: only async-signal-safe-ish calls, then exec. */
static void child(char **argv, char **envp, const char *root, int in, int out, int err, int sock) {
    int src[4] = {in, out, err, sock};
    for (int i = 0; i < 4; i++) src[i] = fcntl(src[i], F_DUPFD, 10);   /* clear of 0..3 before dup2 */
    setsid();
    for (int i = 0; i < 4; i++) dup2(src[i], i);
    int max = getdtablesize() < 65536 ? getdtablesize() : 65536;
    for (int fd = 4; fd < max; fd++) close(fd);
    struct rlimit core = {0, 0};
    setrlimit(RLIMIT_CORE, &core);
    signal(SIGPIPE, SIG_DFL);
    sigset_t none;
    sigemptyset(&none);
    sigprocmask(SIG_SETMASK, &none, NULL);
    if (chdir(root) != 0) _exit(126);
    environ = envp;
    execvp(argv[0], argv);
    _exit(127);
}

int fleet_run(const struct fleet_run *r, char **out) {
    char *root = canon(r->root), *tmp = NULL, *cache = NULL, *tool = NULL;
    char **argv = NULL, **envp = NULL;
    int rc = 1, pin[2] = {-1, -1}, pout[2] = {-1, -1}, perr[2] = {-1, -1}, sv[2] = {-1, -1};
    struct buf obuf = {0}, ebuf = {0}, sin = {0}, sout = {0};
    pid_t pid = -1;

    if (!root) {
        *out = fmt("cannot resolve project root %s", r->root);
        return 1;
    }
    char *db = r->db_path && *r->db_path ? canon(r->db_path) : NULL;
    size_t rl = strlen(root);
    if (db && strncmp(db, root, rl) == 0 && (root[rl - 1] == '/' || db[rl] == '/')) {
        free(db);
        free(root);
        *out = fmt("fleet tools are disabled here because the knowledge DB is inside this project; move CNTCTR_DB");
        return 1;
    }
    free(db);
    if (!on_path("sandbox-exec") && !on_path("bwrap")) {
        free(root);
        *out = fmt("fleet tools need sandbox-exec or bwrap; neither found");
        return 1;
    }

    const char *base = getenv("TMPDIR") && *getenv("TMPDIR") ? getenv("TMPDIR") : "/tmp";
    char *tmpl = fmt("%s/cntctr-tool.XXXXXX", base);
    if (!mkdtemp(tmpl)) {
        *out = fmt("cannot create a temp dir under %s: %s", base, strerror(errno));
        free(tmpl);
        free(root);
        return 1;
    }
    tmp = canon(tmpl);
    free(tmpl);
    cache = fleet_cache_dir(root);
    if (!tmp || !cache) {
        *out = fmt("cannot set up the tool's temp and cache dirs");
        goto done;
    }
    const char *sub[] = {"xdg", "npm", "pip", "go"};
    for (int i = 0; i < 4; i++) {
        char *d = fmt("%s/%s", cache, sub[i]);
        mkdir(d, 0755);
        free(d);
    }
    tool = fmt("%s/tool", tmp);
    FILE *f = fopen(tool, "w");
    if (!f || fputs(r->script, f) == EOF || fclose(f) != 0) {
        *out = fmt("cannot write the tool script: %s", strerror(errno));
        goto done;
    }
    argv = sandbox_argv(r, root, tmp, cache, tool);
    if (!argv) {
        *out = fmt("fleet tools need sandbox-exec or bwrap; neither found");
        goto done;
    }
    envp = tool_env(root, tmp, cache);

    if (pipe(pin) || pipe(pout) || pipe(perr) || socketpair(AF_UNIX, SOCK_STREAM, 0, sv)) {
        *out = fmt("cannot create pipes: %s", strerror(errno));
        goto done;
    }
    int all[] = {pin[0], pin[1], pout[0], pout[1], perr[0], perr[1], sv[0], sv[1]};
    for (int i = 0; i < 8; i++) fcntl(all[i], F_SETFD, FD_CLOEXEC);   /* so a concurrent fork elsewhere does not inherit them */
    pid = fork();
    if (pid < 0) {
        *out = fmt("cannot fork: %s", strerror(errno));
        goto done;
    }
    if (pid == 0) child(argv, envp, root, pin[0], pout[1], perr[1], sv[1]);
    close_fd(&pin[0]);
    close_fd(&pout[1]);
    close_fd(&perr[1]);
    close_fd(&sv[1]);
    int win = pin[1], rout = pout[0], rerr = perr[0], sock = sv[0];
    pin[1] = pout[0] = perr[0] = sv[0] = -1;
    set_nonblock(win), set_nonblock(rout), set_nonblock(rerr), set_nonblock(sock);

    put(&sin, r->args_json ? r->args_json : "{}", strlen(r->args_json ? r->args_json : "{}"));
    put(&sin, "\n", 1);
    size_t woff = 0, soff = 0;
    long long deadline = now_ms() + (long long)r->timeout * 1000;
    struct buf req = {0};
    int capped = 0, timed_out = 0, status = 0, exited = 0;
    put(&req, "", 0);

    while (!exited) {
        long long left = deadline - now_ms();
        if (left <= 0) {
            timed_out = 1;
            break;
        }
        struct pollfd pf[4] = {
            {win, win >= 0 ? POLLOUT : 0, 0}, {rout, POLLIN, 0}, {rerr, POLLIN, 0},
            {sock, (short)(POLLIN | (sout.len > soff ? POLLOUT : 0)), 0}};
        poll(pf, 4, left < 100 ? (int)left : 100);

        if (win >= 0) {
            ssize_t w = write(win, sin.p + woff, sin.len - woff);
            if (w > 0) woff += (size_t)w;
            if (woff == sin.len || (w < 0 && errno != EAGAIN && errno != EINTR)) close_fd(&win);
        }
        capped = drain(&rout, &obuf, OUT_CAP) || capped;
        capped = drain(&rerr, &ebuf, ERR_CAP) || capped;
        if (sock >= 0) {
            drain(&sock, &req, LINE_CAP);
            if (req.len >= LINE_CAP) close_fd(&sock);
            serve_lines(r, &req, &sout);
            while (sock >= 0 && soff < sout.len) {
                ssize_t w = write(sock, sout.p + soff, sout.len - soff);
                if (w > 0) soff += (size_t)w;
                else if (w < 0 && errno == EINTR) continue;
                else {
                    if (w < 0 && errno != EAGAIN) close_fd(&sock);
                    break;
                }
            }
            if (soff == sout.len) sout.len = soff = 0;
        }
        if (capped) break;
        siginfo_t si = {0};
        if (waitid(P_PID, (id_t)pid, &si, WEXITED | WNOHANG | WNOWAIT) == 0 && si.si_pid == pid) exited = 1;
    }
    if (exited) {   /* take what the tool wrote last, then stop stragglers it left holding the pipes */
        capped = drain(&rout, &obuf, OUT_CAP) || capped;
        capped = drain(&rerr, &ebuf, ERR_CAP) || capped;
    }
    killpg(pid, SIGKILL);
    while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {}
    pid = -1;
    close_fd(&win), close_fd(&rout), close_fd(&rerr), close_fd(&sock);
    free(req.p);

    if (timed_out) {
        char *head = fmt("tool %s timed out after %d s", r->name, r->timeout);
        *out = error_with(head, &ebuf);
        free(head);
    } else if (capped) {
        char *text = result_text(obuf.p ? obuf.p : "", obuf.len);
        *out = fmt("%s\ntool %s was stopped: output over %d KB", text, r->name, OUT_CAP / 1024);
        free(text);
    } else if (!WIFEXITED(status) || WEXITSTATUS(status) != 0) {
        char *head = WIFEXITED(status) ? fmt("tool %s exited with status %d", r->name, WEXITSTATUS(status))
                                       : fmt("tool %s was killed by signal %d", r->name, WTERMSIG(status));
        *out = error_with(head, &ebuf);
        free(head);
    } else {
        *out = result_text(obuf.p ? obuf.p : "", obuf.len);
        rc = 0;
    }
done:
    if (pid > 0) {
        killpg(pid, SIGKILL);
        waitpid(pid, NULL, 0);
    }
    int *fds[] = {&pin[0], &pin[1], &pout[0], &pout[1], &perr[0], &perr[1], &sv[0], &sv[1]};
    for (int i = 0; i < 8; i++) close_fd(fds[i]);
    if (tmp) rm_rf(tmp);
    if (argv) free_strv(argv);
    if (envp) free_strv(envp);
    free(obuf.p), free(ebuf.p), free(sin.p), free(sout.p);
    free(tmp), free(cache), free(tool), free(root);
    return rc;
}
