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
static int live_calls;                                        /* tools/call threads still running */

static char client_name[64] = "agent";   /* clientInfo.name from initialize */
static char self_pane[32];               /* our tmux pane id, e.g. "%3"; empty outside tmux */

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

static const char *sarg(json_object *o, const char *key) {
    json_object *v;
    return json_object_object_get_ex(o, key, &v) && json_object_is_type(v, json_type_string)
        ? json_object_get_string(v) : NULL;
}

/* ---- dispatch ---- */

typedef int (*tool_fn)(json_object *args, char **res);
static const struct { const char *name; tool_fn fn; int needs_pane; } TOOL_FNS[] = {
    {NULL, NULL, 0},
};

static int dispatch(const char *name, json_object *args, char **res) {
    for (int i = 0; TOOL_FNS[i].name; i++) {
        if (strcmp(TOOL_FNS[i].name, name ? name : "") != 0) continue;
        if (TOOL_FNS[i].needs_pane && !*self_pane) return fail(res, fmt("cntctr is not running inside a tmux pane"));
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
    "\"wait\":{\"type\":\"boolean\"},"
    "\"timeout\":{\"type\":\"integer\",\"description\":\"Seconds to block when wait=true (default 600)\"}},"
    "\"required\":[\"harness\",\"name\",\"task\"]}},"
    "{\"name\":\"send\",\"description\":\"Send a message to another agent's terminal. Returns the message id at once. "
    "With wait=true, blocks until the receiver calls reply; if the timeout passes first, the reply arrives in your terminal later.\","
    "\"inputSchema\":{\"type\":\"object\",\"properties\":{"
    "\"to\":{\"type\":\"string\"},\"text\":{\"type\":\"string\"},\"wait\":{\"type\":\"boolean\"},"
    "\"timeout\":{\"type\":\"integer\",\"description\":\"Seconds to block when wait=true (default 600)\"}},"
    "\"required\":[\"to\",\"text\"]}},"
    "{\"name\":\"reply\",\"description\":\"Answer a message you received. Use the id from its [cntctr from=... id=...] header. "
    "Always reply when you finish a task another agent gave you.\","
    "\"inputSchema\":{\"type\":\"object\",\"properties\":{\"id\":{\"type\":\"string\"},\"text\":{\"type\":\"string\"}},"
    "\"required\":[\"id\",\"text\"]}},"
    "{\"name\":\"list\",\"description\":\"List agents: name, harness, tmux pane, alive or dead.\","
    "\"inputSchema\":{\"type\":\"object\",\"properties\":{}}},"
    "{\"name\":\"kill\",\"description\":\"Close an agent's tmux pane.\","
    "\"inputSchema\":{\"type\":\"object\",\"properties\":{\"name\":{\"type\":\"string\"}},\"required\":[\"name\"]}}"
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
    json_object *req = arg, *id = NULL, *params = NULL, *args = NULL;
    json_object_object_get_ex(req, "id", &id);
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
    json_object_put(req);

    pthread_mutex_lock(&live_mu);
    if (--live_calls == 0) pthread_cond_signal(&live_cv);
    pthread_mutex_unlock(&live_mu);
    return NULL;
}

/* Run a tools/call on its own thread so a blocking send doesn't hold up other calls. */
static void start_call(json_object *req) {
    pthread_t thread;
    pthread_mutex_lock(&live_mu);
    live_calls++;
    pthread_mutex_unlock(&live_mu);
    if (pthread_create(&thread, NULL, call_thread, req) == 0) pthread_detach(thread);
    else call_thread(req);   /* out of threads: run it inline */
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
    else if (id) respond_error(id, -32601, "method not found");   /* notifications need no answer */
    json_object_put(req);
}

int main(void) {
    signal(SIGPIPE, SIG_IGN);
    char *line = NULL;
    size_t cap = 0;
    while (getline(&line, &cap, stdin) > 0) handle(line);
    free(line);
    /* ponytail: on EOF we wait for in-flight calls, blocking ones included (up to their
     * timeout). Cancel them instead if orphaned servers turn out to linger. */
    pthread_mutex_lock(&live_mu);
    while (live_calls > 0) pthread_cond_wait(&live_cv, &live_mu);
    pthread_mutex_unlock(&live_mu);
    return 0;
}
