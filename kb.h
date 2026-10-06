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
#endif
