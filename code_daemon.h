/* Per-user code-mode daemon, Unix socket IPC, lockfile, and deadlock-free semver drain. */
#ifndef CODE_DAEMON_H
#define CODE_DAEMON_H

#include <limits.h>
#include <pthread.h>
#include <json-c/json.h>
#include "kb.h"

#ifndef PATH_MAX
#define PATH_MAX 4096
#endif

#define CODE_PROTO_VERSION 1

/* Register cntctr executable path, version string, and fork_mu once at startup. */
void code_daemon_init(const char *exe_path, const char *version, pthread_mutex_t *fork_mu);

/* Default: dirname(kb_path)/code.sock, or $CNTCTR_CODE_SOCK. Fails naming CNTCTR_CODE_SOCK if >= sizeof(sa.sun_path). */
int code_sock_path(char out[PATH_MAX], char **err);
int code_canon_db(char out[PATH_MAX], char **err); /* realpath(dirname) + "/" + basename */
int code_daemon_main(const char *sock_path, const char *db_path);
int code_client_probe(json_object **status_out, char **err); /* never autostarts */

typedef int (*code_cancelled_fn)(void *ctx);
/* Reverse-RPC callback. `reply(rctx, resp)` is thread-safe and backed by a refcounted connection
 * handle, so `rev` may dispatch asynchronously; `rev` owns `rctx` and must call `reply(rctx, resp)`
 * exactly once (passing resp == NULL drops the token without sending a reply). */
typedef void (*code_rev_fn)(void *ctx, json_object *req, void (*reply)(void *rctx, json_object *resp), void *rctx);

/* autostart=1 for MCP paths, autostart=0 for CLI. Polls is_cancelled in <=200 ms slices; guards writes with write_mu. */
int code_client_rpc(json_object *req, int autostart, json_object **resp,
                    code_rev_fn rev, code_cancelled_fn is_cancelled, void *ctx, int timeout_ms, char **err);
int code_status_cmd(int argc, char **argv); /* status [--short|--verbose] | stop; never autostarts */

/* Virtual "cntctr" server (reg_id "cntctr"): the static allowlist and its class table, shared with the admin tools. */
size_t code_cntctr_tool_count(void);
const char *code_cntctr_tool_name(size_t i);
int code_cntctr_tool_class(const char *name, enum code_class *cls); /* 1 allowlisted */

#endif
