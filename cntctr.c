/* cntctr: MCP stdio server that lets terminal agents (Claude Code, Codex, agy)
 * spawn, message, and reply to each other. All state lives in the tmux
 * server; this process keeps none between tool calls. */
#define _DARWIN_C_SOURCE
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <pthread.h>
#include <regex.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
#include <json-c/json.h>

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

/* Paste `text` into `pane` as one bracketed paste, then press Enter.
 * `who` names the pane in errors. Returns NULL or an error (caller frees). */
static char *inject(const char *pane, const char *who, const char *text) {
    if (awaiting_permission(pane)) return fmt("%s awaiting permission prompt; retry later", who);
    char buf[32], *err;
    snprintf(buf, sizeof buf, "cntctr-in-%08x", arc4random());
    if ((err = TMUXE(text, "load-buffer", "-b", buf, "-"))) return err;
    if ((err = TMUXE(NULL, "paste-buffer", "-p", "-d", "-b", buf, "-t", pane))) {
        free(TMUXE(NULL, "delete-buffer", "-b", buf));
        return err;
    }
    struct timespec pause = {enter_delay_ms / 1000, (enter_delay_ms % 1000) * 1000000L};
    nanosleep(&pause, NULL);
    return TMUXE(NULL, "send-keys", "-t", pane, "Enter");
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
    return fmt("[cntctr from=%s id=%s]\n%s\n[when done: call the reply tool of the cntctr MCP server with id=%s and your answer; it is an MCP tool, not a shell command. Your agent name is %s: pass from=%s when you call send, spawn or kill]", caller_name, id, text, id, you, you);
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
    int r = wait ? await_reply(id, pane, to, targ(a), res) : ok(res, fmt("sent id=%s", id));
    free(pane);
    return r;
}

static int tool_reply(json_object *a, char **res) {
    const char *id = sarg(a, "id"), *text = sarg(a, "text");
    if (!id || !text) return fail(res, fmt("reply needs 'id' and 'text'"));
    char opt[48], buf[40], chan[32], *sender = NULL, *waiting, *env, *err;
    snprintf(opt, sizeof opt, "@cntctr_from_%s", id);
    if (strlen(id) != 8 || strspn(id, "0123456789abcdef") != 8 || !(sender = sopt_get(opt)))
        return fail(res, fmt("unknown id %s", id));

    /* Write the buffer before checking the wait flag; await_reply clears the flag
     * before claiming. That ordering means no reply is lost. */
    snprintf(buf, sizeof buf, "cntctr-reply-%s", id);
    if ((err = TMUXE(text, "load-buffer", "-b", buf, "-"))) {
        free(sender);
        return fail(res, err);
    }
    snprintf(opt, sizeof opt, "@cntctr_wait_%s", id);
    if ((waiting = sopt_get(opt))) {   /* sender is blocked in await_reply: wake it */
        free(waiting);
        free(sender);
        snprintf(chan, sizeof chan, "cntctr-%s", id);
        free(TMUXE(NULL, "wait-for", "-S", chan));
        return ok(res, fmt("ok"));
    }
    /* Nobody waiting: type the reply into the sender's pane, unless a timed-out
     * waiter claimed the buffer first. */
    if ((err = TMUXE(NULL, "delete-buffer", "-b", buf))) {
        free(err);
        free(sender);
        return ok(res, fmt("ok"));
    }
    if (!pane_alive(sender)) {
        free(sender);
        untrack(id);
        return fail(res, fmt("sender gone"));
    }
    char *me = NULL;
    snprintf(opt, sizeof opt, "@cntctr_to_%s", id);
    char *to = sopt_get(opt);
    if (to && TMUX(NULL, &me, "show", "-pqv", "-t", to, "@cntctr_name") != 0) *me = '\0';
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

/* ---- dispatch ---- */

typedef int (*tool_fn)(json_object *args, char **res);
static const struct { const char *name; tool_fn fn; int needs_pane; } TOOL_FNS[] = {
    {"list", tool_list, 0},
    {"send", tool_send, 1},
    {"reply", tool_reply, 0},
    {"spawn", tool_spawn, 1},
    {"kill", tool_kill, 1},
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
        if (TOOL_FNS[i].needs_pane && from && *from) {
            char *err = resolve_from(from);
            if (err) return fail(res, err);
        }
        if (TOOL_FNS[i].needs_pane && !*caller_pane)
            return fail(res, fmt("cntctr cannot tell which pane you are in; pass from=<your agent name, or your $TMUX_PANE if you were started by hand>"));
        return TOOL_FNS[i].fn(args, res);
    }
    return fail(res, fmt("unknown tool %s", name ? name : "(none)"));
}

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
    "\"inputSchema\":{\"type\":\"object\",\"properties\":{\"id\":{\"type\":\"string\"},\"text\":{\"type\":\"string\"}},"
    "\"required\":[\"id\",\"text\"]}},"
    "{\"name\":\"list\",\"description\":\"List agents: name, harness, tmux pane, alive or dead.\","
    "\"inputSchema\":{\"type\":\"object\",\"properties\":{}}},"
    "{\"name\":\"kill\",\"description\":\"Close an agent's tmux pane.\","
    "\"inputSchema\":{\"type\":\"object\",\"properties\":{\"name\":{\"type\":\"string\"},\"from\":{\"type\":\"string\",\"description\":\"Who you are, if this fails with a pane error (Codex): your agent name, or $TMUX_PANE\"}},\"required\":[\"name\"]}}"
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
