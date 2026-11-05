/* The knowledge store: entries in SQLite with an FTS5 index. Knows nothing about tmux or MCP. */
#define _DARWIN_C_SOURCE
#include "kb.h"
#include <ctype.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>

static const char SCHEMA[] =
    "CREATE TABLE IF NOT EXISTS entries("
    " id TEXT PRIMARY KEY, layer TEXT NOT NULL, scope TEXT NOT NULL, title TEXT NOT NULL,"
    " summary TEXT NOT NULL, body TEXT NOT NULL DEFAULT '', tags TEXT NOT NULL DEFAULT '',"
    " refs TEXT NOT NULL DEFAULT '', author TEXT, machine TEXT, agent TEXT, visibility TEXT NOT NULL,"
    " created INTEGER, updated INTEGER, superseded_by TEXT, mem_id INTEGER);"
    "CREATE INDEX IF NOT EXISTS entries_scope ON entries(scope, layer, updated);"
    "CREATE INDEX IF NOT EXISTS entries_mem ON entries(mem_id);"
    "CREATE VIRTUAL TABLE IF NOT EXISTS entries_fts USING fts5(title, summary, body, tags,"
    " content='entries', content_rowid='rowid');"
    "CREATE TRIGGER IF NOT EXISTS entries_ai AFTER INSERT ON entries BEGIN"
    " INSERT INTO entries_fts(rowid, title, summary, body, tags) VALUES (new.rowid, new.title, new.summary, new.body, new.tags); END;"
    "CREATE TRIGGER IF NOT EXISTS entries_ad AFTER DELETE ON entries BEGIN"
    " INSERT INTO entries_fts(entries_fts, rowid, title, summary, body, tags)"
    " VALUES ('delete', old.rowid, old.title, old.summary, old.body, old.tags); END;"
    "CREATE TRIGGER IF NOT EXISTS entries_au AFTER UPDATE OF title, summary, body, tags ON entries BEGIN"
    " INSERT INTO entries_fts(entries_fts, rowid, title, summary, body, tags)"
    " VALUES ('delete', old.rowid, old.title, old.summary, old.body, old.tags);"
    " INSERT INTO entries_fts(rowid, title, summary, body, tags) VALUES (new.rowid, new.title, new.summary, new.body, new.tags); END;"
    "CREATE TABLE IF NOT EXISTS projects(root TEXT PRIMARY KEY, key TEXT NOT NULL);"
    "CREATE TABLE IF NOT EXISTS meta(k TEXT PRIMARY KEY, v TEXT);"
    "CREATE TABLE IF NOT EXISTS posts(scope TEXT NOT NULL, sender TEXT NOT NULL, text TEXT NOT NULL, at INTEGER NOT NULL);"
    "CREATE TABLE IF NOT EXISTS tools(project TEXT NOT NULL, name TEXT NOT NULL, version INTEGER NOT NULL,"
    " status TEXT NOT NULL, author TEXT NOT NULL, author_model TEXT NOT NULL DEFAULT '', description TEXT NOT NULL,"
    " input_schema TEXT NOT NULL, interpreter TEXT NOT NULL, script TEXT NOT NULL, net INTEGER NOT NULL DEFAULT 0,"
    " timeout INTEGER NOT NULL DEFAULT 60, source TEXT NOT NULL DEFAULT '', reviewer TEXT, reviewer_pane TEXT,"
    " reviewer_model TEXT, review_root TEXT, deadline INTEGER, verdict_reason TEXT, calls INTEGER NOT NULL DEFAULT 0,"
    " failures INTEGER NOT NULL DEFAULT 0, created INTEGER,"
    " PRIMARY KEY(project, name, version, author));"   /* author: drafts are version 0, one per author */
    "CREATE UNIQUE INDEX IF NOT EXISTS tools_version ON tools(project, name, version) WHERE version > 0;"
    "CREATE INDEX IF NOT EXISTS tools_name ON tools(project, name, status);"
    "INSERT OR IGNORE INTO meta VALUES ('schema', '1');";

static const char *col(sqlite3_stmt *st, int i) {
    const unsigned char *t = sqlite3_column_text(st, i);
    return t ? (const char *)t : "";
}

static sqlite3_stmt *prep(sqlite3 *db, const char *sql) {
    sqlite3_stmt *st = NULL;
    sqlite3_prepare_v2(db, sql, -1, &st, NULL);
    return st;
}

static char *text1(sqlite3 *db, const char *sql, const char *a) {
    sqlite3_stmt *st = prep(db, sql);
    char *r = NULL;
    sqlite3_bind_text(st, 1, a, -1, SQLITE_TRANSIENT);
    if (sqlite3_step(st) == SQLITE_ROW && sqlite3_column_type(st, 0) != SQLITE_NULL) r = strdup(col(st, 0));
    sqlite3_finalize(st);
    return r;
}

static int exec2(sqlite3 *db, const char *sql, const char *a, const char *b) {
    sqlite3_stmt *st = prep(db, sql);
    sqlite3_bind_text(st, 1, a, -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(st, 2, b, -1, SQLITE_TRANSIENT);
    int rc = sqlite3_step(st) == SQLITE_DONE ? sqlite3_changes(db) : -1;
    sqlite3_finalize(st);
    return rc;
}

sqlite3 *kb_open(const char *path, char **err) {
    sqlite3 *db = NULL;
    if (sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, NULL) != SQLITE_OK) {
        *err = strdup(db ? sqlite3_errmsg(db) : "out of memory");
        sqlite3_close(db);
        return NULL;
    }
    sqlite3_busy_timeout(db, 5000);
    sqlite3_exec(db, "PRAGMA journal_mode=WAL", NULL, NULL, NULL);
    char host[256] = "host";
    gethostname(host, sizeof host - 1);
    host[strcspn(host, ".")] = '\0';
    char *machine = sqlite3_mprintf("INSERT OR IGNORE INTO meta VALUES ('machine', '%08x-%q');", arc4random(), host);
    int rc = sqlite3_exec(db, "BEGIN IMMEDIATE", NULL, NULL, NULL);
    if (rc == SQLITE_OK) rc = sqlite3_exec(db, SCHEMA, NULL, NULL, NULL);
    if (rc == SQLITE_OK) rc = sqlite3_exec(db, machine, NULL, NULL, NULL);
    if (rc == SQLITE_OK) rc = sqlite3_exec(db, "COMMIT", NULL, NULL, NULL);
    sqlite3_free(machine);
    if (rc == SQLITE_OK) return db;
    *err = strdup(sqlite3_errmsg(db));
    sqlite3_close(db);
    return NULL;
}

int kb_put(sqlite3 *db, const struct kb_entry *e, char id[64]) {
    char *machine = kb_meta_get(db, "machine");
    struct timeval tv;
    gettimeofday(&tv, NULL);
    long long ms = tv.tv_sec * 1000LL + tv.tv_usec / 1000;
    snprintf(id, 64, "%.8s-%llx-%04x", machine ? machine : "00000000", ms, arc4random() & 0xffff);
    sqlite3_stmt *st = prep(db,
        "INSERT INTO entries(id, layer, scope, title, summary, body, tags, refs, author, machine, agent, visibility,"
        " created, updated) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?13)");
    const char *v[] = {id, e->layer, e->scope, e->title, e->summary, e->body ? e->body : "", e->tags ? e->tags : "",
                       e->refs ? e->refs : "", e->author, machine, e->agent, e->visibility};
    for (int i = 0; i < 12; i++) sqlite3_bind_text(st, i + 1, v[i], -1, SQLITE_TRANSIENT);
    sqlite3_bind_int64(st, 13, ms / 1000);
    int rc = sqlite3_step(st) == SQLITE_DONE ? 0 : -1;
    sqlite3_finalize(st);
    free(machine);
    return rc;
}

int kb_lookup(sqlite3 *db, const char *id, char layer[16], long long *mem_id) {
    sqlite3_stmt *st = prep(db, "SELECT layer, mem_id FROM entries WHERE id = ?1");
    sqlite3_bind_text(st, 1, id, -1, SQLITE_TRANSIENT);
    int found = sqlite3_step(st) == SQLITE_ROW;
    if (found) {
        snprintf(layer, 16, "%s", col(st, 0));
        *mem_id = sqlite3_column_int64(st, 1);
    }
    sqlite3_finalize(st);
    return found ? 0 : -1;
}

char *kb_show(sqlite3 *db, const char *id) {
    sqlite3_stmt *st = prep(db,
        "SELECT id, layer, scope, title, summary, tags, refs, author, machine, agent, visibility,"
        " datetime(created, 'unixepoch'), datetime(updated, 'unixepoch'), superseded_by, body FROM entries WHERE id = ?1");
    sqlite3_bind_text(st, 1, id, -1, SQLITE_TRANSIENT);
    char *r = NULL;
    if (sqlite3_step(st) == SQLITE_ROW) {
        const char *sup = col(st, 13);
        char *s = sqlite3_mprintf("id: %s\nlayer: %s\nscope: %s\ntitle: %s\nsummary: %s\ntags: %s\nrefs: %s\n"
                                  "author: %s@%s (agent %s)\nvisibility: %s\ncreated: %s UTC\nupdated: %s UTC\n%s%s%s\n%s",
                                  col(st, 0), col(st, 1), col(st, 2), col(st, 3), col(st, 4), col(st, 5), col(st, 6),
                                  col(st, 7), col(st, 8), col(st, 9), col(st, 10), col(st, 11), col(st, 12),
                                  *sup ? "superseded_by: " : "", sup, *sup ? "\n" : "", col(st, 14));
        r = strdup(s);
        sqlite3_free(s);
    }
    sqlite3_finalize(st);
    return r;
}

static char *lines(sqlite3_stmt *st) {
    size_t len = 0, cap = 256;
    char *out = malloc(cap);
    *out = '\0';
    while (sqlite3_step(st) == SQLITE_ROW) {
        char *l = sqlite3_column_count(st) == 1 ? sqlite3_mprintf("%s\n", col(st, 0))
                  : sqlite3_mprintf("%s [%s] %s — %s\n", col(st, 0), col(st, 1), col(st, 2), col(st, 3));
        size_t n = strlen(l);
        if (len + n + 1 > cap) out = realloc(out, cap = (len + n + 1) * 2);
        memcpy(out + len, l, n + 1);
        len += n;
        sqlite3_free(l);
    }
    sqlite3_finalize(st);
    if (len) out[len - 1] = '\0';
    return out;
}

char *kb_index(sqlite3 *db, const char *s1, const char *s2, const char *layer, const char *since, int limit) {
    sqlite3_stmt *st = prep(db,
        "SELECT id, layer, title, summary FROM entries"
        " WHERE superseded_by IS NULL AND scope IN (?1, ?2)"
        " AND (layer = ?3 OR (?3 IS NULL AND layer != 'history'))"
        " AND (?5 IS NULL OR created >= CAST(strftime('%s', ?5) AS INTEGER))"
        " ORDER BY scope = ?1 DESC, CASE layer WHEN 'insight' THEN 0 WHEN 'skill' THEN 1 WHEN 'doc' THEN 2 ELSE 3 END,"
        " updated DESC, rowid DESC LIMIT ?4");
    sqlite3_bind_text(st, 1, s1, -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(st, 2, s2, -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(st, 3, layer, -1, SQLITE_TRANSIENT);
    sqlite3_bind_int(st, 4, limit);
    sqlite3_bind_text(st, 5, since, -1, SQLITE_TRANSIENT);
    return lines(st);
}

static char *fts_query(const char *q) {
    char *out = malloc(strlen(q) * 4 + 8), *o = out;
    *o = '\0';
    int words = 0;
    for (const unsigned char *s = (const unsigned char *)q; *s && words < 32;) {
        if (!(isalnum(*s) || *s >= 0x80)) {
            s++;
            continue;
        }
        if (words++) {
            memcpy(o, " OR ", 4);
            o += 4;
        }
        *o++ = '"';
        while (*s && (isalnum(*s) || *s >= 0x80)) *o++ = (char)*s++;
        *o++ = '"';
        *o = '\0';
    }
    return out;
}

char *kb_search(sqlite3 *db, const char *s1, const char *s2, const char *query, const char *layer, int history, int limit) {
    char *match = fts_query(query);
    if (!*match) return match;
    sqlite3_stmt *st = prep(db,
        "SELECT e.id, e.layer, e.title, e.summary FROM entries_fts JOIN entries e ON e.rowid = entries_fts.rowid"
        " WHERE entries_fts MATCH ?5 AND e.superseded_by IS NULL AND e.scope IN (?1, ?2)"
        " AND (e.layer = ?3 OR (?3 IS NULL AND (?6 OR e.layer != 'history')))"
        " ORDER BY bm25(entries_fts) LIMIT ?4");
    sqlite3_bind_text(st, 1, s1, -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(st, 2, s2, -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(st, 3, layer, -1, SQLITE_TRANSIENT);
    sqlite3_bind_int(st, 4, limit);
    sqlite3_bind_text(st, 5, match, -1, SQLITE_TRANSIENT);
    sqlite3_bind_int(st, 6, history);
    free(match);
    return lines(st);
}

char *kb_by_mem(sqlite3 *db, long long mem_id) {
    sqlite3_stmt *st = prep(db, "SELECT id, layer, title, summary FROM entries WHERE mem_id = ?1 AND superseded_by IS NULL LIMIT 1");
    sqlite3_bind_int64(st, 1, mem_id);
    char *r = lines(st);
    if (*r) return r;
    free(r);
    return NULL;
}

int kb_supersede(sqlite3 *db, const char *id, const char *by) {
    return exec2(db, "UPDATE entries SET superseded_by = ?2, updated = CAST(strftime('%s', 'now') AS INTEGER) WHERE id = ?1",
                 id, by) == 1 ? 0 : -1;
}

void kb_set_mem(sqlite3 *db, const char *id, long long mem_id) {
    sqlite3_stmt *st = prep(db, "UPDATE entries SET mem_id = ?2 WHERE id = ?1");
    sqlite3_bind_text(st, 1, id, -1, SQLITE_TRANSIENT);
    sqlite3_bind_int64(st, 2, mem_id);
    sqlite3_step(st);
    sqlite3_finalize(st);
}

char *kb_meta_get(sqlite3 *db, const char *k) { return text1(db, "SELECT v FROM meta WHERE k = ?1", k); }
void kb_meta_set(sqlite3 *db, const char *k, const char *v) { exec2(db, "INSERT OR REPLACE INTO meta VALUES (?1, ?2)", k, v); }
char *kb_project_get(sqlite3 *db, const char *root) { return text1(db, "SELECT key FROM projects WHERE root = ?1", root); }

void kb_project_set(sqlite3 *db, const char *root, const char *key) {
    if (*key) exec2(db, "INSERT OR REPLACE INTO projects VALUES (?1, ?2)", root, key);
    else exec2(db, "DELETE FROM projects WHERE root = ?1", root, NULL);
}

int kb_post(sqlite3 *db, const char *scope, const char *sender, const char *text) {
    sqlite3_stmt *st = prep(db, "INSERT INTO posts VALUES (?1, ?2, ?3, CAST(strftime('%s', 'now') AS INTEGER))");
    sqlite3_bind_text(st, 1, scope, -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(st, 2, sender, -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(st, 3, text, -1, SQLITE_TRANSIENT);
    int rc = sqlite3_step(st) == SQLITE_DONE ? 0 : -1;
    sqlite3_finalize(st);
    return rc;
}

char *kb_tool_projects(sqlite3 *db) {
    return lines(prep(db, "SELECT DISTINCT project FROM tools WHERE project <> 'global'"));
}

char *kb_board(sqlite3 *db, const char *scope, int limit) {
    sqlite3_stmt *st = prep(db,
        "SELECT line FROM (SELECT rowid, datetime(at, 'unixepoch') || ' ' || sender || ': ' || text AS line FROM posts"
        " WHERE scope = ?1 ORDER BY rowid DESC LIMIT ?2) ORDER BY rowid");
    sqlite3_bind_text(st, 1, scope, -1, SQLITE_TRANSIENT);
    sqlite3_bind_int(st, 2, limit);
    return lines(st);
}

/* ---- fleet tools ---- */

void kb_tool_free(struct kb_tool *t) {
    free(t->description);
    free(t->input_schema);
    free(t->script);
    memset(t, 0, sizeof *t);
}

int kb_tool_save_draft(sqlite3 *db, const char *project, const char *author, const char *author_model,
                       const char *name, const char *description, const char *schema,
                       const char *interpreter, const char *script, int net, int timeout) {
    if (sqlite3_exec(db, "BEGIN IMMEDIATE", NULL, NULL, NULL) != SQLITE_OK) return -1;
    sqlite3_stmt *st = prep(db, "DELETE FROM tools WHERE project = ?1 AND name = ?2 AND status = 'draft' AND author = ?3");
    sqlite3_bind_text(st, 1, project, -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(st, 2, name, -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(st, 3, author, -1, SQLITE_TRANSIENT);
    int rc = sqlite3_step(st) == SQLITE_DONE ? 0 : -1;
    sqlite3_finalize(st);
    if (rc == 0) {
        st = prep(db,
            "INSERT INTO tools(project, name, version, status, author, author_model, description, input_schema,"
            " interpreter, script, net, timeout, created) VALUES (?1, ?2, 0, 'draft', ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10,"
            " CAST(strftime('%s', 'now') AS INTEGER))");
        const char *v[] = {project, name, author, author_model, description, schema, interpreter, script};
        for (int i = 0; i < 8; i++) sqlite3_bind_text(st, i + 1, v[i], -1, SQLITE_TRANSIENT);
        sqlite3_bind_int(st, 9, net);
        sqlite3_bind_int(st, 10, timeout);
        rc = sqlite3_step(st) == SQLITE_DONE ? 0 : -1;
        sqlite3_finalize(st);
    }
    if (sqlite3_exec(db, rc == 0 ? "COMMIT" : "ROLLBACK", NULL, NULL, NULL) != SQLITE_OK) rc = -1;
    return rc;
}

/* The newest row of `name` in `project` matching `where` (?1 project, ?2 name, ?3 who), into *t. */
static int tool_row(sqlite3 *db, const char *where, const char *project, const char *name, const char *who, struct kb_tool *t) {
    char *sql = sqlite3_mprintf(
        "SELECT project, name, status, interpreter, author, version, net, timeout, description, input_schema, script"
        " FROM tools WHERE project = ?1 AND name = ?2 AND %s ORDER BY version DESC LIMIT 1", where);
    sqlite3_stmt *st = prep(db, sql);
    sqlite3_free(sql);
    sqlite3_bind_text(st, 1, project, -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(st, 2, name, -1, SQLITE_TRANSIENT);
    if (who) sqlite3_bind_text(st, 3, who, -1, SQLITE_TRANSIENT);
    int found = sqlite3_step(st) == SQLITE_ROW;
    if (found) {
        snprintf(t->project, sizeof t->project, "%s", col(st, 0));
        snprintf(t->name, sizeof t->name, "%s", col(st, 1));
        snprintf(t->status, sizeof t->status, "%s", col(st, 2));
        snprintf(t->interpreter, sizeof t->interpreter, "%s", col(st, 3));
        snprintf(t->author, sizeof t->author, "%s", col(st, 4));
        t->version = sqlite3_column_int(st, 5);
        t->net = sqlite3_column_int(st, 6);
        t->timeout = sqlite3_column_int(st, 7);
        t->description = strdup(col(st, 8));
        t->input_schema = strdup(col(st, 9));
        t->script = strdup(col(st, 10));
    }
    sqlite3_finalize(st);
    return found;
}

int kb_tool_resolve(sqlite3 *db, const char *project, const char *name,
                    const char *caller_name, const char *caller_pane, struct kb_tool *t) {
    memset(t, 0, sizeof *t);
    if (*caller_pane && tool_row(db, "status = 'pending' AND reviewer_pane = ?3", project, name, caller_pane, t)) return 0;
    if (*caller_name && tool_row(db, "status = 'draft' AND author = ?3", project, name, caller_name, t)) return 0;
    const char *scopes[] = {project, "global"};
    for (int i = 0; i < 2; i++)
        if (tool_row(db, "status IN ('active', 'revoked')", scopes[i], name, NULL, t)) return strcmp(t->status, "revoked") == 0;
    return -1;
}

char *kb_tool_names(sqlite3 *db, const char *project, const char *caller_name, const char *caller_pane) {
    sqlite3_stmt *st = prep(db,
        "SELECT DISTINCT name FROM tools WHERE project IN (?1, 'global') AND (status IN ('active', 'revoked')"
        " OR (status = 'draft' AND author = ?2) OR (status = 'pending' AND reviewer_pane = ?3)) ORDER BY name");
    sqlite3_bind_text(st, 1, project, -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(st, 2, caller_name, -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(st, 3, caller_pane, -1, SQLITE_TRANSIENT);
    return lines(st);
}

void kb_tool_count(sqlite3 *db, const struct kb_tool *t, int ok) {
    sqlite3_stmt *st = prep(db,
        "UPDATE tools SET calls = calls + 1, failures = failures + ?5 WHERE project = ?1 AND name = ?2 AND version = ?3 AND author = ?4 AND version > 0");
    sqlite3_bind_text(st, 1, t->project, -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(st, 2, t->name, -1, SQLITE_TRANSIENT);
    sqlite3_bind_int(st, 3, t->version);
    sqlite3_bind_text(st, 4, t->author, -1, SQLITE_TRANSIENT);
    sqlite3_bind_int(st, 5, !ok);
    sqlite3_step(st);
    sqlite3_finalize(st);
}

char *kb_tool_reason(sqlite3 *db, const struct kb_tool *t) {
    sqlite3_stmt *st = prep(db,
        "SELECT COALESCE(verdict_reason, '') FROM tools WHERE project = ?1 AND name = ?2 AND version = ?3 AND author = ?4");
    sqlite3_bind_text(st, 1, t->project, -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(st, 2, t->name, -1, SQLITE_TRANSIENT);
    sqlite3_bind_int(st, 3, t->version);
    sqlite3_bind_text(st, 4, t->author, -1, SQLITE_TRANSIENT);
    char *r = strdup(sqlite3_step(st) == SQLITE_ROW ? col(st, 0) : "");
    sqlite3_finalize(st);
    return r;
}

/* A text column of one tool version (caller frees), or NULL if the row or the value is missing. `column` is a literal. */
char *kb_tool_field(sqlite3 *db, const char *project, const char *name, int version, const char *column) {
    char *sql = sqlite3_mprintf("SELECT %s FROM tools WHERE project = ?1 AND name = ?2 AND version = ?3", column);
    sqlite3_stmt *st = prep(db, sql);
    sqlite3_free(sql);
    sqlite3_bind_text(st, 1, project, -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(st, 2, name, -1, SQLITE_TRANSIENT);
    sqlite3_bind_int(st, 3, version);
    char *r = NULL;
    if (sqlite3_step(st) == SQLITE_ROW && sqlite3_column_type(st, 0) != SQLITE_NULL) r = strdup(col(st, 0));
    sqlite3_finalize(st);
    return r;
}

int kb_tool_publish(sqlite3 *db, const char *project, const char *author, const char *name, int *version, char **superseded) {
    *superseded = NULL;
    if (sqlite3_exec(db, "BEGIN IMMEDIATE", NULL, NULL, NULL) != SQLITE_OK) return -1;
    sqlite3_stmt *st = prep(db, "SELECT COALESCE(MAX(version), 0) + 1 FROM tools WHERE project = ?1 AND name = ?2");
    sqlite3_bind_text(st, 1, project, -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(st, 2, name, -1, SQLITE_TRANSIENT);
    *version = sqlite3_step(st) == SQLITE_ROW ? sqlite3_column_int(st, 0) : 0;
    sqlite3_finalize(st);
    int rc = *version > 0 ? 0 : -1;
    if (rc == 0) {   /* the reviews to close: "<pane>\t<review_root>" per live one */
        st = prep(db, "SELECT COALESCE(reviewer_pane, '') || char(9) || COALESCE(review_root, '') FROM tools"
                      " WHERE project = ?1 AND name = ?2 AND status = 'pending'");
        sqlite3_bind_text(st, 1, project, -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(st, 2, name, -1, SQLITE_TRANSIENT);
        *superseded = lines(st);
        rc = exec2(db, "UPDATE tools SET status = 'rejected', verdict_reason = 'superseded'"
                       " WHERE project = ?1 AND name = ?2 AND status IN ('pending', 'escalated')", project, name) < 0 ? -1 : 0;
    }
    if (rc == 0) {
        st = prep(db,
            "INSERT INTO tools(project, name, version, status, author, author_model, description, input_schema, interpreter,"
            " script, net, timeout, deadline, created) SELECT project, name, ?3, 'pending', author, author_model, description,"
            " input_schema, interpreter, script, net, timeout, CAST(strftime('%s', 'now') AS INTEGER) + 1200,"
            " CAST(strftime('%s', 'now') AS INTEGER) FROM tools WHERE project = ?1 AND name = ?2 AND status = 'draft' AND author = ?4");
        sqlite3_bind_text(st, 1, project, -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(st, 2, name, -1, SQLITE_TRANSIENT);
        sqlite3_bind_int(st, 3, *version);
        sqlite3_bind_text(st, 4, author, -1, SQLITE_TRANSIENT);
        rc = sqlite3_step(st) == SQLITE_DONE && sqlite3_changes(db) == 1 ? 0 : -1;   /* the draft is the content */
        sqlite3_finalize(st);
    }
    if (rc == 0) {
        st = prep(db, "DELETE FROM tools WHERE project = ?1 AND name = ?2 AND status = 'draft' AND author = ?3");
        sqlite3_bind_text(st, 1, project, -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(st, 2, name, -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(st, 3, author, -1, SQLITE_TRANSIENT);
        rc = sqlite3_step(st) == SQLITE_DONE ? 0 : -1;
        sqlite3_finalize(st);
    }
    if (sqlite3_exec(db, rc == 0 ? "COMMIT" : "ROLLBACK", NULL, NULL, NULL) != SQLITE_OK) rc = -1;
    if (rc != 0) {
        free(*superseded);
        *superseded = NULL;
    }
    return rc;
}

int kb_tool_bind(sqlite3 *db, const char *project, const char *name, int version,
                 const char *pane, const char *model, const char *review_root) {
    sqlite3_stmt *st = prep(db,
        "UPDATE tools SET reviewer_pane = ?4, reviewer_model = ?5, review_root = ?6"
        " WHERE project = ?1 AND name = ?2 AND version = ?3 AND status = 'pending' AND reviewer_pane IS NULL");
    sqlite3_bind_text(st, 1, project, -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(st, 2, name, -1, SQLITE_TRANSIENT);
    sqlite3_bind_int(st, 3, version);
    sqlite3_bind_text(st, 4, pane, -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(st, 5, model, -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(st, 6, review_root, -1, SQLITE_TRANSIENT);
    int n = sqlite3_step(st) == SQLITE_DONE ? sqlite3_changes(db) : 0;
    sqlite3_finalize(st);
    return n;
}

int kb_tool_escalate(sqlite3 *db, const char *project, const char *name, int version) {
    sqlite3_stmt *st = prep(db,
        "UPDATE tools SET status = 'escalated', reviewer_pane = NULL"
        " WHERE project = ?1 AND name = ?2 AND version = ?3 AND status = 'pending'");
    sqlite3_bind_text(st, 1, project, -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(st, 2, name, -1, SQLITE_TRANSIENT);
    sqlite3_bind_int(st, 3, version);
    int n = sqlite3_step(st) == SQLITE_DONE ? sqlite3_changes(db) : 0;
    sqlite3_finalize(st);
    return n;
}

int kb_tool_verdict(sqlite3 *db, const char *project, const char *name, int version, const char *pane,
                    const char *verdict, const char *reason, char status[16]) {
    const char *to = strcmp(verdict, "approve") == 0 ? "active" : strcmp(verdict, "reject") == 0 ? "rejected" : "escalated";
    if (sqlite3_exec(db, "BEGIN IMMEDIATE", NULL, NULL, NULL) != SQLITE_OK) {
        snprintf(status, 16, "busy");
        return -1;
    }
    sqlite3_stmt *st = prep(db,
        "UPDATE tools SET status = ?5, verdict_reason = ?6, reviewer_pane = CASE WHEN ?5 = 'escalated' THEN NULL ELSE reviewer_pane END"
        " WHERE project = ?1 AND name = ?2 AND version = ?3 AND status = 'pending' AND reviewer_pane = ?4");
    sqlite3_bind_text(st, 1, project, -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(st, 2, name, -1, SQLITE_TRANSIENT);
    sqlite3_bind_int(st, 3, version);
    sqlite3_bind_text(st, 4, pane, -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(st, 5, to, -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(st, 6, reason, -1, SQLITE_TRANSIENT);
    int applied = sqlite3_step(st) == SQLITE_DONE && sqlite3_changes(db) == 1;
    sqlite3_finalize(st);
    if (applied) {
        if (strcmp(to, "active") == 0) {   /* at most one active row per tool */
            st = prep(db, "UPDATE tools SET status = 'revoked', verdict_reason = 'superseded'"
                          " WHERE project = ?1 AND name = ?2 AND status = 'active' AND version <> ?3");
            sqlite3_bind_text(st, 1, project, -1, SQLITE_TRANSIENT);
            sqlite3_bind_text(st, 2, name, -1, SQLITE_TRANSIENT);
            sqlite3_bind_int(st, 3, version);
            applied = sqlite3_step(st) == SQLITE_DONE;
            sqlite3_finalize(st);
        }
        if (sqlite3_exec(db, applied ? "COMMIT" : "ROLLBACK", NULL, NULL, NULL) != SQLITE_OK) applied = 0;
        if (applied) return 0;
        snprintf(status, 16, "busy");
        return -1;
    }
    st = prep(db, "SELECT status, reviewer_pane IS NULL FROM tools WHERE project = ?1 AND name = ?2 AND version = ?3");
    sqlite3_bind_text(st, 1, project, -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(st, 2, name, -1, SQLITE_TRANSIENT);
    sqlite3_bind_int(st, 3, version);
    if (sqlite3_step(st) != SQLITE_ROW) snprintf(status, 16, "unknown");
    else if (strcmp(col(st, 0), "pending") == 0 && sqlite3_column_int(st, 1)) snprintf(status, 16, "unbound");
    else snprintf(status, 16, "%s", col(st, 0));
    sqlite3_finalize(st);
    sqlite3_exec(db, "ROLLBACK", NULL, NULL, NULL);
    return -1;
}

char *kb_tool_expire(sqlite3 *db, const char *project) {
    if (sqlite3_exec(db, "BEGIN IMMEDIATE", NULL, NULL, NULL) != SQLITE_OK) return strdup("");
    sqlite3_stmt *st = prep(db,
        "SELECT COALESCE(reviewer_pane, '') || char(9) || COALESCE(review_root, '') || char(9) || name || char(9) || version"
        " FROM tools WHERE project = ?1 AND status = 'pending' AND deadline <= ?2");
    long long now = time(NULL);   /* one cutoff for the SELECT and the UPDATE */
    sqlite3_bind_text(st, 1, project, -1, SQLITE_TRANSIENT);
    sqlite3_bind_int64(st, 2, now);
    char *out = lines(st);
    st = prep(db, "UPDATE tools SET status = 'escalated', reviewer_pane = NULL"
                  " WHERE project = ?1 AND status = 'pending' AND deadline <= ?2");
    sqlite3_bind_text(st, 1, project, -1, SQLITE_TRANSIENT);
    sqlite3_bind_int64(st, 2, now);
    int ok = sqlite3_step(st) == SQLITE_DONE;
    sqlite3_finalize(st);
    if (sqlite3_exec(db, ok ? "COMMIT" : "ROLLBACK", NULL, NULL, NULL) != SQLITE_OK || !ok) *out = '\0';
    return out;
}

int kb_tool_revoke(sqlite3 *db, const char *project, const char *name, const char *reason, char **reviews) {
    *reviews = NULL;
    if (sqlite3_exec(db, "BEGIN IMMEDIATE", NULL, NULL, NULL) != SQLITE_OK) return 0;
    sqlite3_stmt *st = prep(db, "SELECT COALESCE(reviewer_pane, '') || char(9) || COALESCE(review_root, '') FROM tools"
                                " WHERE project = ?1 AND name = ?2 AND status = 'pending'");
    sqlite3_bind_text(st, 1, project, -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(st, 2, name, -1, SQLITE_TRANSIENT);
    *reviews = lines(st);
    st = prep(db, "UPDATE tools SET status = 'revoked', verdict_reason = ?3"
                  " WHERE project = ?1 AND name = ?2 AND status IN ('active', 'pending', 'escalated')");
    sqlite3_bind_text(st, 1, project, -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(st, 2, name, -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(st, 3, reason, -1, SQLITE_TRANSIENT);
    int n = sqlite3_step(st) == SQLITE_DONE ? sqlite3_changes(db) : -1;
    sqlite3_finalize(st);
    if (sqlite3_exec(db, n >= 0 ? "COMMIT" : "ROLLBACK", NULL, NULL, NULL) != SQLITE_OK || n < 0) n = 0;
    if (n == 0) {
        free(*reviews);
        *reviews = NULL;
    }
    return n;
}

int kb_tool_live(sqlite3 *db, const char *review_root) {
    sqlite3_stmt *st = prep(db, "SELECT 1 FROM tools WHERE status = 'pending' AND review_root = ?1");
    sqlite3_bind_text(st, 1, review_root, -1, SQLITE_TRANSIENT);
    int live = sqlite3_step(st) == SQLITE_ROW;
    sqlite3_finalize(st);
    return live;
}
