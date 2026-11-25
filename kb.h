/* The knowledge store: SQLite + FTS5. Knows nothing about tmux, MCP or processes. */
#ifndef KB_H
#define KB_H
#include <limits.h>
#include <sqlite3.h>
#include <time.h>
#ifndef PATH_MAX
#define PATH_MAX 4096
#endif

/* What a new entry holds; kb_put fills in id, machine and times. NULL body, tags
 * and refs are stored as empty text. */
struct kb_entry {
    const char *layer, *scope, *title, *summary, *body, *tags, *refs, *author, *agent, *visibility;
};

/* Test builds (cntctr-test) must never open the user's real knowledge DB: kb_test_guard aborts when CNTCTR_DB is unset or
 * `path` is the real ~/.local/share/cntctr/kb.db. A no-op in the production build. */
#ifdef CNTCTR_TEST_HOOKS
void kb_test_guard(const char *path);
#else
#define kb_test_guard(path) ((void)(path))
#endif
sqlite3 *kb_open_timeout(const char *path, char **err, int timeout_ms);
sqlite3 *kb_open(const char *path, char **err);   /* creates the schema; *err is malloc'd on failure */
int kb_put(sqlite3 *db, const struct kb_entry *e, char id[64]);   /* 0, or -1 */
int kb_lookup(sqlite3 *db, const char *id, char layer[16], long long *mem_id);   /* 0 if found */
char *kb_show(sqlite3 *db, const char *id);   /* every field, or NULL */
/* Entry lists are "id [layer] title — summary" lines, "" when empty. The caller frees them.
 * s2 may be NULL; layer NULL means insight, skill and doc (plus history in kb_search if `history`). */
char *kb_index(sqlite3 *db, const char *s1, const char *s2, const char *layer, const char *since, int limit);
char *kb_search(sqlite3 *db, const char *s1, const char *s2, const char *query, const char *layer, int history, int limit);
char *kb_by_mem(sqlite3 *db, long long mem_id);   /* the live entry mirrored as claude-mem `mem_id`, or NULL */
int kb_supersede(sqlite3 *db, const char *id, const char *by);   /* 0, or -1 if no such entry */
void kb_set_mem(sqlite3 *db, const char *id, long long mem_id);
char *kb_meta_get(sqlite3 *db, const char *k);
void kb_meta_set(sqlite3 *db, const char *k, const char *v);
char *kb_project_get(sqlite3 *db, const char *root);
void kb_project_set(sqlite3 *db, const char *root, const char *key);   /* an empty key removes the override */
int kb_post(sqlite3 *db, const char *scope, const char *sender, const char *text);   /* 0, or -1 */
char *kb_tool_projects(sqlite3 *db);   /* every project with a tool row, one per line (not global) */
/* Recipient by name within the project socket, or by current bound pane. */
#define KB_MAIL_PANE(m, pane_arg) \
    "(" m ".socket || char(10) || " m ".pane=" pane_arg " AND " pane_arg "!='')"
#define KB_MAIL_FOR(m, name_arg, scope_arg, socket_arg, pane_arg, start_arg) \
    "((" m ".name=" name_arg " AND " name_arg "!='' AND posts.scope=" scope_arg \
    " AND " m ".socket IN (" socket_arg ",'')) OR (" KB_MAIL_PANE(m, pane_arg) " AND posts.at>" start_arg "))"
#define KB_MAIL_BOUND(m, socket_arg, pane_arg, start_arg) \
    "(" m ".socket!='' AND " m ".pane!='' AND " start_arg ">0 AND " \
    KB_MAIL_PANE(m, "(" socket_arg "||char(10)||" pane_arg ")") ")"
#define KB_MAIL_ATTACHED(m, socket_arg, pane_arg, start_arg) \
    "(" KB_MAIL_BOUND(m, socket_arg, pane_arg, start_arg) " AND posts.at>" start_arg ")"
/* Insert, claim and finish can share the caller's short write transaction.
 * Claim returns the attempt number, zero if ineligible, or -1 on error. */
long long kb_mail_insert(sqlite3 *db, const char *scope, const char *pane, const char *name, const char *sender,
                         const char *task, const char *body, int hooked, const char *from_pane,
                         const char *from_scope, const char *socket);
int kb_mail_claim(sqlite3 *db, long long post, const char *socket, const char *pane, long long server_start,
                  const char *token, int full, int presentations, time_t now, time_t until, int new_post);
enum kb_mail_finish { KB_MAIL_READ, KB_MAIL_STOP, KB_MAIL_TERMINAL };
int kb_mail_finish(sqlite3 *db, long long post, enum kb_mail_finish outcome, int attempt, const char *token,
                   time_t now); /* 1 finished, 0 unmatched, -1 error */
int kb_mail_reconcile(sqlite3 *db, time_t now, int wake_sec); /* SQLite result code */
char *kb_board_mail(sqlite3 *db, const char *scope, const char *me, const char *pane, const char *socket, long long server_start, int limit);
char *kb_board(sqlite3 *db, const char *scope, const char *me, const char *pane, const char *socket, long long server_start, int limit);   /* "<UTC time> <sender>: <text>" lines, oldest first */

/* Fleet tools: script-backed MCP tools. Drafts are private to their author; see the spec's "Resolving a name". */
struct kb_tool {
    char project[1024], name[64], status[16], interpreter[16], author[128];
    int version, net, timeout;
    char *description, *input_schema, *script;
};
void kb_tool_free(struct kb_tool *t);
int kb_tool_save_draft(sqlite3 *db, const char *project, const char *author, const char *author_model,
                       const char *name, const char *description, const char *schema,
                       const char *interpreter, const char *script, int net, int timeout);   /* replaces the author's draft; 0, or -1 */
/* 0 found, 1 revoked (t->status is "revoked"), -1 unknown. Free t with kb_tool_free. */
int kb_tool_resolve(sqlite3 *db, const char *project, const char *name,
                    const char *caller_name, const char *caller_pane, struct kb_tool *t);
char *kb_tool_names(sqlite3 *db, const char *project, const char *caller_name, const char *caller_pane);   /* names with any candidate row, one per line; the caller resolves each */
void kb_tool_count(sqlite3 *db, const struct kb_tool *t, int ok); /* one more call on t's row, and a failure unless ok */
char *kb_tool_reason(sqlite3 *db, const struct kb_tool *t);       /* why t was revoked or rejected; malloc'd, may be "" */
char *kb_tool_field(sqlite3 *db, const char *project, const char *name, int version, const char *column);   /* one text column of a version, or NULL */
/* Promote the author's draft to a new pending version (deadline in 20 min), rejecting older pending and escalated ones.
 * *superseded gets "<pane>\t<review_root>\n" per pending review that was closed (caller frees). 0, or -1 (no draft). */
int kb_tool_define(sqlite3 *db, const char *project, const char *author, const char *author_model,
                   const char *name, const char *description, const char *schema,
                   const char *interpreter, const char *script, int net, int timeout,
                   int publish, int *version, char **superseded);
int kb_tool_publish(sqlite3 *db, const char *project, const char *author, const char *name, int *version, char **superseded);
int kb_tool_bind(sqlite3 *db, const char *project, const char *name, int version,
                 const char *pane, const char *model, const char *review_root);   /* rows changed: 0 or 1 */
int kb_tool_escalate(sqlite3 *db, const char *project, const char *name, int version);   /* pending -> escalated; rows changed */
/* 0 applied. -1 not applied; status is the row's current status, "unbound" (pending, no reviewer yet), "unknown" or "busy". */
int kb_tool_verdict(sqlite3 *db, const char *project, const char *name, int version, const char *pane,
                    const char *verdict, const char *reason, char status[16]);
/* Escalate pending rows past their deadline, once. "<pane>\t<review_root>\t<name>\t<version>\n" per row. */
char *kb_tool_expire(sqlite3 *db, const char *project);
int kb_tool_revoke(sqlite3 *db, const char *project, const char *name, const char *reason, char **reviews);   /* active, pending and escalated -> revoked; rows changed. *reviews: "<pane>	<review_root>" of the pending ones */
int kb_tool_live(sqlite3 *db, const char *review_root);   /* a pending row owns this review dir (its stored review_root) */
/* Human controls (CLI only). Lists are lines, "" when empty; the caller frees them. */
char *kb_tool_list(sqlite3 *db, const char *project);                 /* one line per tool: name, live version, status, net, calls, failures, promote? */
char *kb_tool_show(sqlite3 *db, const char *project, const char *name);   /* every version in project and global, with its script */
/* Approve or reject the newest pending or escalated version. 0 applied (*version, *reviews as in kb_tool_revoke), or -1 none. */
int kb_tool_resolve_human(sqlite3 *db, const char *project, const char *name, int approve, int *version, char **reviews);
/* Copy the project's active version *from to global as a new active *version, revoking the previous one. 0, or -1 (no active version). */
int kb_tool_promote(sqlite3 *db, const char *project, const char *name, int *from, int *version);
char *kb_unread(sqlite3 *db, const char *scope, const char *me, const char *pane, const char *socket, long long server_start, long long after, long long *newest, int *count);
int kb_omitted(sqlite3 *db, const char *scope, const char *me, const char *pane, const char *socket, long long server_start, long long after, int limit, int *mail_omitted);

/* Code mode: downstream MCP servers, per-instance catalogs, per-project grants, and stored runs. */
enum code_class { CODE_READ = 1, CODE_WRITE = 2, CODE_DESTRUCTIVE = 3 };
/* code_grants.project of the user-wide policy a human sets with `cntctr code grant --all-projects`: access read/deny only,
 * human only, user-scoped servers only. Real project keys are absolute roots, so it cannot collide with one. A rule of this
 * scope applies in every project where its server is effective; a project-local access rule beats it, a deny from either
 * scope denies. */
#define KB_CODE_ALL_PROJECTS "*"
struct code_server_row {
    char scope_project[PATH_MAX], name[64], reg_id[64], trust[16], created_by[128];
    int isolated; long long created_at;
    char *command, *args_json, *env_json;
};
void kb_code_server_free(struct code_server_row *s);
/* Fresh reg_id on insert/replace; in BEGIN IMMEDIATE deletes old code_grants & code_catalogs for old reg_id
 * and sets *dropped_grants / *dropped_projects. If from_mcp != 0, refuses (-2) when any granted_by='human' row
 * exists for old reg_id, or when scope_project != "" tries to shadow an existing user-scoped server name. */
int kb_code_server_put(sqlite3 *db, const struct code_server_row *s, int from_mcp, char reg_id_out[64],
                       int *dropped_grants, int *dropped_projects);
/* Checked variant (Sol R4-01): inside BEGIN IMMEDIATE rechecks expected_reg_id (if non-NULL) and human_approved
 * before replacing; returns -3 if the approval no longer covers the change. */
int kb_code_server_put_checked(sqlite3 *db, const struct code_server_row *s, int from_mcp,
                               const char *expected_reg_id, int human_approved, char reg_id_out[64],
                               int *dropped_grants, int *dropped_projects);
int kb_code_server_get(sqlite3 *db, const char *project, const char *name, struct code_server_row *out); /* project shadows user ('') */
int kb_code_server_inspect(sqlite3 *db, const char *scope_project, const char *name,
                           char reg_id_out[64], int *has_human_grants); /* exact scope: 0 found, -1 missing, -2 DB error */
int kb_code_server_del(sqlite3 *db, const char *scope_project, const char *name, int from_mcp,
                       int *dropped_grants, int *dropped_projects); /* rows changed, or -2 if blocked by human rows */
int kb_code_server_del_checked(sqlite3 *db, const char *scope_project, const char *name, int from_mcp,
                               const char *expected_reg_id, int human_approved,
                               int *dropped_grants, int *dropped_projects); /* rows changed, -2 MCP blocked, -3 stale */
int kb_code_server_has_human_grants(sqlite3 *db, const char *scope_project, const char *name); /* 1 yes, 0 no, -1 DB error */
char *kb_code_server_list_json(sqlite3 *db, const char *project); /* emits env_keys, never env values */

/* Per-instance catalog keyed by (reg_id, owner_project): owner_project="" for user-shared, project for --project/--isolated. */
int kb_code_catalog_get(sqlite3 *db, const char *reg_id, const char *owner_project,
                        char **tools_json_out, long long *meta_gen_out); /* 0 found, -1 empty */
int kb_code_catalog_set(sqlite3 *db, const char *reg_id, const char *owner_project,
                        const char *tools_json, long long *meta_gen_out);

/* kind='access': level in ('allow','read','deny'); v1 'allow' rejects wildcards (*, ?).
 * kind='class':  level in ('class:write','class:destructive').
 * If from_mcp != 0, refuses to replace/delete any existing row with granted_by='human' (returns -2). */
int kb_code_grant_put(sqlite3 *db, const char *project, const char *reg_id, const char *server,
                      const char *pattern, const char *kind, const char *level,
                      const char *class_at_grant, const char *granted_by, const char *reason, int from_mcp);
int kb_code_grant_del(sqlite3 *db, const char *project, const char *reg_id, const char *pattern,
                      const char *kind, int from_mcp); /* rows changed, or -2 if blocked by human row */
/* Checked variants (Sol R4-01, CODE-ADMIN-03): inside BEGIN IMMEDIATE they re-verify what the decision depended on and
 * return -3 when any of it changed (the caller re-inspects and re-confirms):
 *  - server_name (NULL for virtual "cntctr"): the effective registration (project row, else user row) is still reg_id;
 *  - snapshot: kb_code_grant_snapshot() taken before deciding still matches (rules of this reg_id + catalog generation);
 *  - policy_key: meta[policy_key] is still "allow" (an orchestrator's destructive grant);
 *  - !human_approved: no human deny/class rule would be replaced or removed. */
struct kb_code_grant_guard {
    const char *server_name;
    const char *snapshot, *snapshot_owner;
    const char *snapshot_policy_key;   /* policy key the snapshot included (NULL: none) */
    const char *policy_key;
    int human_approved;
};
/* One injective, length-prefixed string of the rules, catalog generation and (optional) policy a decision reads,
 * collected in a single read transaction. NULL on any DB error (callers deny). *policy_out: the policy value read. */
char *kb_code_grant_snapshot(sqlite3 *db, const char *project, const char *reg_id, const char *owner_project,
                             const char *policy_key, char **policy_out);
int kb_code_grant_put_checked(sqlite3 *db, const char *project, const char *reg_id, const char *server,
                              const char *pattern, const char *kind, const char *level,
                              const char *class_at_grant, const char *granted_by, const char *reason,
                              int from_mcp, const struct kb_code_grant_guard *guard);
int kb_code_grant_del_checked(sqlite3 *db, const char *project, const char *reg_id, const char *pattern,
                              const char *kind, int from_mcp, const struct kb_code_grant_guard *guard);
/* 0, or -2 on a DB error. has_human: a human row exists; human_protected: a human deny or class:* row exists. */
int kb_code_grant_inspect(sqlite3 *db, const char *project, const char *reg_id, const char *pattern,
                          const char *kind, int *has_human, int *human_protected);
char *kb_code_server_shadows_json(sqlite3 *db, const char *name); /* project roots with a project-local row, NULL on error */
int kb_code_has_non_deny_grant(sqlite3 *db, const char *project, const char *reg_id); /* for lazy discovery gate */
/* 1 if `project` has an effective server (its own, or a user-scoped one it does not shadow) with a non-deny access rule
 * that applies to it (its own or all-projects); 0 if not, -1 on a DB error. The built-in cntctr server never counts. */
int kb_code_project_has_usable(sqlite3 *db, const char *project);
int kb_code_reg_user_scoped(sqlite3 *db, const char *reg_id); /* 1 user-scoped server, 0 project-local or unknown (an --all-projects rule can only bind a user-scoped one) */
/* Lists grants filtered to project's currently effective reg_ids plus virtual "cntctr". */
char *kb_code_grant_list_json(sqlite3 *db, const char *project, const char *server);
/* Two-pass check for (project, reg_id, tool). Returns 0 allowed, 1 denied (*why malloc'd), -1 the rule lookup itself
 * failed (invalid parameters or a DB error; *why says so). Both non-zero results deny; -1 is never an ordinary denial. */
int kb_code_check_grant(sqlite3 *db, const char *project, const char *reg_id, const char *tool,
                        enum code_class base_class, enum code_class *effective_out, char **why);

int kb_code_run_save(sqlite3 *db, const char *id, const char *project, const char *caller,
                     const char *script_hash, const char *result, const char *logs,
                     const char *calls, const char *denied, int retained_capped, int ttl_sec);
/* 0 ok (*slice malloc'd, UTF-8 aligned, limit clamped to 64 KiB), 1 expired, -1 not found/error. */
int kb_code_run_expand(sqlite3 *db, const char *project, const char *id, const char *part,
                       size_t offset, size_t limit, char **slice, size_t *total_len, int *retained_capped,
                       size_t *start_out); /* start_out: byte offset the slice really starts at (UTF-8 aligned); -2: store error */
int kb_code_run_sweep(sqlite3 *db, time_t now);
#endif
