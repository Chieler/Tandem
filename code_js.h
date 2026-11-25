/* QuickJS script runner on a sized pthread with refcounted async tool bridge. */
#ifndef CODE_JS_H
#define CODE_JS_H

#include <stddef.h>
#include <json-c/json.h>
#include "kb.h"

enum code_call_status { CODE_CALL_OK = 0, CODE_CALL_ERROR = 1, CODE_CALL_DENIED = 2 };

struct code_tool_meta {
    char *server, *reg_id, *name, *description;
    long long meta_gen;
    enum code_class base_class;
    json_object *input_schema; /* owned json_object_get ref, released on catalog free */
};

struct code_server_hint { char *name, *reg_id; int has_catalog; }; /* lets bridge lazy-discover granted unindexed servers */

/* Refcounted completion token (refcount=2: run + dispatcher). Payload copied under mutex in code_js_complete. */
struct code_call_handle;
void code_call_handle_unref(struct code_call_handle *h);
void code_js_complete(struct code_call_handle *h, enum code_call_status status,
                      const char *payload_text, int is_json, const char *grant_cmd_or_null);

/* Takes an OWNED json_object *args ref (callee must json_object_put); server/reg_id/tool copied by callee. */
typedef void (*code_dispatch_fn)(void *ctx, const char *server, const char *reg_id, long long meta_gen,
                                 const char *tool, json_object *args_owned, int timeout_ms,
                                 struct code_call_handle *h);
typedef void (*code_cancel_call_fn)(void *ctx, struct code_call_handle *h);

struct code_run_cancel;
struct code_run_cancel *code_run_cancel_new(void);
void code_run_cancel_signal(struct code_run_cancel *c, const char *reason); /* wakes condvar immediately */
void code_run_cancel_free(struct code_run_cancel *c);

struct code_run_opts {
    const char *db_path, *project, *script;
    const char *const *scope; size_t nscope;
    const struct code_tool_meta *catalog; size_t ncatalog;
    const struct code_server_hint *servers; size_t nservers;
    size_t max_mb, max_stack_bytes, result_cap_bytes, calls_preview_bytes, max_log_bytes, max_queue_bytes;
    int cpu_sec, wall_sec, call_sec, max_inflight;
    struct code_run_cancel *cancel;
    code_dispatch_fn dispatch; code_cancel_call_fn cancel_call; void *dispatch_ctx;
};

struct code_run_out {
    int is_error, retained_capped;
    char *result, *logs, *calls, *denied;
    char *result_preview, *logs_preview, *calls_preview, *denied_preview; /* all 4 bounded with expand offsets */
};

void code_run_out_free(struct code_run_out *o);
/* Always executes on a dedicated pthread with stack size >= max_stack_bytes + 8 MiB. */
int code_js_run(const struct code_run_opts *opts, struct code_run_out *out);

#endif
