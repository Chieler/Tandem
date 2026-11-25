/* Downstream stdio MCP client, per-instance catalogs, atomic live recheck, and LRU server pool. */
#ifndef CODE_MCP_H
#define CODE_MCP_H

#include <pthread.h>
#include <stddef.h>
#include <time.h>
#include <json-c/json.h>
#include "kb.h"
#include "code_js.h"

struct code_pool;

/* Register shared fork_mu and client version once at startup. */
void code_mcp_init(const char *version, pthread_mutex_t *fork_mu);

struct code_pool *code_pool_new(const char *db_path, int max_servers, int idle_sec, int call_sec,
                                size_t line_cap_bytes, size_t daemon_queue_bytes);
void code_pool_free(struct code_pool *p);

/* Helper computing owner_project: "" for user-shared, project for --project or --isolated. */
const char *code_owner_project(const struct code_server_row *srv, const char *project);

/* One-shot direct stdio probe (scrubbed env + env_json, full MCP init + paginated tools/list) without
 * starting the daemon; persists code_catalogs(reg_id, owner_project). Used by CLI discover/grant. */
int code_mcp_probe_server(sqlite3 *db, const struct code_server_row *srv, const char *project,
                          int timeout_sec, long long *meta_gen_out, char **err);

/* Daemon pool discovery: lazy-starts instance, runs full MCP init + paginated tools/list, persists code_catalogs. */
int code_pool_discover(struct code_pool *p, const char *project, const char *server_name,
                       char **tools_json_out, long long *meta_gen_out, char **err);

/* Off-thread async dispatch: takes OWNED json_object *args_owned; queues cold start/lazy discover,
 * atomic live grant + schema recheck (even for same-class schema changes or mid-queue grant revocations),
 * and stdio write completely off the QuickJS run thread. */
void code_pool_dispatch(struct code_pool *p, const char *project, const char *server,
                        const char *expected_reg_id, long long expected_meta_gen,
                        const char *tool, json_object *args_owned, int timeout_ms,
                        struct code_call_handle *h);

void code_pool_cancel_call(struct code_pool *p, struct code_call_handle *h);
int code_pool_tick(struct code_pool *p, time_t now);
void code_pool_stop(struct code_pool *p, const char *scope_project, const char *server_name);
/* Exact identity: the instance of registration reg_id owned by owner_project ("" for shared). */
void code_pool_stop_reg(struct code_pool *p, const char *reg_id);
void code_pool_stop_inst(struct code_pool *p, const char *reg_id, const char *owner_project);
void code_pool_reset_crashes_inst(struct code_pool *p, const char *reg_id, const char *owner_project);
void code_pool_reset_crashes(struct code_pool *p, const char *project, const char *server_name);
json_object *code_pool_status_json(struct code_pool *p, long *total_mem_mb, int *nprojects);

#endif
