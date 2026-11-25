/* The knowledge store: entries in SQLite with an FTS5 index. Knows nothing about tmux or MCP. */
#define _DARWIN_C_SOURCE
#include "kb.h"
#include <ctype.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>
#include <json-c/json.h>

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
    "CREATE TABLE IF NOT EXISTS mail(post INTEGER PRIMARY KEY, name TEXT NOT NULL, pane TEXT NOT NULL, delivered INTEGER NOT NULL DEFAULT 0);"
    "CREATE TABLE IF NOT EXISTS posts(scope TEXT NOT NULL, sender TEXT NOT NULL, text TEXT NOT NULL, at INTEGER NOT NULL);"
    "CREATE INDEX IF NOT EXISTS posts_scope ON posts(scope);"
    "CREATE TABLE IF NOT EXISTS hook_sessions("
    " socket TEXT NOT NULL, pane TEXT NOT NULL, harness TEXT NOT NULL, session_id TEXT NOT NULL,"
    " harness_pid INTEGER NOT NULL, last_event TEXT NOT NULL, at INTEGER NOT NULL,"
    " prompt_seen INTEGER NOT NULL DEFAULT 0, stop_seen INTEGER NOT NULL DEFAULT 0,"
    " wake_reserved INTEGER NOT NULL DEFAULT 0, wake_at INTEGER,"
    " stop_blocked INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(socket,pane));"

    "CREATE TABLE IF NOT EXISTS task_gate(task TEXT PRIMARY KEY, reminded INTEGER NOT NULL DEFAULT 0, away INTEGER NOT NULL DEFAULT 0,"
    " answered INTEGER NOT NULL DEFAULT 0);"
    "CREATE TABLE IF NOT EXISTS tools(project TEXT NOT NULL, name TEXT NOT NULL, version INTEGER NOT NULL,"
    " status TEXT NOT NULL, author TEXT NOT NULL, author_model TEXT NOT NULL DEFAULT '', description TEXT NOT NULL,"
    " input_schema TEXT NOT NULL, interpreter TEXT NOT NULL, script TEXT NOT NULL, net INTEGER NOT NULL DEFAULT 0,"
    " timeout INTEGER NOT NULL DEFAULT 60, source TEXT NOT NULL DEFAULT '', reviewer TEXT, reviewer_pane TEXT,"
    " reviewer_model TEXT, review_root TEXT, deadline INTEGER, verdict_reason TEXT, calls INTEGER NOT NULL DEFAULT 0,"
    " failures INTEGER NOT NULL DEFAULT 0, created INTEGER,"
    " PRIMARY KEY(project, name, version, author));"   /* author: drafts are version 0, one per author */
    "CREATE UNIQUE INDEX IF NOT EXISTS tools_version ON tools(project, name, version) WHERE version > 0;"
    "CREATE INDEX IF NOT EXISTS tools_name ON tools(project, name, status);"
    "CREATE TABLE IF NOT EXISTS code_servers("
    " scope_project TEXT NOT NULL DEFAULT '', name TEXT NOT NULL,"
    " reg_id TEXT NOT NULL UNIQUE,"
    " command TEXT NOT NULL, args_json TEXT NOT NULL DEFAULT '[]',"
    " env_json TEXT NOT NULL DEFAULT '{}', isolated INTEGER NOT NULL DEFAULT 0,"
    " trust TEXT NOT NULL DEFAULT 'none',"
    " created_by TEXT NOT NULL DEFAULT '', created_at INTEGER NOT NULL,"
    " PRIMARY KEY(scope_project, name));"
    "CREATE TABLE IF NOT EXISTS code_catalogs("
    " reg_id TEXT NOT NULL, owner_project TEXT NOT NULL DEFAULT '',"
    " tools_json TEXT NOT NULL DEFAULT '', meta_gen INTEGER NOT NULL DEFAULT 0,"
    " updated_at INTEGER NOT NULL,"
    " PRIMARY KEY(reg_id, owner_project));"
    "CREATE TABLE IF NOT EXISTS code_grants("
    " project TEXT NOT NULL, reg_id TEXT NOT NULL, server TEXT NOT NULL,"
    " tool_pattern TEXT NOT NULL, kind TEXT NOT NULL,"
    " level TEXT NOT NULL, class_at_grant TEXT NOT NULL DEFAULT '',"
    " granted_by TEXT NOT NULL, granted_at INTEGER NOT NULL,"
    " reason TEXT NOT NULL DEFAULT '',"
    " PRIMARY KEY(project, reg_id, tool_pattern, kind));"
    "CREATE INDEX IF NOT EXISTS code_grants_proj ON code_grants(project, reg_id);"
    "CREATE TABLE IF NOT EXISTS code_runs("
    " id TEXT PRIMARY KEY, project TEXT NOT NULL, caller TEXT NOT NULL,"
    " script_hash TEXT NOT NULL, result TEXT, logs TEXT, calls TEXT, denied TEXT,"
    " retained_capped INTEGER NOT NULL DEFAULT 0,"
    " created INTEGER NOT NULL, expires INTEGER NOT NULL, expired INTEGER NOT NULL DEFAULT 0);"
    "CREATE INDEX IF NOT EXISTS code_runs_exp ON code_runs(expires) WHERE expired = 0;"
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

/* Add the column when the table lacks it. `def` is its type and default. */
static int ensure_column(sqlite3 *db, const char *table, const char *name, const char *def) {
    sqlite3_stmt *st = NULL;
    char query[512];
    snprintf(query, sizeof query, "PRAGMA table_info(%s)", table);
    int found = 0, rc = sqlite3_prepare_v2(db, query, -1, &st, NULL);
    if (rc != SQLITE_OK) return rc;
    while ((rc = sqlite3_step(st)) == SQLITE_ROW)
        if (!strcmp((const char *)sqlite3_column_text(st, 1), name)) found = 1;
    sqlite3_finalize(st);
    if (rc != SQLITE_DONE) return rc;
    snprintf(query, sizeof query, "ALTER TABLE %s ADD COLUMN %s %s", table, name, def);
    return found ? SQLITE_OK : sqlite3_exec(db, query, NULL, NULL, NULL);
}

/* Columns added to the tables of SCHEMA since the first 0.4.0 databases, in order. Add a column here and only here: the stamp
 * below follows the length of this list, so a database that lacks the column is migrated and never skipped. */
static const struct { const char *table, *name, *def; } MIGRATIONS[] = {
    {"mail", "state", "TEXT NOT NULL DEFAULT 'pending'"},
    {"mail", "staged_turn", "TEXT"},
    {"mail", "presentations", "INTEGER NOT NULL DEFAULT 0"},
    {"hook_sessions", "stop_blocked", "INTEGER NOT NULL DEFAULT 0"},
    {"mail", "task", "TEXT NOT NULL DEFAULT ''"},
    {"mail", "hooked", "INTEGER NOT NULL DEFAULT 0"},
    {"mail", "from_pane", "TEXT NOT NULL DEFAULT ''"},
    {"mail", "from_scope", "TEXT NOT NULL DEFAULT ''"},
    {"mail", "socket", "TEXT NOT NULL DEFAULT ''"},   /* the tmux server of `pane`; rows from before 0.4.0 have none */
    {"hook_sessions", "turn", "INTEGER NOT NULL DEFAULT 0"},
    {"hook_sessions", "broken", "INTEGER NOT NULL DEFAULT 0"},
    {"hook_sessions", "server_start", "INTEGER NOT NULL DEFAULT 0"},
    {"task_gate", "answered", "INTEGER NOT NULL DEFAULT 0"},
    {"mail", "shown", "INTEGER NOT NULL DEFAULT 0"},
    {"mail", "staged_full", "INTEGER NOT NULL DEFAULT 0"},
    {"hook_sessions", "generation", "TEXT NOT NULL DEFAULT ''"},
    {"hook_sessions", "event_seq", "INTEGER NOT NULL DEFAULT 0"},
    {"mail", "wake_attempts", "INTEGER NOT NULL DEFAULT 0"},
    {"mail", "lease_until", "INTEGER NOT NULL DEFAULT 0"},
};

/* PRAGMA user_version of a database that has this file's SCHEMA and every column of MIGRATIONS: 1 for the 13 columns above, one
 * more for each column added later. A database stamped above it is refused. A new table
 * in SCHEMA has no entry in MIGRATIONS: lower the 10 below by one for it, or databases stamped before it never get the table. */
/* Version 4 also backfills data, without adding a column. */
#define KB_SCHEMA_VERSION ((int)(sizeof MIGRATIONS / sizeof *MIGRATIONS) - 10)

static int schema_version(sqlite3 *db, int *version) {
    sqlite3_stmt *st = prep(db, "PRAGMA user_version");
    int rc = sqlite3_step(st);
    if (rc == SQLITE_ROW) *version = sqlite3_column_int(st, 0);
    sqlite3_finalize(st);
    return rc == SQLITE_ROW ? SQLITE_OK : rc;
}

#ifdef CNTCTR_TEST_HOOKS
#include <pwd.h>
#include <sys/stat.h>
void kb_test_guard(const char *path) {
    const char *env = getenv("CNTCTR_DB");
    if (!env || !*env) {
        fprintf(stderr, "cntctr-test: refusing to open a knowledge DB (%s) with CNTCTR_DB unset (pid %d); a test must isolate its DB\n", path, (int)getpid());
        abort();
    }
    struct passwd *pw = getpwuid(getuid());
    char real[4096];
    struct stat a, b;
    if (pw && pw->pw_dir) {
        snprintf(real, sizeof real, "%s/.local/share/cntctr/kb.db", pw->pw_dir);
        if (stat(real, &a) == 0 && stat(path, &b) == 0 && a.st_dev == b.st_dev && a.st_ino == b.st_ino) {
            fprintf(stderr, "cntctr-test: refusing to open the real knowledge DB %s (pid %d)\n", real, (int)getpid());
            abort();
        }
    }
}
#endif

sqlite3 *kb_open_timeout(const char *path, char **err, int timeout_ms) {
    kb_test_guard(path);
    sqlite3 *db = NULL;
    if (sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, NULL) != SQLITE_OK) {
        *err = strdup(db ? sqlite3_errmsg(db) : "out of memory");
        sqlite3_close(db);
        return NULL;
    }
    sqlite3_busy_timeout(db, timeout_ms);
    int version = 0, rc = schema_version(db, &version);
    if (rc != SQLITE_OK || version > KB_SCHEMA_VERSION) goto fail;
    if (version == KB_SCHEMA_VERSION) return db;

    sqlite3_exec(db, "PRAGMA journal_mode=WAL", NULL, NULL, NULL);
    char host[256] = "host";
    gethostname(host, sizeof host - 1);
    host[strcspn(host, ".")] = '\0';
    char *machine = sqlite3_mprintf("INSERT OR IGNORE INTO meta VALUES ('machine', '%08x-%q');", arc4random(), host);
    rc = sqlite3_exec(db, "BEGIN IMMEDIATE", NULL, NULL, NULL);
    if (rc == SQLITE_OK) rc = schema_version(db, &version);
    if (rc != SQLITE_OK || version >= KB_SCHEMA_VERSION) {
        sqlite3_free(machine);
        if (rc != SQLITE_OK || version > KB_SCHEMA_VERSION) goto fail;
        sqlite3_exec(db, "ROLLBACK", NULL, NULL, NULL);
        return db; /* another new writer finished the migration while we waited */
    }
    if (rc == SQLITE_OK) rc = sqlite3_exec(db, SCHEMA, NULL, NULL, NULL);
    for (size_t i = 0; rc == SQLITE_OK && i < sizeof MIGRATIONS / sizeof *MIGRATIONS; i++)
        rc = ensure_column(db, MIGRATIONS[i].table, MIGRATIONS[i].name, MIGRATIONS[i].def);
    /* Legacy staging tokens prove an attempt and give no evidence of a full payload. */
    if (rc == SQLITE_OK)
        rc = sqlite3_exec(db, "UPDATE mail SET shown=1, staged_full=0 WHERE shown=0 AND staged_turn IS NOT NULL",
                          NULL, NULL, NULL);
    if (rc == SQLITE_OK)
        rc = sqlite3_exec(db, "UPDATE hook_sessions SET generation=lower(hex(randomblob(16)))"
                             " WHERE generation='' AND session_id!=''", NULL, NULL, NULL);
    if (rc == SQLITE_OK) rc = kb_mail_reconcile(db, time(NULL), 0);
    if (rc == SQLITE_OK) rc = sqlite3_exec(db, machine, NULL, NULL, NULL);
    if (rc == SQLITE_OK) {
        char stamp[48];
        snprintf(stamp, sizeof stamp, "PRAGMA user_version=%d", KB_SCHEMA_VERSION);
        rc = sqlite3_exec(db, stamp, NULL, NULL, NULL);
    }
    if (rc == SQLITE_OK) rc = sqlite3_exec(db, "COMMIT", NULL, NULL, NULL);
    sqlite3_free(machine);
    if (rc == SQLITE_OK) return db;
fail:
    *err = strdup(version > KB_SCHEMA_VERSION ? "newer schema, upgrade cntctr" : sqlite3_errmsg(db));
    sqlite3_close(db);
    return NULL;
}

sqlite3 *kb_open(const char *path, char **err) { return kb_open_timeout(path, err, 5000); }

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

long long kb_mail_insert(sqlite3 *db, const char *scope, const char *pane, const char *name, const char *sender,
                         const char *task, const char *body, int hooked, const char *from_pane,
                         const char *from_scope, const char *socket) {
    if (kb_post(db, scope, sender, body) != 0) return 0;
    long long post = sqlite3_last_insert_rowid(db);
    sqlite3_stmt *st = prep(db, "INSERT INTO mail(post,name,pane,task,hooked,from_pane,from_scope,socket)"
                               " VALUES(?1,?2,?3,?4,?5,?6,?7,?8)");
    sqlite3_bind_int64(st, 1, post);
    sqlite3_bind_text(st, 2, name, -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(st, 3, pane ? pane : "", -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(st, 4, task, -1, SQLITE_TRANSIENT);
    sqlite3_bind_int(st, 5, hooked);
    sqlite3_bind_text(st, 6, from_pane, -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(st, 7, from_scope, -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(st, 8, socket, -1, SQLITE_TRANSIENT);
    int rc = sqlite3_step(st);
    sqlite3_finalize(st);
    return rc == SQLITE_DONE ? post : 0;
}

int kb_mail_claim(sqlite3 *db, long long post, const char *socket, const char *pane, long long server_start,
                  const char *token, int full, int presentations, time_t now, time_t until, int new_post) {
    sqlite3_stmt *st = prep(db, "UPDATE mail SET shown=shown+1,state='staged',staged_turn=?2,staged_full=?3,"
                               " presentations=presentations+?4,lease_until=?9,hooked=max(hooked,?2 IS NOT NULL)"
                               " WHERE post=?1 AND delivered=0 AND shown<3"
                               " AND (state='pending' OR (?2 IS NOT NULL AND state='staged' AND lease_until<?8))"
                               " AND EXISTS (SELECT 1 FROM posts WHERE posts.rowid=mail.post AND "
                               KB_MAIL_BOUND("mail", "?5", "?6", "?7")
        " AND (posts.at>?7 OR (?10 AND posts.at=?7))) RETURNING shown");
    sqlite3_bind_int64(st, 1, post);
    sqlite3_bind_text(st, 2, token, -1, SQLITE_TRANSIENT);
    sqlite3_bind_int(st, 3, full);
    sqlite3_bind_int(st, 4, presentations);
    sqlite3_bind_text(st, 5, socket, -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(st, 6, pane, -1, SQLITE_TRANSIENT);
    sqlite3_bind_int64(st, 7, server_start);
    sqlite3_bind_int64(st, 8, now);
    sqlite3_bind_int64(st, 9, until);
    sqlite3_bind_int(st, 10, new_post);
    int rc = sqlite3_step(st), attempt = 0;
    if (rc == SQLITE_ROW) {
        attempt = sqlite3_column_int(st, 0);
        rc = sqlite3_step(st);
    }
    sqlite3_finalize(st);
    return rc == SQLITE_DONE ? attempt : -1;
}

int kb_mail_finish(sqlite3 *db, long long post, enum kb_mail_finish outcome, int attempt, const char *token,
                   time_t now) {
    const char *read = "UPDATE mail SET delivered=1,state='delivered',lease_until=0 WHERE post=?1 AND delivered=0"
                       " AND state IN ('pending','staged','stalled')";
    const char *ack = "UPDATE mail SET delivered=1,state='delivered',lease_until=0 WHERE post=?1 AND delivered=0"
                      " AND state='staged' AND shown=?2 AND staged_turn IS ?3 AND staged_full=1"
                      " AND lease_until>?4";
    sqlite3_stmt *st = prep(db, outcome == KB_MAIL_READ ? read : ack);
    sqlite3_bind_int64(st, 1, post);
    if (outcome != KB_MAIL_READ) {
        sqlite3_bind_int(st, 2, attempt);
        sqlite3_bind_text(st, 3, token, -1, SQLITE_TRANSIENT);
        sqlite3_bind_int64(st, 4, now);
    }
    int rc = sqlite3_step(st) == SQLITE_DONE ? sqlite3_changes(db) : -1;
    sqlite3_finalize(st);
    return rc;
}

int kb_mail_reconcile(sqlite3 *db, time_t now, int wake_sec) {
    int own = sqlite3_get_autocommit(db);
    int rc = own ? sqlite3_exec(db, "BEGIN IMMEDIATE", NULL, NULL, NULL) : SQLITE_OK;
    if (rc != SQLITE_OK) return rc;
    sqlite3_stmt *st = prep(db, "UPDATE mail SET state='pending',lease_until=0"
        " WHERE delivered=0 AND state='staged' AND shown<3 AND lease_until<?1");
    sqlite3_bind_int64(st, 1, now);
    rc = sqlite3_step(st);
    sqlite3_finalize(st);
    if (rc == SQLITE_DONE) rc = SQLITE_OK;

    sqlite3_stmt *due = prep(db, "SELECT post,name,from_pane,from_scope,socket,posts.sender,posts.scope"
        " FROM mail LEFT JOIN posts ON posts.rowid=mail.post WHERE post>?2 AND delivered=0 AND shown>=3"
        " AND (state='pending' OR (state='staged' AND lease_until<?1)) ORDER BY post LIMIT 1");
    sqlite3_stmt *stall = prep(db, "UPDATE mail SET state='stalled',lease_until=0 WHERE post=?1");
    long long post = 0;
    sqlite3_bind_int64(due, 1, now);
    while (rc == SQLITE_OK) {
        sqlite3_bind_int64(due, 2, post);
        int step = sqlite3_step(due);
        if (step != SQLITE_ROW) {
            rc = step == SQLITE_DONE ? SQLITE_OK : step;
            break;
        }
        post = sqlite3_column_int64(due, 0);
        int save = sqlite3_exec(db, "SAVEPOINT stall_mail", NULL, NULL, NULL);
        if (save != SQLITE_OK) { rc = save; break; }
        sqlite3_bind_int64(stall, 1, post);
        int ok = sqlite3_step(stall) == SQLITE_DONE && sqlite3_changes(db) == 1;
        sqlite3_reset(stall);
        if (ok && sqlite3_column_type(due, 5) != SQLITE_NULL) {
            const char *to = col(due, 5), *pane = col(due, 2), *scope = col(due, 3);
            char *body = sqlite3_mprintf("for %s: undelivered after 3 attempts: %lld to %s; recipient can call board id=%lld",
                                        to, post, col(due, 1), post);
            ok = body && kb_mail_insert(db, *scope ? scope : col(due, 6), pane, to, "cntctr", "",
                                        body, 0, "", "", col(due, 4)) > 0;
            sqlite3_free(body);
        }
        sqlite3_reset(due);
        if (!ok) rc = sqlite3_exec(db, "ROLLBACK TO stall_mail", NULL, NULL, NULL);
        if (rc == SQLITE_OK) rc = sqlite3_exec(db, "RELEASE stall_mail", NULL, NULL, NULL);
        if (!ok && wake_sec == 0 && rc == SQLITE_OK) rc = SQLITE_ERROR;  /* Migration stays atomic. */
    }
    sqlite3_finalize(stall);
    sqlite3_finalize(due);
    if (rc == SQLITE_OK && wake_sec > 0) {
        st = prep(db, "UPDATE hook_sessions SET wake_reserved=0,wake_at=NULL,broken=1"
                      " WHERE wake_reserved=1 AND wake_at<=?1");
        sqlite3_bind_int64(st, 1, now - wake_sec);
        rc = sqlite3_step(st);
        sqlite3_finalize(st);
        if (rc == SQLITE_DONE) rc = SQLITE_OK;
    }
    if (own && rc == SQLITE_OK) rc = sqlite3_exec(db, "COMMIT", NULL, NULL, NULL);
    if (own && rc != SQLITE_OK) sqlite3_exec(db, "ROLLBACK", NULL, NULL, NULL);
    return rc;
}

char *kb_tool_projects(sqlite3 *db) {
    return lines(prep(db, "SELECT DISTINCT project FROM tools WHERE project <> 'global'"));
}

char *kb_board(sqlite3 *db, const char *scope, const char *me, const char *pane, const char *socket, long long server_start, int limit) {
    sqlite3_stmt *st = prep(db,
        "SELECT line FROM (SELECT rowid, datetime(at, 'unixepoch') || ' ' || sender || ': ' || text AS line FROM posts"
        " WHERE scope = ?1 AND NOT EXISTS (SELECT 1 FROM mail WHERE mail.post = posts.rowid AND NOT " KB_MAIL_FOR("mail", "?3", "?1", "?6", "?4", "?5") ") ORDER BY rowid DESC LIMIT ?2) ORDER BY rowid");
    sqlite3_bind_text(st, 1, scope, -1, SQLITE_TRANSIENT);
    sqlite3_bind_int(st, 2, limit);
    sqlite3_bind_text(st, 3, me, -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(st, 4, pane, -1, SQLITE_TRANSIENT);
    sqlite3_bind_int64(st, 5, server_start);
    sqlite3_bind_text(st, 6, socket, -1, SQLITE_TRANSIENT);
    return lines(st);
}

/* Ids of undelivered mail whose full text is included in the board result. */
char *kb_board_mail(sqlite3 *db, const char *scope, const char *me, const char *pane, const char *socket, long long server_start, int limit) {
    sqlite3_stmt *st = prep(db,
        "SELECT group_concat(post) FROM mail JOIN posts ON posts.rowid = mail.post WHERE mail.delivered = 0"
        " AND " KB_MAIL_FOR("mail", "?3", "?1", "?6", "?4", "?5") ""
        " AND mail.post IN (SELECT rowid FROM (SELECT rowid FROM posts WHERE scope = ?1 AND NOT EXISTS (SELECT 1 FROM mail m2 WHERE m2.post = posts.rowid"
        " AND NOT " KB_MAIL_FOR("m2", "?3", "?1", "?6", "?4", "?5") ") ORDER BY rowid DESC LIMIT ?2))");
    sqlite3_bind_text(st, 1, scope, -1, SQLITE_TRANSIENT);
    sqlite3_bind_int(st, 2, limit);
    sqlite3_bind_text(st, 3, me, -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(st, 4, pane, -1, SQLITE_TRANSIENT);
    sqlite3_bind_int64(st, 5, server_start);
    sqlite3_bind_text(st, 6, socket, -1, SQLITE_TRANSIENT);
    char *ids = sqlite3_step(st) == SQLITE_ROW ? strdup(col(st, 0)) : strdup("");
    sqlite3_finalize(st);
    return ids;
}

/* ---- fleet tools ---- */

void kb_tool_free(struct kb_tool *t) {
    free(t->description);
    free(t->input_schema);
    free(t->script);
    memset(t, 0, sizeof *t);
}

/* Replace the author's draft of `name`; the caller owns the transaction. */
static int draft_put(sqlite3 *db, const char *project, const char *author, const char *author_model,
                       const char *name, const char *description, const char *schema,
                       const char *interpreter, const char *script, int net, int timeout) {
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

/* Publish the author's draft as the next version; the caller owns the transaction. */
static int publish_in(sqlite3 *db, const char *project, const char *author, const char *name, int *version, char **superseded) {
    *superseded = NULL;
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
    return rc;
}

/* Save the draft and, with publish, publish it, all in one transaction so a parallel define cannot swap the script between. */
int kb_tool_define(sqlite3 *db, const char *project, const char *author, const char *author_model,
                   const char *name, const char *description, const char *schema,
                   const char *interpreter, const char *script, int net, int timeout,
                   int publish, int *version, char **superseded) {
    *version = 0;
    *superseded = NULL;
    if (sqlite3_exec(db, "BEGIN IMMEDIATE", NULL, NULL, NULL) != SQLITE_OK) return -1;
    int rc = draft_put(db, project, author, author_model, name, description, schema, interpreter, script, net, timeout);
    if (rc == 0 && publish) rc = publish_in(db, project, author, name, version, superseded);
    if (sqlite3_exec(db, rc == 0 ? "COMMIT" : "ROLLBACK", NULL, NULL, NULL) != SQLITE_OK) rc = -1;
    if (rc != 0) {
        free(*superseded);
        *superseded = NULL;
    }
    return rc;
}

int kb_tool_save_draft(sqlite3 *db, const char *project, const char *author, const char *author_model,
                       const char *name, const char *description, const char *schema,
                       const char *interpreter, const char *script, int net, int timeout) {
    int v;
    char *old;
    return kb_tool_define(db, project, author, author_model, name, description, schema, interpreter, script, net,
                          timeout, 0, &v, &old);
}

int kb_tool_publish(sqlite3 *db, const char *project, const char *author, const char *name, int *version, char **superseded) {
    *version = 0;
    *superseded = NULL;
    if (sqlite3_exec(db, "BEGIN IMMEDIATE", NULL, NULL, NULL) != SQLITE_OK) return -1;
    int rc = publish_in(db, project, author, name, version, superseded);
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

/* ---- human controls ---- */

char *kb_tool_list(sqlite3 *db, const char *project) {
    sqlite3_stmt *st = prep(db,
        "SELECT name || ' v' || version || ' ' || status || ' net=' || net || ' calls=' || calls || ' failures=' || failures"
        " || ' promote?=' || CASE WHEN project <> 'global' AND status = 'active' AND calls >= 20 AND failures * 20 < calls"
        "   AND (SELECT count(DISTINCT agent) FROM entries WHERE layer = 'history' AND scope = t.project"
        "        AND instr(title, 'tool ' || t.name || ' v' || t.version || ' ') = 1) >= 3 THEN 'yes' ELSE 'no' END"
        " || CASE WHEN project = 'global' THEN ' (global)' ELSE '' END"
        " FROM tools t WHERE project IN (?1, 'global') AND version > 0"
        " AND (status IN ('active', 'pending', 'escalated') OR (status = 'revoked' AND version = (SELECT MAX(version) FROM tools u"
        "   WHERE u.project = t.project AND u.name = t.name AND u.status IN ('active', 'revoked'))))"
        " AND (project = ?1 OR NOT EXISTS (SELECT 1 FROM tools u WHERE u.project = ?1 AND u.name = t.name AND u.status IN ('active', 'revoked')))"
        " ORDER BY project = 'global', name, version");
    sqlite3_bind_text(st, 1, project, -1, SQLITE_TRANSIENT);
    return lines(st);
}

char *kb_tool_show(sqlite3 *db, const char *project, const char *name) {
    sqlite3_stmt *st = prep(db,
        "SELECT CASE WHEN project = 'global' THEN 'global ' ELSE '' END || 'v' || version || ' ' || status || ' by ' || author"
        " || ', author model ' || COALESCE(NULLIF(author_model, ''), 'unknown')"
        " || ', reviewer model ' || COALESCE(NULLIF(reviewer_model, ''), 'none')"
        " || ', verdict: ' || COALESCE(NULLIF(verdict_reason, ''), 'none') || char(10) || script || char(10)"
        " FROM tools WHERE project IN (?1, 'global') AND name = ?2 AND version > 0 ORDER BY project = 'global', version");
    sqlite3_bind_text(st, 1, project, -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(st, 2, name, -1, SQLITE_TRANSIENT);
    return lines(st);
}

int kb_tool_resolve_human(sqlite3 *db, const char *project, const char *name, int approve, int *version, char **reviews) {
    *reviews = NULL;
    if (sqlite3_exec(db, "BEGIN IMMEDIATE", NULL, NULL, NULL) != SQLITE_OK) return -1;
    sqlite3_stmt *st = prep(db, "SELECT MAX(version) FROM tools WHERE project = ?1 AND name = ?2 AND status IN ('pending', 'escalated')");
    sqlite3_bind_text(st, 1, project, -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(st, 2, name, -1, SQLITE_TRANSIENT);
    *version = sqlite3_step(st) == SQLITE_ROW ? sqlite3_column_int(st, 0) : 0;
    sqlite3_finalize(st);
    int rc = *version > 0 ? 0 : -1;
    if (rc == 0) {   /* the review to close: "<pane>\t<review_root>" if the version is still pending */
        st = prep(db, "SELECT COALESCE(reviewer_pane, '') || char(9) || COALESCE(review_root, '') FROM tools"
                      " WHERE project = ?1 AND name = ?2 AND version = ?3 AND status = 'pending'");
        sqlite3_bind_text(st, 1, project, -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(st, 2, name, -1, SQLITE_TRANSIENT);
        sqlite3_bind_int(st, 3, *version);
        *reviews = lines(st);
        st = prep(db, "UPDATE tools SET status = ?4, verdict_reason = ?5 WHERE project = ?1 AND name = ?2 AND version = ?3");
        sqlite3_bind_text(st, 1, project, -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(st, 2, name, -1, SQLITE_TRANSIENT);
        sqlite3_bind_int(st, 3, *version);
        sqlite3_bind_text(st, 4, approve ? "active" : "rejected", -1, SQLITE_STATIC);
        sqlite3_bind_text(st, 5, approve ? "approved by a human" : "rejected by a human", -1, SQLITE_STATIC);
        rc = sqlite3_step(st) == SQLITE_DONE ? 0 : -1;
        sqlite3_finalize(st);
    }
    if (rc == 0 && approve) {   /* at most one active row per tool */
        st = prep(db, "UPDATE tools SET status = 'revoked', verdict_reason = 'superseded'"
                      " WHERE project = ?1 AND name = ?2 AND status = 'active' AND version <> ?3");
        sqlite3_bind_text(st, 1, project, -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(st, 2, name, -1, SQLITE_TRANSIENT);
        sqlite3_bind_int(st, 3, *version);
        rc = sqlite3_step(st) == SQLITE_DONE ? 0 : -1;
        sqlite3_finalize(st);
    }
    if (sqlite3_exec(db, rc == 0 ? "COMMIT" : "ROLLBACK", NULL, NULL, NULL) != SQLITE_OK) rc = -1;
    if (rc != 0) {
        free(*reviews);
        *reviews = NULL;
    }
    return rc;
}

int kb_tool_promote(sqlite3 *db, const char *project, const char *name, int *from, int *version) {
    if (sqlite3_exec(db, "BEGIN IMMEDIATE", NULL, NULL, NULL) != SQLITE_OK) return -1;
    sqlite3_stmt *st = prep(db, "SELECT version, (SELECT COALESCE(MAX(version), 0) + 1 FROM tools WHERE project = 'global' AND name = ?2)"
                                " FROM tools WHERE project = ?1 AND name = ?2 AND status = 'active'");
    sqlite3_bind_text(st, 1, project, -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(st, 2, name, -1, SQLITE_TRANSIENT);
    int rc = -1;
    if (sqlite3_step(st) == SQLITE_ROW) {
        *from = sqlite3_column_int(st, 0);
        *version = sqlite3_column_int(st, 1);
        rc = 0;
    }
    sqlite3_finalize(st);
    if (rc == 0) {
        st = prep(db, "UPDATE tools SET status = 'revoked', verdict_reason = 'superseded' WHERE project = 'global' AND name = ?1 AND status = 'active'");
        sqlite3_bind_text(st, 1, name, -1, SQLITE_TRANSIENT);
        rc = sqlite3_step(st) == SQLITE_DONE ? 0 : -1;
        sqlite3_finalize(st);
    }
    if (rc == 0) {
        st = prep(db,
            "INSERT INTO tools(project, name, version, status, author, author_model, description, input_schema, interpreter,"
            " script, net, timeout, source, created) SELECT 'global', name, ?3, 'active', author, author_model, description,"
            " input_schema, interpreter, script, net, timeout, project || '/' || name || '/v' || version, CAST(strftime('%s', 'now') AS INTEGER)"
            " FROM tools WHERE project = ?1 AND name = ?2 AND version = ?4");
        sqlite3_bind_text(st, 1, project, -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(st, 2, name, -1, SQLITE_TRANSIENT);
        sqlite3_bind_int(st, 3, *version);
        sqlite3_bind_int(st, 4, *from);
        rc = sqlite3_step(st) == SQLITE_DONE && sqlite3_changes(db) == 1 ? 0 : -1;
        sqlite3_finalize(st);
    }
    if (sqlite3_exec(db, rc == 0 ? "COMMIT" : "ROLLBACK", NULL, NULL, NULL) != SQLITE_OK) rc = -1;
    return rc;
}
char *kb_unread(sqlite3 *db, const char *scope, const char *me, const char *pane, const char *socket, long long server_start, long long after, long long *newest, int *count) {
    sqlite3_stmt *st = prep(db, "SELECT rowid, sender, text FROM posts WHERE scope = ?1 AND rowid > ?2 "
        "AND (EXISTS (SELECT 1 FROM mail WHERE mail.post = posts.rowid AND " KB_MAIL_FOR("mail", "?3", "?1", "?6", "?4", "?5") " AND mail.delivered = 0) "
        "OR (at >= strftime('%s', 'now') - 86400 AND NOT EXISTS (SELECT 1 FROM mail WHERE mail.post = posts.rowid))) ORDER BY rowid");
    sqlite3_bind_text(st, 1, scope, -1, SQLITE_TRANSIENT);
    sqlite3_bind_int64(st, 2, after);
    sqlite3_bind_text(st, 3, me, -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(st, 4, pane, -1, SQLITE_TRANSIENT);
    sqlite3_bind_int64(st, 5, server_start);
    sqlite3_bind_text(st, 6, socket, -1, SQLITE_TRANSIENT);
    char *out = strdup("");
    *newest = after;
    *count = 0;
    while (sqlite3_step(st) == SQLITE_ROW) {
        *newest = sqlite3_column_int64(st, 0);
        if (strcmp(col(st, 1), me) == 0) continue;   /* our own posts count as seen */
        char *t;
        if (asprintf(&t, "%s- %s: %s\n", out, col(st, 1), col(st, 2)) < 0) break;
        free(out);
        out = t;
        (*count)++;
    }
    sqlite3_finalize(st);
    return out;
}

int kb_omitted(sqlite3 *db, const char *scope, const char *me, const char *pane, const char *socket, long long server_start, long long after, int limit, int *mail_omitted) {
    sqlite3_stmt *st = prep(db,
        "SELECT sum(posts.rowid>?2 AND posts.sender!=?3), sum(mail.post IS NOT NULL)"
        " FROM posts LEFT JOIN mail ON mail.post=posts.rowid WHERE posts.scope=?1 AND ("
        " (mail.post IS NOT NULL AND mail.delivered=0 AND " KB_MAIL_FOR("mail", "?3", "?1", "?7", "?4", "?6") ")"
        " OR (mail.post IS NULL AND posts.at >= strftime('%s','now') - 86400)) "
        "AND posts.rowid NOT IN (SELECT rowid FROM posts WHERE scope=?1 AND NOT EXISTS "
        "(SELECT 1 FROM mail WHERE mail.post=posts.rowid AND NOT " KB_MAIL_FOR("mail", "?3", "?1", "?7", "?4", "?6") ") ORDER BY rowid DESC LIMIT ?5)");
    sqlite3_bind_text(st, 1, scope, -1, SQLITE_TRANSIENT);
    sqlite3_bind_int64(st, 2, after);
    sqlite3_bind_text(st, 3, me, -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(st, 4, pane, -1, SQLITE_TRANSIENT);
    sqlite3_bind_int(st, 5, limit);
    sqlite3_bind_int64(st, 6, server_start);
    sqlite3_bind_text(st, 7, socket, -1, SQLITE_TRANSIENT);
    int row = sqlite3_step(st) == SQLITE_ROW;
    int count = row ? sqlite3_column_int(st, 0) : 0;
    *mail_omitted = row ? sqlite3_column_int(st, 1) : 0;
    sqlite3_finalize(st);
    return count;
}

/* ---- code mode ---- */

static void code_gen_reg_id(char out[64]) {
    struct timeval tv;
    gettimeofday(&tv, NULL);
    long long ms = (long long)tv.tv_sec * 1000LL + tv.tv_usec / 1000;
    snprintf(out, 64, "reg-%llx-%08x%08x", ms, arc4random(), arc4random());
}

void kb_code_server_free(struct code_server_row *s) {
    if (!s) return;
    free(s->command);
    free(s->args_json);
    free(s->env_json);
    s->command = s->args_json = s->env_json = NULL;
}

/* 1 if any human grant exists for reg_id, 0 if none, -1 on DB error. */
static int code_reg_has_human_grants(sqlite3 *db, const char *reg_id) {
    if (!reg_id || !*reg_id) return 0;
    sqlite3_stmt *st = prep(db, "SELECT 1 FROM code_grants WHERE reg_id = ?1 AND granted_by = 'human' LIMIT 1");
    if (!st) return -1;
    if (sqlite3_bind_text(st, 1, reg_id, -1, SQLITE_TRANSIENT) != SQLITE_OK) {
        sqlite3_finalize(st);
        return -1;
    }
    int step_rc = sqlite3_step(st);
    sqlite3_finalize(st);
    if (step_rc == SQLITE_ROW) return 1;
    if (step_rc == SQLITE_DONE) return 0;
    return -1;
}

int kb_code_server_inspect(sqlite3 *db, const char *scope_project, const char *name,
                           char reg_id_out[64], int *has_human_grants) {
    if (reg_id_out) reg_id_out[0] = '\0';
    if (has_human_grants) *has_human_grants = 0;
    if (!db || !name) return -2;
    const char *scope = scope_project ? scope_project : "";
    sqlite3_stmt *st = prep(db, "SELECT reg_id FROM code_servers WHERE scope_project = ?1 AND name = ?2");
    if (!st) return -2;
    if (sqlite3_bind_text(st, 1, scope, -1, SQLITE_TRANSIENT) != SQLITE_OK ||
        sqlite3_bind_text(st, 2, name, -1, SQLITE_TRANSIENT) != SQLITE_OK) {
        sqlite3_finalize(st);
        return -2;
    }
    int step_rc = sqlite3_step(st);
    char reg[64] = "";
    if (step_rc == SQLITE_ROW) snprintf(reg, sizeof reg, "%s", col(st, 0));
    sqlite3_finalize(st);
    if (step_rc == SQLITE_DONE) return -1;
    if (step_rc != SQLITE_ROW) return -2;
    if (has_human_grants) {
        int hh = code_reg_has_human_grants(db, reg);
        if (hh < 0) return -2;
        *has_human_grants = hh;
    }
    if (reg_id_out) snprintf(reg_id_out, 64, "%s", reg);
    return 0;
}

int kb_code_server_has_human_grants(sqlite3 *db, const char *scope_project, const char *name) {
    int has_human = 0;
    int rc = kb_code_server_inspect(db, scope_project, name, NULL, &has_human);
    if (rc == -2) return -1;
    return rc == 0 ? has_human : 0;
}

int kb_code_server_put_checked(sqlite3 *db, const struct code_server_row *s, int from_mcp,
                               const char *expected_reg_id, int human_approved, char reg_id_out[64],
                               int *dropped_grants, int *dropped_projects) {
    if (dropped_grants) *dropped_grants = 0;
    if (dropped_projects) *dropped_projects = 0;
    if (reg_id_out) reg_id_out[0] = '\0';
    if (!db || !s || !s->name[0] || !s->command || !s->command[0]) return -1;
    const char *scope = s->scope_project;
    const char *args_json = (s->args_json && s->args_json[0]) ? s->args_json : "[]";
    const char *env_json = (s->env_json && s->env_json[0]) ? s->env_json : "{}";
    const char *trust = s->trust[0] ? s->trust : "none";
    long long created_at = s->created_at > 0 ? s->created_at : (long long)time(NULL);

    if (sqlite3_exec(db, "BEGIN IMMEDIATE", NULL, NULL, NULL) != SQLITE_OK) return -1;

    if (from_mcp && scope[0] != '\0') {
        sqlite3_stmt *st = prep(db, "SELECT 1 FROM code_servers WHERE scope_project = '' AND name = ?1 LIMIT 1");
        if (!st) { sqlite3_exec(db, "ROLLBACK", NULL, NULL, NULL); return -1; }
        if (sqlite3_bind_text(st, 1, s->name, -1, SQLITE_TRANSIENT) != SQLITE_OK) {
            sqlite3_finalize(st);
            sqlite3_exec(db, "ROLLBACK", NULL, NULL, NULL);
            return -1;
        }
        int step_rc = sqlite3_step(st);
        sqlite3_finalize(st);
        if (step_rc == SQLITE_ROW) {
            sqlite3_exec(db, "ROLLBACK", NULL, NULL, NULL);
            return -2;
        }
        if (step_rc != SQLITE_DONE) {
            sqlite3_exec(db, "ROLLBACK", NULL, NULL, NULL);
            return -1;
        }
    }

    char old_reg[64] = "";
    sqlite3_stmt *st = prep(db, "SELECT reg_id FROM code_servers WHERE scope_project = ?1 AND name = ?2");
    if (!st) { sqlite3_exec(db, "ROLLBACK", NULL, NULL, NULL); return -1; }
    if (sqlite3_bind_text(st, 1, scope, -1, SQLITE_TRANSIENT) != SQLITE_OK ||
        sqlite3_bind_text(st, 2, s->name, -1, SQLITE_TRANSIENT) != SQLITE_OK) {
        sqlite3_finalize(st);
        sqlite3_exec(db, "ROLLBACK", NULL, NULL, NULL);
        return -1;
    }
    int step_rc = sqlite3_step(st);
    if (step_rc == SQLITE_ROW) snprintf(old_reg, sizeof old_reg, "%s", col(st, 0));
    sqlite3_finalize(st);
    if (step_rc != SQLITE_ROW && step_rc != SQLITE_DONE) {
        sqlite3_exec(db, "ROLLBACK", NULL, NULL, NULL);
        return -1;
    }

    int has_human = old_reg[0] ? code_reg_has_human_grants(db, old_reg) : 0;
    if (has_human < 0) {
        sqlite3_exec(db, "ROLLBACK", NULL, NULL, NULL);
        return -1;
    }
    if (from_mcp && has_human) {
        sqlite3_exec(db, "ROLLBACK", NULL, NULL, NULL);
        return -2;
    }
    if (expected_reg_id != NULL) {
        if (strcmp(old_reg, expected_reg_id) != 0 || (has_human && !human_approved)) {
            sqlite3_exec(db, "ROLLBACK", NULL, NULL, NULL);
            return -3;
        }
    }

    int dg = 0, dp = 0, rc = 0;
    if (old_reg[0]) {
        st = prep(db, "SELECT COUNT(*), COUNT(DISTINCT project) FROM code_grants WHERE reg_id = ?1");
        if (!st) { rc = -1; goto done; }
        if (sqlite3_bind_text(st, 1, old_reg, -1, SQLITE_TRANSIENT) != SQLITE_OK ||
            sqlite3_step(st) != SQLITE_ROW) {
            rc = -1;
        } else {
            dg = sqlite3_column_int(st, 0);
            dp = sqlite3_column_int(st, 1);
        }
        sqlite3_finalize(st);
        if (rc != 0) goto done;

        st = prep(db, "DELETE FROM code_grants WHERE reg_id = ?1");
        if (!st) { rc = -1; goto done; }
        if (sqlite3_bind_text(st, 1, old_reg, -1, SQLITE_TRANSIENT) != SQLITE_OK ||
            sqlite3_step(st) != SQLITE_DONE) rc = -1;
        sqlite3_finalize(st);
        if (rc != 0) goto done;

        st = prep(db, "DELETE FROM code_catalogs WHERE reg_id = ?1");
        if (!st) { rc = -1; goto done; }
        if (sqlite3_bind_text(st, 1, old_reg, -1, SQLITE_TRANSIENT) != SQLITE_OK ||
            sqlite3_step(st) != SQLITE_DONE) rc = -1;
        sqlite3_finalize(st);
        if (rc != 0) goto done;

        st = prep(db, "DELETE FROM code_servers WHERE scope_project = ?1 AND name = ?2");
        if (!st) { rc = -1; goto done; }
        if (sqlite3_bind_text(st, 1, scope, -1, SQLITE_TRANSIENT) != SQLITE_OK ||
            sqlite3_bind_text(st, 2, s->name, -1, SQLITE_TRANSIENT) != SQLITE_OK ||
            sqlite3_step(st) != SQLITE_DONE) rc = -1;
        sqlite3_finalize(st);
        if (rc != 0) goto done;
    }

    char new_reg[64];
    code_gen_reg_id(new_reg);
    st = prep(db, "INSERT INTO code_servers(scope_project, name, reg_id, command, args_json, env_json, isolated, trust, created_by, created_at)"
                  " VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)");
    if (!st) { rc = -1; goto done; }
    if (sqlite3_bind_text(st, 1, scope, -1, SQLITE_TRANSIENT) != SQLITE_OK ||
        sqlite3_bind_text(st, 2, s->name, -1, SQLITE_TRANSIENT) != SQLITE_OK ||
        sqlite3_bind_text(st, 3, new_reg, -1, SQLITE_TRANSIENT) != SQLITE_OK ||
        sqlite3_bind_text(st, 4, s->command, -1, SQLITE_TRANSIENT) != SQLITE_OK ||
        sqlite3_bind_text(st, 5, args_json, -1, SQLITE_TRANSIENT) != SQLITE_OK ||
        sqlite3_bind_text(st, 6, env_json, -1, SQLITE_TRANSIENT) != SQLITE_OK ||
        sqlite3_bind_int(st, 7, s->isolated ? 1 : 0) != SQLITE_OK ||
        sqlite3_bind_text(st, 8, trust, -1, SQLITE_TRANSIENT) != SQLITE_OK ||
        sqlite3_bind_text(st, 9, s->created_by, -1, SQLITE_TRANSIENT) != SQLITE_OK ||
        sqlite3_bind_int64(st, 10, created_at) != SQLITE_OK ||
        sqlite3_step(st) != SQLITE_DONE) rc = -1;
    sqlite3_finalize(st);

done:
    if (sqlite3_exec(db, rc == 0 ? "COMMIT" : "ROLLBACK", NULL, NULL, NULL) != SQLITE_OK) rc = -1;
    if (rc == 0) {
        if (reg_id_out) snprintf(reg_id_out, 64, "%s", new_reg);
        if (dropped_grants) *dropped_grants = dg;
        if (dropped_projects) *dropped_projects = dp;
    }
    return rc;
}

int kb_code_server_put(sqlite3 *db, const struct code_server_row *s, int from_mcp, char reg_id_out[64],
                       int *dropped_grants, int *dropped_projects) {
    return kb_code_server_put_checked(db, s, from_mcp, NULL, from_mcp ? 0 : 1, reg_id_out, dropped_grants, dropped_projects);
}

int kb_code_server_get(sqlite3 *db, const char *project, const char *name, struct code_server_row *out) {
    if (!out) return -1;
    memset(out, 0, sizeof *out);
    if (!db || !name || !*name) return -1;
    const char *proj = project ? project : "";
    sqlite3_stmt *st = prep(db,
        "SELECT scope_project, name, reg_id, command, args_json, env_json, isolated, trust, created_by, created_at"
        " FROM code_servers WHERE name = ?1 AND (scope_project = ?2 OR scope_project = '')"
        " ORDER BY CASE WHEN scope_project = ?2 AND ?2 != '' THEN 0 ELSE 1 END LIMIT 1");
    if (!st) return -1;
    if (sqlite3_bind_text(st, 1, name, -1, SQLITE_TRANSIENT) != SQLITE_OK ||
        sqlite3_bind_text(st, 2, proj, -1, SQLITE_TRANSIENT) != SQLITE_OK) {
        sqlite3_finalize(st);
        return -1;
    }
    int found = sqlite3_step(st) == SQLITE_ROW;
    if (found) {
        const char *sp = col(st, 0);
        if (strlen(sp) >= sizeof out->scope_project) {
            sqlite3_finalize(st);
            return -1;
        }
        snprintf(out->scope_project, sizeof out->scope_project, "%s", sp);
        snprintf(out->name, sizeof out->name, "%s", col(st, 1));
        snprintf(out->reg_id, sizeof out->reg_id, "%s", col(st, 2));
        out->command = strdup(col(st, 3));
        out->args_json = strdup(col(st, 4));
        out->env_json = strdup(col(st, 5));
        out->isolated = sqlite3_column_int(st, 6);
        snprintf(out->trust, sizeof out->trust, "%s", col(st, 7));
        snprintf(out->created_by, sizeof out->created_by, "%s", col(st, 8));
        out->created_at = sqlite3_column_int64(st, 9);
    }
    sqlite3_finalize(st);
    return found ? 0 : -1;
}

int kb_code_server_del_checked(sqlite3 *db, const char *scope_project, const char *name, int from_mcp,
                               const char *expected_reg_id, int human_approved,
                               int *dropped_grants, int *dropped_projects) {
    if (dropped_grants) *dropped_grants = 0;
    if (dropped_projects) *dropped_projects = 0;
    if (!db || !name || !*name) return -1;
    const char *scope = scope_project ? scope_project : "";
    if (sqlite3_exec(db, "BEGIN IMMEDIATE", NULL, NULL, NULL) != SQLITE_OK) return -1;

    char old_reg[64] = "";
    sqlite3_stmt *st = prep(db, "SELECT reg_id FROM code_servers WHERE scope_project = ?1 AND name = ?2");
    if (!st) { sqlite3_exec(db, "ROLLBACK", NULL, NULL, NULL); return -1; }
    if (sqlite3_bind_text(st, 1, scope, -1, SQLITE_TRANSIENT) != SQLITE_OK ||
        sqlite3_bind_text(st, 2, name, -1, SQLITE_TRANSIENT) != SQLITE_OK) {
        sqlite3_finalize(st);
        sqlite3_exec(db, "ROLLBACK", NULL, NULL, NULL);
        return -1;
    }
    int step_rc = sqlite3_step(st);
    if (step_rc == SQLITE_ROW) snprintf(old_reg, sizeof old_reg, "%s", col(st, 0));
    sqlite3_finalize(st);
    if (step_rc != SQLITE_ROW && step_rc != SQLITE_DONE) {
        sqlite3_exec(db, "ROLLBACK", NULL, NULL, NULL);
        return -1;
    }

    int has_human = old_reg[0] ? code_reg_has_human_grants(db, old_reg) : 0;
    if (has_human < 0) {
        sqlite3_exec(db, "ROLLBACK", NULL, NULL, NULL);
        return -1;
    }
    if (expected_reg_id != NULL) {
        if (strcmp(old_reg, expected_reg_id) != 0 || (has_human && !human_approved)) {
            sqlite3_exec(db, "ROLLBACK", NULL, NULL, NULL);
            return -3;
        }
    }
    if (!old_reg[0]) {
        sqlite3_exec(db, "COMMIT", NULL, NULL, NULL);
        return 0;
    }
    if (from_mcp && has_human) {
        sqlite3_exec(db, "ROLLBACK", NULL, NULL, NULL);
        return -2;
    }

    int dg = 0, dp = 0, changed = 0, rc = 0;
    st = prep(db, "SELECT COUNT(*), COUNT(DISTINCT project) FROM code_grants WHERE reg_id = ?1");
    if (!st) { rc = -1; goto done; }
    if (sqlite3_bind_text(st, 1, old_reg, -1, SQLITE_TRANSIENT) != SQLITE_OK ||
        sqlite3_step(st) != SQLITE_ROW) {
        rc = -1;
    } else {
        dg = sqlite3_column_int(st, 0);
        dp = sqlite3_column_int(st, 1);
    }
    sqlite3_finalize(st);
    if (rc != 0) goto done;

    st = prep(db, "DELETE FROM code_grants WHERE reg_id = ?1");
    if (!st) { rc = -1; goto done; }
    if (sqlite3_bind_text(st, 1, old_reg, -1, SQLITE_TRANSIENT) != SQLITE_OK ||
        sqlite3_step(st) != SQLITE_DONE) rc = -1;
    sqlite3_finalize(st);
    if (rc != 0) goto done;

    st = prep(db, "DELETE FROM code_catalogs WHERE reg_id = ?1");
    if (!st) { rc = -1; goto done; }
    if (sqlite3_bind_text(st, 1, old_reg, -1, SQLITE_TRANSIENT) != SQLITE_OK ||
        sqlite3_step(st) != SQLITE_DONE) rc = -1;
    sqlite3_finalize(st);
    if (rc != 0) goto done;

    st = prep(db, "DELETE FROM code_servers WHERE scope_project = ?1 AND name = ?2");
    if (!st) { rc = -1; goto done; }
    if (sqlite3_bind_text(st, 1, scope, -1, SQLITE_TRANSIENT) != SQLITE_OK ||
        sqlite3_bind_text(st, 2, name, -1, SQLITE_TRANSIENT) != SQLITE_OK ||
        sqlite3_step(st) != SQLITE_DONE) rc = -1;
    else changed = sqlite3_changes(db);
    sqlite3_finalize(st);

done:
    if (sqlite3_exec(db, rc == 0 ? "COMMIT" : "ROLLBACK", NULL, NULL, NULL) != SQLITE_OK) rc = -1;
    if (rc != 0) return -1;
    if (dropped_grants) *dropped_grants = dg;
    if (dropped_projects) *dropped_projects = dp;
    return changed;
}

int kb_code_server_del(sqlite3 *db, const char *scope_project, const char *name, int from_mcp,
                       int *dropped_grants, int *dropped_projects) {
    return kb_code_server_del_checked(db, scope_project, name, from_mcp, NULL, from_mcp ? 0 : 1, dropped_grants, dropped_projects);
}

char *kb_code_server_list_json(sqlite3 *db, const char *project) {
    const char *proj = project ? project : "";
    json_object *arr = json_object_new_array();
    sqlite3_stmt *st = prep(db,
        "SELECT s.scope_project, s.name, s.reg_id, s.command, s.args_json, s.env_json,"
        " s.isolated, s.trust, s.created_by, s.created_at"
        " FROM code_servers s"
        " WHERE (?1 != '' AND s.scope_project = ?1)"
        "    OR (s.scope_project = '' AND (?1 = '' OR NOT EXISTS ("
        "        SELECT 1 FROM code_servers p WHERE p.scope_project = ?1 AND p.name = s.name)))"
        " ORDER BY s.name");
    if (st) {
        sqlite3_bind_text(st, 1, proj, -1, SQLITE_TRANSIENT);
        while (sqlite3_step(st) == SQLITE_ROW) {
            json_object *row = json_object_new_object();
            const char *sp = col(st, 0);
            json_object_object_add(row, "scope", json_object_new_string(*sp ? "project" : "user"));
            json_object_object_add(row, "scope_project", json_object_new_string(sp));
            json_object_object_add(row, "name", json_object_new_string(col(st, 1)));
            json_object_object_add(row, "reg_id", json_object_new_string(col(st, 2)));
            json_object_object_add(row, "command", json_object_new_string(col(st, 3)));
            json_object *args = json_tokener_parse(col(st, 4));
            if (!args || !json_object_is_type(args, json_type_array)) {
                if (args) json_object_put(args);
                args = json_object_new_array();
            }
            json_object_object_add(row, "args", args);
            /* Emit env_keys ONLY; never expose env values. */
            json_object *env_keys = json_object_new_array();
            json_object *env = json_tokener_parse(col(st, 5));
            if (env && json_object_is_type(env, json_type_object)) {
                json_object_object_foreach(env, k, v) {
                    (void)v;
                    json_object_array_add(env_keys, json_object_new_string(k));
                }
            }
            if (env) json_object_put(env);
            json_object_object_add(row, "env_keys", env_keys);
            json_object_object_add(row, "isolated", json_object_new_boolean(sqlite3_column_int(st, 6) != 0));
            json_object_object_add(row, "trust", json_object_new_string(col(st, 7)));
            json_object_object_add(row, "created_by", json_object_new_string(col(st, 8)));
            json_object_object_add(row, "created_at", json_object_new_int64(sqlite3_column_int64(st, 9)));
            json_object_array_add(arr, row);
        }
        sqlite3_finalize(st);
    }
    char *out = strdup(json_object_to_json_string_ext(arr, JSON_C_TO_STRING_PLAIN));
    json_object_put(arr);
    return out;
}

int kb_code_catalog_get(sqlite3 *db, const char *reg_id, const char *owner_project,
                        char **tools_json_out, long long *meta_gen_out) {
    if (tools_json_out) *tools_json_out = NULL;
    if (meta_gen_out) *meta_gen_out = 0;
    if (!db || !reg_id || !*reg_id) return -1;
    const char *owner = owner_project ? owner_project : "";
    sqlite3_stmt *st = prep(db, "SELECT tools_json, meta_gen FROM code_catalogs WHERE reg_id = ?1 AND owner_project = ?2");
    if (!st) return -1;
    sqlite3_bind_text(st, 1, reg_id, -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(st, 2, owner, -1, SQLITE_TRANSIENT);
    int found = sqlite3_step(st) == SQLITE_ROW;
    if (found) {
        if (tools_json_out) *tools_json_out = strdup(col(st, 0));
        if (meta_gen_out) *meta_gen_out = sqlite3_column_int64(st, 1);
    }
    sqlite3_finalize(st);
    return found ? 0 : -1;
}

int kb_code_catalog_set(sqlite3 *db, const char *reg_id, const char *owner_project,
                        const char *tools_json, long long *meta_gen_out) {
    if (meta_gen_out) *meta_gen_out = 0;
    if (!db || !reg_id || !*reg_id) return -1;
    const char *owner = owner_project ? owner_project : "";
    const char *tj = tools_json ? tools_json : "";
    if (sqlite3_exec(db, "BEGIN IMMEDIATE", NULL, NULL, NULL) != SQLITE_OK) return -1;
    sqlite3_stmt *st = prep(db,
        "INSERT INTO code_catalogs(reg_id, owner_project, tools_json, meta_gen, updated_at)"
        " VALUES(?1, ?2, ?3, 1, ?4)"
        " ON CONFLICT(reg_id, owner_project) DO UPDATE SET"
        "  tools_json = excluded.tools_json,"
        "  meta_gen = code_catalogs.meta_gen + 1,"
        "  updated_at = excluded.updated_at");
    int rc = -1;
    if (st) {
        sqlite3_bind_text(st, 1, reg_id, -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(st, 2, owner, -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(st, 3, tj, -1, SQLITE_TRANSIENT);
        sqlite3_bind_int64(st, 4, (long long)time(NULL));
        if (sqlite3_step(st) == SQLITE_DONE) rc = 0;
        sqlite3_finalize(st);
    }
    long long gen = 0;
    if (rc == 0) {
        st = prep(db, "SELECT meta_gen FROM code_catalogs WHERE reg_id = ?1 AND owner_project = ?2");
        if (st) {
            sqlite3_bind_text(st, 1, reg_id, -1, SQLITE_TRANSIENT);
            sqlite3_bind_text(st, 2, owner, -1, SQLITE_TRANSIENT);
            if (sqlite3_step(st) == SQLITE_ROW) gen = sqlite3_column_int64(st, 0);
            else rc = -1;
            sqlite3_finalize(st);
        } else rc = -1;
    }
    if (sqlite3_exec(db, rc == 0 ? "COMMIT" : "ROLLBACK", NULL, NULL, NULL) != SQLITE_OK) rc = -1;
    if (rc == 0 && meta_gen_out) *meta_gen_out = gen;
    return rc;
}

/* Length-prefixed field: "<len>:<bytes>", so no stored text can forge a boundary (CODE-ADMIN-03). */
static void snap_field(char **buf, size_t *len, size_t *cap, const char *tag, const char *v) {
    const char *t = v ? v : "";
    size_t n = strlen(t);
    char head[40];
    int h = snprintf(head, sizeof head, "%s%zu:", tag, n);
    while (*len + (size_t)h + n + 1 > *cap) { *cap *= 2; *buf = realloc(*buf, *cap); if (!*buf) abort(); }
    memcpy(*buf + *len, head, (size_t)h);
    *len += (size_t)h;
    memcpy(*buf + *len, t, n);
    *len += n;
    (*buf)[*len] = '\0';
}

/* Everything a grant decision reads, as one injective string: the (project, reg_id) rules, the catalog generation
 * (absent vs present are distinct; a read failure is an error, not "absent") and, when asked, the policy value. With
 * own_txn the reads share one read transaction; inside the caller's BEGIN IMMEDIATE they already do. NULL on any
 * DB error (callers deny). *policy_out gets the policy value read, or NULL if the key is unset. */
static char *grant_snapshot(sqlite3 *db, const char *project, const char *reg_id, const char *owner_project,
                            const char *policy_key, char **policy_out, int own_txn) {
    if (policy_out) *policy_out = NULL;
    if (own_txn && sqlite3_exec(db, "BEGIN", NULL, NULL, NULL) != SQLITE_OK) return NULL;
    size_t cap = 256, len = 0;
    char *out = malloc(cap), *pol = NULL;
    if (!out) abort();
    out[0] = '\0';
    int good = 0;
    sqlite3_stmt *st = prep(db,
        "SELECT project, tool_pattern, kind, level, class_at_grant, granted_by, granted_at, reason FROM code_grants"
        " WHERE project IN (?1, '" KB_CODE_ALL_PROJECTS "') AND reg_id = ?2 ORDER BY project, tool_pattern, kind");
    if (st && sqlite3_bind_text(st, 1, project, -1, SQLITE_TRANSIENT) == SQLITE_OK &&
        sqlite3_bind_text(st, 2, reg_id, -1, SQLITE_TRANSIENT) == SQLITE_OK) {
        int rc;
        while ((rc = sqlite3_step(st)) == SQLITE_ROW) {
            snap_field(&out, &len, &cap, "r", NULL);
            for (int c = 0; c < 8; c++) snap_field(&out, &len, &cap, "f", (const char *)sqlite3_column_text(st, c));
        }
        good = rc == SQLITE_DONE;
    }
    if (st) sqlite3_finalize(st);
    if (good) {
        good = 0;
        st = prep(db, "SELECT meta_gen FROM code_catalogs WHERE reg_id = ?1 AND owner_project = ?2");
        if (st && sqlite3_bind_text(st, 1, reg_id, -1, SQLITE_TRANSIENT) == SQLITE_OK &&
            sqlite3_bind_text(st, 2, owner_project ? owner_project : "", -1, SQLITE_TRANSIENT) == SQLITE_OK) {
            int rc = sqlite3_step(st);
            if (rc == SQLITE_ROW) {
                char gen[32];
                snprintf(gen, sizeof gen, "%lld", (long long)sqlite3_column_int64(st, 0));
                snap_field(&out, &len, &cap, "c", gen);
                good = 1;
            } else if (rc == SQLITE_DONE) {
                snap_field(&out, &len, &cap, "n", NULL);   /* no catalog yet */
                good = 1;
            }
        }
        if (st) sqlite3_finalize(st);
    }
    if (good && policy_key) {
        good = 0;
        st = prep(db, "SELECT v FROM meta WHERE k = ?1");
        if (st && sqlite3_bind_text(st, 1, policy_key, -1, SQLITE_TRANSIENT) == SQLITE_OK) {
            int rc = sqlite3_step(st);
            if (rc == SQLITE_ROW) {
                const char *v = (const char *)sqlite3_column_text(st, 0);
                pol = strdup(v ? v : "");
                snap_field(&out, &len, &cap, "p", pol);
                good = 1;
            } else if (rc == SQLITE_DONE) {
                snap_field(&out, &len, &cap, "q", NULL);   /* policy unset */
                good = 1;
            }
        }
        if (st) sqlite3_finalize(st);
    }
    if (own_txn && sqlite3_exec(db, good ? "COMMIT" : "ROLLBACK", NULL, NULL, NULL) != SQLITE_OK) good = 0;
    if (!good) { free(out); free(pol); return NULL; }
    if (policy_out) *policy_out = pol;
    else free(pol);
    return out;
}

char *kb_code_grant_snapshot(sqlite3 *db, const char *project, const char *reg_id, const char *owner_project,
                             const char *policy_key, char **policy_out) {
    return grant_snapshot(db, project, reg_id, owner_project, policy_key, policy_out, 1);
}

/* Inside the caller's BEGIN IMMEDIATE (Sol R4-01, CODE-ADMIN-03): the decision still describes what is about to
 * commit. 0 ok, -3 something it depended on changed (re-inspect, re-confirm), -1 DB error. */
static int grant_recheck(sqlite3 *db, const char *project, const char *reg_id, const char *pattern,
                         const char *kind, const struct kb_code_grant_guard *g) {
    if (g->server_name) {
        sqlite3_stmt *st = prep(db,
            "SELECT reg_id FROM code_servers WHERE name = ?1 AND scope_project IN (?2, '')"
            " ORDER BY (scope_project = '') LIMIT 1");
        if (!st) return -1;
        if (sqlite3_bind_text(st, 1, g->server_name, -1, SQLITE_TRANSIENT) != SQLITE_OK ||
            sqlite3_bind_text(st, 2, project, -1, SQLITE_TRANSIENT) != SQLITE_OK) { sqlite3_finalize(st); return -1; }
        int rc = sqlite3_step(st);
        const char *cur = rc == SQLITE_ROW ? (const char *)sqlite3_column_text(st, 0) : NULL;
        int same = cur && strcmp(cur, reg_id) == 0;
        sqlite3_finalize(st);
        if (rc != SQLITE_ROW && rc != SQLITE_DONE) return -1;
        if (!same) return -3;   /* gone, replaced, or now shadowed by another registration */
    } else if (strcmp(reg_id, "cntctr") != 0) {
        return -1;
    }
    if (g->snapshot) {
        char *now = grant_snapshot(db, project, reg_id, g->snapshot_owner, g->snapshot_policy_key, NULL, 0);
        if (!now) return -1;
        int same = strcmp(now, g->snapshot) == 0;
        free(now);
        if (!same) return -3;
    }
    if (g->policy_key) {
        sqlite3_stmt *st = prep(db, "SELECT v FROM meta WHERE k = ?1");
        if (!st) return -1;
        if (sqlite3_bind_text(st, 1, g->policy_key, -1, SQLITE_TRANSIENT) != SQLITE_OK) { sqlite3_finalize(st); return -1; }
        int rc = sqlite3_step(st);
        const char *v = rc == SQLITE_ROW ? (const char *)sqlite3_column_text(st, 0) : NULL;
        int allowed = v && strcmp(v, "allow") == 0;
        sqlite3_finalize(st);
        if (rc != SQLITE_ROW && rc != SQLITE_DONE) return -1;
        if (!allowed) return -3;
    }
    if (!g->human_approved) {
        sqlite3_stmt *st = prep(db,
            "SELECT 1 FROM code_grants WHERE project = ?1 AND reg_id = ?2 AND tool_pattern = ?3"
            " AND (?4 IS NULL OR kind = ?4) AND granted_by = 'human' AND (kind = 'class' OR level = 'deny') LIMIT 1");
        if (!st) return -1;
        int bound = sqlite3_bind_text(st, 1, project, -1, SQLITE_TRANSIENT) == SQLITE_OK &&
                    sqlite3_bind_text(st, 2, reg_id, -1, SQLITE_TRANSIENT) == SQLITE_OK &&
                    sqlite3_bind_text(st, 3, pattern, -1, SQLITE_TRANSIENT) == SQLITE_OK &&
                    (kind ? sqlite3_bind_text(st, 4, kind, -1, SQLITE_TRANSIENT) : sqlite3_bind_null(st, 4)) == SQLITE_OK;
        if (!bound) { sqlite3_finalize(st); return -1; }
        int rc = sqlite3_step(st);
        sqlite3_finalize(st);
        if (rc == SQLITE_ROW) return -3;
        if (rc != SQLITE_DONE) return -1;
    }
    return 0;
}

static int grant_put_impl(sqlite3 *db, const char *project, const char *reg_id, const char *server,
                          const char *pattern, const char *kind, const char *level,
                          const char *class_at_grant, const char *granted_by, const char *reason, int from_mcp,
                          const struct kb_code_grant_guard *guard) {
    if (!db || !project || !*project || !reg_id || !*reg_id || !server || !*server ||
        !pattern || !*pattern || !kind || !level || !granted_by || !*granted_by) return -1;
    if (strcmp(kind, "access") == 0) {
        if (strcmp(level, "allow") != 0 && strcmp(level, "read") != 0 && strcmp(level, "deny") != 0) return -1;
        /* v1 positive allow is exact-tool only (no wildcards). */
        if (strcmp(level, "allow") == 0 && (strchr(pattern, '*') || strchr(pattern, '?'))) return -1;
    } else if (strcmp(kind, "class") == 0) {
        if (strcmp(level, "class:write") != 0 && strcmp(level, "class:destructive") != 0) return -1;
    } else {
        return -1;
    }

    if (strcmp(project, KB_CODE_ALL_PROJECTS) == 0) {
        /* The user-wide policy: a human sets it from the CLI, only as read or deny, never by MCP. */
        if (from_mcp) return -2;
        if (strcmp(granted_by, "human") != 0 || strcmp(kind, "access") != 0 ||
            (strcmp(level, "read") != 0 && strcmp(level, "deny") != 0) || strcmp(reg_id, "cntctr") == 0) return -1;
    }
    if (sqlite3_exec(db, "BEGIN IMMEDIATE", NULL, NULL, NULL) != SQLITE_OK) return -1;
    if (guard) {
        int lrc = grant_recheck(db, project, reg_id, pattern, kind, guard);
        if (lrc != 0) { sqlite3_exec(db, "ROLLBACK", NULL, NULL, NULL); return lrc; }
    }
    if (from_mcp) {
        sqlite3_stmt *chk = prep(db,
            "SELECT 1 FROM code_grants WHERE project = ?1 AND reg_id = ?2 AND tool_pattern = ?3"
            " AND kind = ?4 AND granted_by = 'human' LIMIT 1");
        if (!chk) { sqlite3_exec(db, "ROLLBACK", NULL, NULL, NULL); return -1; }
        if (sqlite3_bind_text(chk, 1, project, -1, SQLITE_TRANSIENT) != SQLITE_OK ||
            sqlite3_bind_text(chk, 2, reg_id, -1, SQLITE_TRANSIENT) != SQLITE_OK ||
            sqlite3_bind_text(chk, 3, pattern, -1, SQLITE_TRANSIENT) != SQLITE_OK ||
            sqlite3_bind_text(chk, 4, kind, -1, SQLITE_TRANSIENT) != SQLITE_OK) {
            sqlite3_finalize(chk);
            sqlite3_exec(db, "ROLLBACK", NULL, NULL, NULL);
            return -1;
        }
        int step_rc = sqlite3_step(chk);
        sqlite3_finalize(chk);
        if (step_rc == SQLITE_ROW) {
            sqlite3_exec(db, "ROLLBACK", NULL, NULL, NULL);
            return -2;
        }
        if (step_rc != SQLITE_DONE) {
            sqlite3_exec(db, "ROLLBACK", NULL, NULL, NULL);
            return -1;
        }
    }

    sqlite3_stmt *st = prep(db,
        "INSERT INTO code_grants(project, reg_id, server, tool_pattern, kind, level, class_at_grant, granted_by, granted_at, reason)"
        " VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)"
        " ON CONFLICT(project, reg_id, tool_pattern, kind) DO UPDATE SET"
        "  server = excluded.server, level = excluded.level, class_at_grant = excluded.class_at_grant,"
        "  granted_by = excluded.granted_by, granted_at = excluded.granted_at, reason = excluded.reason");
    int rc = -1;
    if (st) {
        if (sqlite3_bind_text(st, 1, project, -1, SQLITE_TRANSIENT) == SQLITE_OK &&
            sqlite3_bind_text(st, 2, reg_id, -1, SQLITE_TRANSIENT) == SQLITE_OK &&
            sqlite3_bind_text(st, 3, server, -1, SQLITE_TRANSIENT) == SQLITE_OK &&
            sqlite3_bind_text(st, 4, pattern, -1, SQLITE_TRANSIENT) == SQLITE_OK &&
            sqlite3_bind_text(st, 5, kind, -1, SQLITE_TRANSIENT) == SQLITE_OK &&
            sqlite3_bind_text(st, 6, level, -1, SQLITE_TRANSIENT) == SQLITE_OK &&
            sqlite3_bind_text(st, 7, class_at_grant ? class_at_grant : "", -1, SQLITE_TRANSIENT) == SQLITE_OK &&
            sqlite3_bind_text(st, 8, granted_by, -1, SQLITE_TRANSIENT) == SQLITE_OK &&
            sqlite3_bind_int64(st, 9, (long long)time(NULL)) == SQLITE_OK &&
            sqlite3_bind_text(st, 10, reason ? reason : "", -1, SQLITE_TRANSIENT) == SQLITE_OK &&
            sqlite3_step(st) == SQLITE_DONE) rc = 0;
        sqlite3_finalize(st);
    }
    if (sqlite3_exec(db, rc == 0 ? "COMMIT" : "ROLLBACK", NULL, NULL, NULL) != SQLITE_OK) rc = -1;
    return rc;
}

int kb_code_grant_put(sqlite3 *db, const char *project, const char *reg_id, const char *server,
                      const char *pattern, const char *kind, const char *level,
                      const char *class_at_grant, const char *granted_by, const char *reason, int from_mcp) {
    return grant_put_impl(db, project, reg_id, server, pattern, kind, level, class_at_grant, granted_by,
                          reason, from_mcp, NULL);
}

int kb_code_grant_put_checked(sqlite3 *db, const char *project, const char *reg_id, const char *server,
                              const char *pattern, const char *kind, const char *level,
                              const char *class_at_grant, const char *granted_by, const char *reason,
                              int from_mcp, const struct kb_code_grant_guard *guard) {
    if (!guard) return -1;
    return grant_put_impl(db, project, reg_id, server, pattern, kind, level, class_at_grant, granted_by,
                          reason, from_mcp, guard);
}

static int grant_del_impl(sqlite3 *db, const char *project, const char *reg_id, const char *pattern,
                          const char *kind, int from_mcp, const struct kb_code_grant_guard *guard) {
    if (!db || !project || !*project || !reg_id || !*reg_id || !pattern || !*pattern) return -1;
    int has_kind = kind && *kind;
    if (from_mcp && strcmp(project, KB_CODE_ALL_PROJECTS) == 0) return -2;
    if (sqlite3_exec(db, "BEGIN IMMEDIATE", NULL, NULL, NULL) != SQLITE_OK) return -1;
    if (guard) {
        int lrc = grant_recheck(db, project, reg_id, pattern, has_kind ? kind : NULL, guard);
        if (lrc != 0) { sqlite3_exec(db, "ROLLBACK", NULL, NULL, NULL); return lrc; }
    }
    if (from_mcp) {
        sqlite3_stmt *chk = prep(db, has_kind
            ? "SELECT 1 FROM code_grants WHERE project = ?1 AND reg_id = ?2 AND tool_pattern = ?3 AND kind = ?4 AND granted_by = 'human' LIMIT 1"
            : "SELECT 1 FROM code_grants WHERE project = ?1 AND reg_id = ?2 AND tool_pattern = ?3 AND granted_by = 'human' LIMIT 1");
        if (!chk) { sqlite3_exec(db, "ROLLBACK", NULL, NULL, NULL); return -1; }
        int bind_ok = sqlite3_bind_text(chk, 1, project, -1, SQLITE_TRANSIENT) == SQLITE_OK &&
                      sqlite3_bind_text(chk, 2, reg_id, -1, SQLITE_TRANSIENT) == SQLITE_OK &&
                      sqlite3_bind_text(chk, 3, pattern, -1, SQLITE_TRANSIENT) == SQLITE_OK &&
                      (!has_kind || sqlite3_bind_text(chk, 4, kind, -1, SQLITE_TRANSIENT) == SQLITE_OK);
        if (!bind_ok) {
            sqlite3_finalize(chk);
            sqlite3_exec(db, "ROLLBACK", NULL, NULL, NULL);
            return -1;
        }
        int step_rc = sqlite3_step(chk);
        sqlite3_finalize(chk);
        if (step_rc == SQLITE_ROW) {
            sqlite3_exec(db, "ROLLBACK", NULL, NULL, NULL);
            return -2;
        }
        if (step_rc != SQLITE_DONE) {
            sqlite3_exec(db, "ROLLBACK", NULL, NULL, NULL);
            return -1;
        }
    }
    sqlite3_stmt *st = prep(db, has_kind
        ? "DELETE FROM code_grants WHERE project = ?1 AND reg_id = ?2 AND tool_pattern = ?3 AND kind = ?4"
        : "DELETE FROM code_grants WHERE project = ?1 AND reg_id = ?2 AND tool_pattern = ?3");
    int changed = -1;
    if (st) {
        int bind_ok = sqlite3_bind_text(st, 1, project, -1, SQLITE_TRANSIENT) == SQLITE_OK &&
                      sqlite3_bind_text(st, 2, reg_id, -1, SQLITE_TRANSIENT) == SQLITE_OK &&
                      sqlite3_bind_text(st, 3, pattern, -1, SQLITE_TRANSIENT) == SQLITE_OK &&
                      (!has_kind || sqlite3_bind_text(st, 4, kind, -1, SQLITE_TRANSIENT) == SQLITE_OK);
        if (bind_ok && sqlite3_step(st) == SQLITE_DONE) changed = sqlite3_changes(db);
        sqlite3_finalize(st);
    }
    if (sqlite3_exec(db, changed >= 0 ? "COMMIT" : "ROLLBACK", NULL, NULL, NULL) != SQLITE_OK) return -1;
    return changed;
}

int kb_code_grant_del(sqlite3 *db, const char *project, const char *reg_id, const char *pattern,
                      const char *kind, int from_mcp) {
    return grant_del_impl(db, project, reg_id, pattern, kind, from_mcp, NULL);
}

int kb_code_grant_del_checked(sqlite3 *db, const char *project, const char *reg_id, const char *pattern,
                              const char *kind, int from_mcp, const struct kb_code_grant_guard *guard) {
    if (!guard) return -1;
    return grant_del_impl(db, project, reg_id, pattern, kind, from_mcp, guard);
}

/* What the existing rows at (project, reg_id, pattern[, kind]) are, before a human confirms a change. */
int kb_code_grant_inspect(sqlite3 *db, const char *project, const char *reg_id, const char *pattern,
                          const char *kind, int *has_human, int *human_protected) {
    *has_human = *human_protected = 0;
    if (!db || !project || !reg_id || !pattern) return -2;
    sqlite3_stmt *st = prep(db,
        "SELECT kind, level, granted_by FROM code_grants WHERE project = ?1 AND reg_id = ?2 AND tool_pattern = ?3"
        " AND (?4 IS NULL OR kind = ?4)");
    if (!st) return -2;
    int bound = sqlite3_bind_text(st, 1, project, -1, SQLITE_TRANSIENT) == SQLITE_OK &&
                sqlite3_bind_text(st, 2, reg_id, -1, SQLITE_TRANSIENT) == SQLITE_OK &&
                sqlite3_bind_text(st, 3, pattern, -1, SQLITE_TRANSIENT) == SQLITE_OK &&
                (kind && *kind ? sqlite3_bind_text(st, 4, kind, -1, SQLITE_TRANSIENT) : sqlite3_bind_null(st, 4)) == SQLITE_OK;
    if (!bound) { sqlite3_finalize(st); return -2; }
    int rc;
    while ((rc = sqlite3_step(st)) == SQLITE_ROW) {
        const char *k = (const char *)sqlite3_column_text(st, 0), *lv = (const char *)sqlite3_column_text(st, 1),
                   *by = (const char *)sqlite3_column_text(st, 2);
        if (by && strcmp(by, "human") == 0) {
            *has_human = 1;
            if ((k && strcmp(k, "class") == 0) || (lv && strcmp(lv, "deny") == 0)) *human_protected = 1;
        }
    }
    sqlite3_finalize(st);
    return rc == SQLITE_DONE ? 0 : -2;
}

/* Project roots holding a project-local row named `name` (JSON array), or NULL on a DB error. */
char *kb_code_server_shadows_json(sqlite3 *db, const char *name) {
    sqlite3_stmt *st = prep(db, "SELECT scope_project FROM code_servers WHERE name = ?1 AND scope_project != '' ORDER BY scope_project");
    if (!st) return NULL;
    if (sqlite3_bind_text(st, 1, name, -1, SQLITE_TRANSIENT) != SQLITE_OK) { sqlite3_finalize(st); return NULL; }
    json_object *arr = json_object_new_array();
    int rc;
    while ((rc = sqlite3_step(st)) == SQLITE_ROW) {
        const char *sp = (const char *)sqlite3_column_text(st, 0);
        json_object_array_add(arr, json_object_new_string(sp ? sp : ""));
    }
    sqlite3_finalize(st);
    char *out = NULL;
    if (rc == SQLITE_DONE) out = strdup(json_object_to_json_string_ext(arr, JSON_C_TO_STRING_PLAIN));
    json_object_put(arr);
    return out;
}

int kb_code_project_has_usable(sqlite3 *db, const char *project) {
    if (!db || !project || !*project) return -1;
    sqlite3_stmt *st = prep(db,
        "SELECT 1 FROM code_servers s"
        " WHERE (s.scope_project = ?1 OR (s.scope_project = '' AND NOT EXISTS ("
        "   SELECT 1 FROM code_servers p WHERE p.scope_project = ?1 AND p.name = s.name)))"
        "  AND EXISTS (SELECT 1 FROM code_grants g WHERE g.reg_id = s.reg_id AND g.project IN (?1, '" KB_CODE_ALL_PROJECTS "')"
        "              AND g.kind = 'access' AND g.level != 'deny') LIMIT 1");
    if (!st) return -1;
    if (sqlite3_bind_text(st, 1, project, -1, SQLITE_TRANSIENT) != SQLITE_OK) { sqlite3_finalize(st); return -1; }
    int rc = sqlite3_step(st);
    sqlite3_finalize(st);
    return rc == SQLITE_ROW ? 1 : rc == SQLITE_DONE ? 0 : -1;
}

int kb_code_reg_user_scoped(sqlite3 *db, const char *reg_id) {
    if (!db || !reg_id || !*reg_id) return 0;
    sqlite3_stmt *st = prep(db, "SELECT 1 FROM code_servers WHERE reg_id = ?1 AND scope_project = '' LIMIT 1");
    if (!st) return 0;
    sqlite3_bind_text(st, 1, reg_id, -1, SQLITE_TRANSIENT);
    int rc = sqlite3_step(st);
    sqlite3_finalize(st);
    return rc == SQLITE_ROW;
}

int kb_code_has_non_deny_grant(sqlite3 *db, const char *project, const char *reg_id) {
    if (!db || !project || !*project || !reg_id || !*reg_id) return 0;
    sqlite3_stmt *st = prep(db,
        "SELECT 1 FROM code_grants WHERE project IN (?1, '" KB_CODE_ALL_PROJECTS "') AND reg_id = ?2"
        " AND kind = 'access' AND level != 'deny' LIMIT 1");
    if (!st) return 0;
    sqlite3_bind_text(st, 1, project, -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(st, 2, reg_id, -1, SQLITE_TRANSIENT);
    int found = sqlite3_step(st) == SQLITE_ROW ? 1 : 0;
    sqlite3_finalize(st);
    return found;
}

char *kb_code_grant_list_json(sqlite3 *db, const char *project, const char *server) {
    const char *proj = project ? project : "";
    const char *srv = server ? server : "";
    json_object *arr = json_object_new_array();
    sqlite3_stmt *st = prep(db,
        "SELECT g.project, g.reg_id, g.server, g.tool_pattern, g.kind, g.level,"
        " g.class_at_grant, g.granted_by, g.granted_at, g.reason"
        " FROM code_grants g"
        " WHERE g.project IN (?1, '" KB_CODE_ALL_PROJECTS "')"
        "  AND (g.reg_id = 'cntctr' OR g.reg_id IN ("
        "    SELECT s.reg_id FROM code_servers s"
        "    WHERE s.scope_project = ?1"
        "       OR (s.scope_project = '' AND NOT EXISTS ("
        "           SELECT 1 FROM code_servers p WHERE p.scope_project = ?1 AND p.name = s.name))"
        "  ))"
        "  AND (?2 = '' OR g.server = ?2)"
        " ORDER BY g.server, g.tool_pattern, g.kind, g.project");
    if (st) {
        sqlite3_bind_text(st, 1, proj, -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(st, 2, srv, -1, SQLITE_TRANSIENT);
        while (sqlite3_step(st) == SQLITE_ROW) {
            json_object *row = json_object_new_object();
            json_object_object_add(row, "project", json_object_new_string(col(st, 0)));
            json_object_object_add(row, "scope", json_object_new_string(strcmp(col(st, 0), KB_CODE_ALL_PROJECTS) == 0 ? "all-projects" : "project"));
            json_object_object_add(row, "reg_id", json_object_new_string(col(st, 1)));
            json_object_object_add(row, "server", json_object_new_string(col(st, 2)));
            json_object_object_add(row, "tool_pattern", json_object_new_string(col(st, 3)));
            json_object_object_add(row, "kind", json_object_new_string(col(st, 4)));
            json_object_object_add(row, "level", json_object_new_string(col(st, 5)));
            json_object_object_add(row, "class_at_grant", json_object_new_string(col(st, 6)));
            json_object_object_add(row, "granted_by", json_object_new_string(col(st, 7)));
            json_object_object_add(row, "granted_at", json_object_new_int64(sqlite3_column_int64(st, 8)));
            json_object_object_add(row, "reason", json_object_new_string(col(st, 9)));
            json_object_array_add(arr, row);
        }
        sqlite3_finalize(st);
    }
    char *out = strdup(json_object_to_json_string_ext(arr, JSON_C_TO_STRING_PLAIN));
    json_object_put(arr);
    return out;
}

static int code_glob_match(const char *pat, const char *str) {
    const char *p = pat, *s = str, *star = NULL, *match = NULL;
    while (*s) {
        if (*p == '?' || *p == *s) { p++; s++; }
        else if (*p == '*') { star = p++; match = s; }
        else if (star) { p = star + 1; s = ++match; }
        else return 0;
    }
    while (*p == '*') p++;
    return *p == '\0';
}

struct code_pat_spec { int exact, literals, stars; size_t len; };

static struct code_pat_spec code_pattern_spec(const char *pat) {
    struct code_pat_spec sp = {1, 0, 0, 0};
    for (const char *p = pat; *p; p++) {
        sp.len++;
        if (*p == '*') { sp.exact = 0; sp.stars++; }
        else if (*p == '?') { sp.exact = 0; }
        else { sp.literals++; }
    }
    return sp;
}

/* >0 if a is more specific than b, <0 if less, 0 if equal specificity. */
static int code_spec_cmp(struct code_pat_spec a, struct code_pat_spec b) {
    if (a.exact != b.exact) return a.exact - b.exact;
    if (a.literals != b.literals) return a.literals - b.literals;
    if (a.stars != b.stars) return b.stars - a.stars;
    if (a.len != b.len) return a.len > b.len ? 1 : -1;
    return 0;
}

static const char *code_class_name(enum code_class c) {
    if (c == CODE_READ) return "read";
    if (c == CODE_WRITE) return "write";
    return "destructive";
}

static int code_parse_class(const char *s) {
    if (!s) return 0;
    if (strcmp(s, "read") == 0) return CODE_READ;
    if (strcmp(s, "write") == 0 || strcmp(s, "class:write") == 0) return CODE_WRITE;
    if (strcmp(s, "destructive") == 0 || strcmp(s, "class:destructive") == 0) return CODE_DESTRUCTIVE;
    return 0;
}

static char *code_why(const char *fmt_str, ...) {
    va_list ap;
    char *s = NULL;
    va_start(ap, fmt_str);
    if (vasprintf(&s, fmt_str, ap) < 0) s = strdup("denied");
    va_end(ap);
    return s;
}

int kb_code_check_grant(sqlite3 *db, const char *project, const char *reg_id, const char *tool,
                        enum code_class base_class, enum code_class *effective_out, char **why) {
    if (why) *why = NULL;
    if (effective_out) *effective_out = base_class;
    if (!db || !project || !*project || !reg_id || !*reg_id || !tool || !*tool) {
        if (why) *why = strdup("invalid grant check parameters");
        return -1;
    }

    int has_class_rule = 0;
    struct code_pat_spec best_class_spec = {0, 0, 0, 0};
    enum code_class best_class_val = base_class;
    int human_class_floor = 0;

    int has_deny = 0, deny_global = 0;
    char deny_pat[256] = "", deny_reason[256] = "";

    /* Access rules by scope: [0] this project's own, [1] the all-projects policy. A project-local access rule beats the
     * all-projects one whatever its specificity; the all-projects rule decides only when no local access rule matches. */
    struct { int has; struct code_pat_spec spec; char level[32], cag[32], pat[256]; } acc[2] = {{0}, {0}};

    sqlite3_stmt *st = prep(db,
        "SELECT tool_pattern, kind, level, class_at_grant, reason, granted_by, project = '" KB_CODE_ALL_PROJECTS "'"
        " FROM code_grants WHERE project IN (?1, '" KB_CODE_ALL_PROJECTS "') AND reg_id = ?2");
    if (!st) {
        if (why) *why = strdup("grant lookup failed");
        return -1;
    }
    if (sqlite3_bind_text(st, 1, project, -1, SQLITE_TRANSIENT) != SQLITE_OK ||
        sqlite3_bind_text(st, 2, reg_id, -1, SQLITE_TRANSIENT) != SQLITE_OK) {
        sqlite3_finalize(st);
        if (why) *why = strdup("grant lookup failed");
        return -1;
    }
    int step_rc;
    while ((step_rc = sqlite3_step(st)) == SQLITE_ROW) {
        const char *pat = col(st, 0), *kind = col(st, 1), *level = col(st, 2),
                   *cag = col(st, 3), *reason = col(st, 4), *granted_by = col(st, 5);
        int global = sqlite3_column_int(st, 6) != 0;
        if (!code_glob_match(pat, tool)) continue;
        struct code_pat_spec sp = code_pattern_spec(pat);
        if (strcmp(kind, "class") == 0) {
            if (global) continue;   /* the all-projects policy holds access rules only */
            int cls = code_parse_class(level);
            if (cls > 0) {
                int cmp = has_class_rule ? code_spec_cmp(sp, best_class_spec) : 1;
                if (cmp > 0) {
                    has_class_rule = 1;
                    best_class_spec = sp;
                    best_class_val = (enum code_class)cls;
                } else if (cmp == 0 && cls > (int)best_class_val) {
                    best_class_val = (enum code_class)cls;
                }
                if (strcmp(granted_by, "human") == 0 && cls > human_class_floor)
                    human_class_floor = cls;
            }
        } else if (strcmp(kind, "access") == 0) {
            if (strcmp(level, "deny") == 0) {
                if (!has_deny || (deny_global && !global)) {   /* name a project's own deny before the user-wide one */
                    has_deny = 1;
                    deny_global = global;
                    snprintf(deny_pat, sizeof deny_pat, "%s", pat);
                    snprintf(deny_reason, sizeof deny_reason, "%s", reason);
                }
            } else if (strcmp(level, "allow") == 0 || strcmp(level, "read") == 0) {
                int s = global ? 1 : 0;
                int cmp = acc[s].has ? code_spec_cmp(sp, acc[s].spec) : 1;
                if (cmp > 0) {
                    acc[s].has = 1;
                    acc[s].spec = sp;
                    snprintf(acc[s].level, sizeof acc[s].level, "%s", level);
                    snprintf(acc[s].cag, sizeof acc[s].cag, "%s", cag);
                    snprintf(acc[s].pat, sizeof acc[s].pat, "%s", pat);
                }
            }
        }
    }
    sqlite3_finalize(st);
    if (step_rc != SQLITE_DONE) {
        if (why) *why = strdup("grant lookup interrupted or failed");
        return -1;
    }

    /* Pass 1: effective class (class overrides can raise, never lower below base_class or human floor). */
    enum code_class eff = base_class;
    if (has_class_rule && best_class_val > eff) eff = best_class_val;
    if (human_class_floor > (int)eff) eff = (enum code_class)human_class_floor;
    if (effective_out) *effective_out = eff;

    /* Pass 2: access decision (a deny from either scope beats everything: a project cannot undo the user-wide policy;
     * default-deny when no access rule matches). */
    if (has_deny) {
        const char *where = deny_global ? " [all-projects]" : "";
        if (why) *why = deny_reason[0] ? code_why("denied by rule %s%s (%s)", deny_pat, where, deny_reason)
                                       : code_why("denied by rule %s%s", deny_pat, where);
        return 1;
    }
    int has_access = acc[0].has || acc[1].has, s = acc[0].has ? 0 : 1;
    const char *acc_level = acc[s].level, *acc_cag = acc[s].cag, *acc_pat = acc[s].pat;
    if (!has_access) {
        if (why) *why = code_why("no grant covers %s (class %s; default-deny)", tool, code_class_name(eff));
        return 1;
    }
    if (strcmp(acc_level, "read") == 0) {
        if (eff == CODE_READ) return 0;
        if (why) *why = code_why("tool %s has class %s, exceeding read grant (%s%s)", tool, code_class_name(eff), acc_pat,
                                 s ? " [all-projects]" : "");
        return 1;
    }
    if (strcmp(acc_level, "allow") == 0) {
        int granted_cls = code_parse_class(acc_cag);
        if (granted_cls > 0 && (int)eff <= granted_cls) return 0;
        if (why) *why = code_why("tool %s class rose to %s (granted at %s); re-approval required",
                                 tool, code_class_name(eff), acc_cag[0] ? acc_cag : "unknown");
        return 1;
    }
    if (why) *why = strdup("denied");
    return 1;
}

int kb_code_run_save(sqlite3 *db, const char *id, const char *project, const char *caller,
                     const char *script_hash, const char *result, const char *logs,
                     const char *calls, const char *denied, int retained_capped, int ttl_sec) {
    if (!db || !id || !*id || !project || !*project || !caller || !script_hash) return -1;
    long long now = (long long)time(NULL);
    long long expires = now + (long long)ttl_sec;
    sqlite3_stmt *st = prep(db,
        "INSERT OR REPLACE INTO code_runs"
        "(id, project, caller, script_hash, result, logs, calls, denied, retained_capped, created, expires, expired)"
        " VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, 0)");
    if (!st) return -1;
    sqlite3_bind_text(st, 1, id, -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(st, 2, project, -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(st, 3, caller, -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(st, 4, script_hash, -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(st, 5, result ? result : "", -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(st, 6, logs ? logs : "", -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(st, 7, calls ? calls : "", -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(st, 8, denied ? denied : "", -1, SQLITE_TRANSIENT);
    sqlite3_bind_int(st, 9, retained_capped ? 1 : 0);
    sqlite3_bind_int64(st, 10, now);
    sqlite3_bind_int64(st, 11, expires);
    int rc = sqlite3_step(st) == SQLITE_DONE ? 0 : -1;
    sqlite3_finalize(st);
    return rc;
}

int kb_code_run_expand(sqlite3 *db, const char *project, const char *id, const char *part,
                       size_t offset, size_t limit, char **slice, size_t *total_len, int *retained_capped,
                       size_t *start_out) {
    if (slice) *slice = NULL;
    if (total_len) *total_len = 0;
    if (retained_capped) *retained_capped = 0;
    if (start_out) *start_out = 0;
    if (!db || !project || !*project || !id || !*id || !part) return -1;
    const char *sql = NULL;
    if (strcmp(part, "result") == 0)
        sql = "SELECT result, retained_capped, expired, expires FROM code_runs WHERE id = ?1 AND project = ?2";
    else if (strcmp(part, "logs") == 0)
        sql = "SELECT logs, retained_capped, expired, expires FROM code_runs WHERE id = ?1 AND project = ?2";
    else if (strcmp(part, "calls") == 0)
        sql = "SELECT calls, retained_capped, expired, expires FROM code_runs WHERE id = ?1 AND project = ?2";
    else if (strcmp(part, "denied") == 0)
        sql = "SELECT denied, retained_capped, expired, expires FROM code_runs WHERE id = ?1 AND project = ?2";
    else return -1;

    sqlite3_stmt *st = prep(db, sql);
    if (!st) return -2;
    if (sqlite3_bind_text(st, 1, id, -1, SQLITE_TRANSIENT) != SQLITE_OK ||
        sqlite3_bind_text(st, 2, project, -1, SQLITE_TRANSIENT) != SQLITE_OK) {
        sqlite3_finalize(st);
        return -2;
    }
    int srow = sqlite3_step(st);
    if (srow != SQLITE_ROW) {
        sqlite3_finalize(st);
        return srow == SQLITE_DONE ? -1 : -2;   /* -1 not found; -2 the store could not say (never "not found") */
    }
    int is_expired = sqlite3_column_int(st, 2) != 0 || sqlite3_column_int64(st, 3) <= (long long)time(NULL);
    if (is_expired) {
        sqlite3_finalize(st);
        return 1;
    }
    if (retained_capped) *retained_capped = sqlite3_column_int(st, 1);
    const unsigned char *raw = sqlite3_column_text(st, 0);
    size_t len = raw ? (size_t)sqlite3_column_bytes(st, 0) : 0;
    if (total_len) *total_len = len;
    if (limit == 0 || limit > 65536) limit = 65536;

    size_t start = offset;
    if (start >= len || !raw) {
        sqlite3_finalize(st);
        if (start_out) *start_out = len;
        if (slice) *slice = strdup("");
        return 0;
    }
    while (start < len && (raw[start] & 0xC0) == 0x80) start++;
    if (start >= len) {
        sqlite3_finalize(st);
        if (start_out) *start_out = len;
        if (slice) *slice = strdup("");
        return 0;
    }
    if (start_out) *start_out = start;
    size_t end = (len - start > limit) ? start + limit : len;
    if (end < len) {
        while (end > start && (raw[end] & 0xC0) == 0x80) end--;
        if (end == start) {
            end = start + 1;
            while (end < len && (raw[end] & 0xC0) == 0x80) end++;
        }
    }
    if (slice) {
        size_t n = end - start;
        char *buf = malloc(n + 1);
        if (buf) {
            memcpy(buf, raw + start, n);
            buf[n] = '\0';
        }
        *slice = buf;
    }
    sqlite3_finalize(st);
    return (slice && !*slice) ? -1 : 0;
}

int kb_code_run_sweep(sqlite3 *db, time_t now) {
    if (!db) return -1;
    sqlite3_stmt *st = prep(db,
        "UPDATE code_runs SET expired = 1, result = NULL, logs = NULL, calls = NULL, denied = NULL"
        " WHERE expired = 0 AND expires <= ?1");
    if (!st) return -1;
    sqlite3_bind_int64(st, 1, (long long)now);
    int n = sqlite3_step(st) == SQLITE_DONE ? sqlite3_changes(db) : -1;
    sqlite3_finalize(st);
    return n;
}
