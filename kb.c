/* The knowledge store: entries in SQLite with an FTS5 index. Knows nothing about tmux or MCP. */
#define _DARWIN_C_SOURCE
#include "kb.h"
#include <ctype.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/time.h>
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
        char *l = sqlite3_mprintf("%s [%s] %s — %s\n", col(st, 0), col(st, 1), col(st, 2), col(st, 3));
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
