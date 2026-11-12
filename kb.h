/* The knowledge store: SQLite + FTS5. Knows nothing about tmux, MCP or processes. */
#ifndef KB_H
#define KB_H
#include <sqlite3.h>

/* What a new entry holds; kb_put fills in id, machine and times. NULL body, tags
 * and refs are stored as empty text. */
struct kb_entry {
    const char *layer, *scope, *title, *summary, *body, *tags, *refs, *author, *agent, *visibility;
};

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
char *kb_board(sqlite3 *db, const char *scope, const char *me, const char *pane, int limit);   /* "<UTC time> <sender>: <text>" lines, oldest first */

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
char *kb_unread(sqlite3 *db, const char *scope, const char *me, const char *pane, long long after, long long *newest, int *count);
int kb_omitted(sqlite3 *db, const char *scope, const char *me, const char *pane, long long after, int limit);
#endif
