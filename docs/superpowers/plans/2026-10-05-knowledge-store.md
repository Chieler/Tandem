# cntctr Knowledge Store Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task by task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give every cntctr agent a persistent, layered, searchable knowledge store with insights, skills, docs and history. SQLite is the source of truth, and claude-mem is used as an optional semantic index.

**Architecture:** A new `kb.c` holds all the SQL and knows nothing about tmux or MCP. `cntctr.c` adds the rest:
- project resolution through `git`
- a best-effort claude-mem mirror through `curl`
- six new tools: `note`, `recall`, `read`, `forget`, `project`, `distill`
- automatic history logging on `send`, `spawn` and `reply`
- knowledge hints in envelopes
- the index in the `initialize` instructions

External programs run through the existing `run()`, using fork/execvp with argv and never a shell.

**Tech Stack:** C11, json-c, system `libsqlite3` (macOS SDK 3.43.2, FTS5 built in), `git`, `curl`, bash plus jq for tests, and a python3 `http.server` stub for the mirror tests.

**Spec:** `docs/superpowers/specs/2026-10-05-knowledge-store-design.md`

## Global Constraints

- Never use `system()`, `popen()` or a shell. Use `run()`/`TMUX()` with argv arrays, and send text over stdin.
- Use only libraries already on the machine: json-c and system sqlite3. `git` and `curl` run as child processes.
- The database lives at `$CNTCTR_DB`, or by default at `~/.local/share/cntctr/kb.db`. It runs in WAL mode with `busy_timeout` 5000.
- `CNTCTR_MEM_URL` defaults to `http://127.0.0.1:37701`. An empty value turns mirroring off.
- Mirror and history failures never fail a tool call.
- History is `private`, append-only, never mirrored, and can't be forgotten or superseded.
- Entry list lines have the exact format `id [layer] title — summary`, where the dash is U+2014 with a space on each side.
- `make test` builds with `-Werror -fsanitize=address,undefined`, so every new static function must be used in the same task that adds it.
- Tests never touch the real database or claude-mem. `test.sh` exports `CNTCTR_DB=$TMPD/kb.db` and `CNTCTR_MEM_URL=` (empty).

## Review Focus

- **Text that isn't plain ASCII or is very long.** A summary or title cut in the middle of a UTF-8 character would send invalid JSON to the harness. `first_line()` cuts on character boundaries, and Task 3 tests it.
- **A task text of thousands of words.** It becomes the envelope's FTS query. `fts_query()` caps it at 32 tokens, and Task 4 tests that a long send is still delivered.
- **A database that's missing or can't be written.** Messaging must keep working. Task 3 tests `send` and `note` with `CNTCTR_DB=/nonexistent/x.db`.
- **Search text containing FTS5 syntax** such as `"`, `AND` or `(`. It's quoted token by token, and Task 2 tests it.
- **A pane whose cwd isn't a git repo.** The project key falls back to the directory itself, and Task 1 tests it.

---

### Task 1: Store, project resolution, and the `note`, `read` and `project` tools

**Files:**
- Create: `kb.h`, `kb.c`
- Modify: `Makefile`, `cntctr.c` (includes, a new knowledge section before `/* ---- agents and delivery ---- */`, new tools before `/* ---- dispatch ---- */`, `dispatch`, `TOOL_FNS`, `TOOLS`), `test.sh` (the export line, plus a knowledge section before `# ---- summary ----`)

**Interfaces:**
- Produces (kb.h): every `kb_*` function listed below.
- Produces (cntctr.c):
  - `static sqlite3 *kb(char **err)`
  - `struct project { char root[4096], key[1024], base[256]; }`
  - `static void resolve_project(sqlite3 *db, const char *pane, struct project *p)`
  - `static char *first_line(const char *text, size_t max)`
  - `static sqlite3 *kb_for_caller(struct project *p, char **res)`
  - the `KFROM` schema macro
  - `tool_note`, `tool_read`, `tool_project`

- [ ] **Step 1: Write the failing tests**

In `test.sh`, change the export line so tests never touch your real store or claude-mem:

```bash
export BIN INIT CNTCTR_ENTER_DELAY_MS=50 LC_ALL=en_US.UTF-8 PATH="$TMPD/bin:$PATH" CNTCTR_DB="$TMPD/kb.db" CNTCTR_MEM_URL=
```

Insert this just before `# ---- summary ----`:

```bash
# ---- knowledge ----
KA=$(newpane ka)
out=$(call "$KA" note '{"layer":"insight","title":"Enter in copy-mode","summary":"send-keys Enter goes to copy-mode; paste a CR instead","body":"Seen with Claude 2.1.287.","tags":"scrollback","refs":"cntctr.c:inject"}')
check "note returns an id" "$(txt "$out")" "noted "
nid=$(txt "$out" | sed 's/noted //')
same "entry id is <machine>-<ms>-<rand>" "$(printf '%s' "$nid" | grep -cE '^[0-9a-f]{8}-[0-9a-f]+-[0-9a-f]{4}$')" 1
out=$(txt "$(call "$KA" read "{\"id\":\"$nid\"}")")
check "read shows layer" "$out" "layer: insight"
check "read shows summary" "$out" "summary: send-keys Enter goes to copy-mode; paste a CR instead"
check "read shows tags" "$out" "tags: scrollback"
check "read shows refs" "$out" "refs: cntctr.c:inject"
check "read shows the agent" "$out" "(agent ka)"
check "read shows visibility" "$out" "visibility: shared"
check "read shows body" "$out" "Seen with Claude 2.1.287."
same "read unknown id" "$(txt "$(call "$KA" read '{"id":"nope"}')")" "entry nope not found"
same "note without summary" "$(txt "$(call "$KA" note '{"layer":"insight","title":"x"}')")" "note needs layer (insight, skill or doc), title and summary"
same "note cannot write history" "$(txt "$(call "$KA" note '{"layer":"history","title":"x","summary":"y"}')")" "note needs layer (insight, skill or doc), title and summary"

mkdir "$TMPD/repo" "$TMPD/plain"
git -C "$TMPD/repo" init -q
git -C "$TMPD/repo" remote add origin git@GitHub.com:X/y.git
KR=$(t new-window -d -n kr -c "$TMPD/repo" -P -F '#{pane_id}' cat)
t set -p -t "$KR" @cntctr_name kr
check "project key from the origin remote" "$(txt "$(call "$KR" project '{}')")" "project github.com/X/y (root "
git -C "$TMPD/repo" remote set-url origin https://github.com/X/y.git/
check "https remote normalizes the same" "$(txt "$(call "$KR" project '{}')")" "project github.com/X/y (root "
same "project override" "$(txt "$(call "$KR" project '{"key":"foo"}')" | cut -d' ' -f1-2)" "project foo"
same "override persists" "$(txt "$(call "$KR" project '{}')" | cut -d' ' -f1-2)" "project foo"
call "$KR" project '{"key":""}' >/dev/null
check "empty key removes the override" "$(txt "$(call "$KR" project '{}')")" "project github.com/X/y"
KP=$(t new-window -d -n kp -c "$TMPD/plain" -P -F '#{pane_id}' cat)
t set -p -t "$KP" @cntctr_name kp
check "outside git the key is the directory" "$(txt "$(call "$KP" project '{}')")" "/plain (root "
```

- [ ] **Step 2: Run the tests and confirm they fail**

Run: `make test 2>&1 | tail -30`
Expected: FAIL lines such as `FAIL: note returns an id` and `got: unknown tool note`, ending in `N passed, M failed`.

- [ ] **Step 3: Write `kb.h`**

```c
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
```

- [ ] **Step 4: Write `kb.c`**

```c
/* The knowledge store: entries in SQLite with an FTS5 index. Knows nothing about tmux or MCP. */
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

/* A failed prepare leaves NULL, which every later sqlite3 call treats as a no-op error. */
static sqlite3_stmt *prep(sqlite3 *db, const char *sql) {
    sqlite3_stmt *st = NULL;
    sqlite3_prepare_v2(db, sql, -1, &st, NULL);
    return st;
}

/* First column of the first row of `sql` with ?1 = a, or NULL (caller frees). */
static char *text1(sqlite3 *db, const char *sql, const char *a) {
    sqlite3_stmt *st = prep(db, sql);
    char *r = NULL;
    sqlite3_bind_text(st, 1, a, -1, SQLITE_TRANSIENT);
    if (sqlite3_step(st) == SQLITE_ROW && sqlite3_column_type(st, 0) != SQLITE_NULL) r = strdup(col(st, 0));
    sqlite3_finalize(st);
    return r;
}

/* Run `sql` with ?1 = a and ?2 = b (NULL binds NULL). Returns the rows changed, or -1. */
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
    sqlite3_exec(db, "PRAGMA journal_mode=WAL", NULL, NULL, NULL);   /* persists once set; failing only costs speed */
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
    sqlite3_close(db);   /* rolls back */
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

/* Rows (id, layer, title, summary) as "id [layer] title — summary" lines; finalizes st. */
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

/* Words of `q` as a quoted FTS5 OR query, so user text can't be FTS syntax.
 * ponytail: first 32 words only; a long task text would otherwise be a huge query. */
static char *fts_query(const char *q) {
    char *out = malloc(strlen(q) * 4 + 8), *o = out;
    *o = '\0';
    int words = 0;
    for (const unsigned char *s = (const unsigned char *)q; *s && words < 32;) {
        if (!(isalnum(*s) || *s >= 0x80)) {
            s++;
            continue;
        }
        if (words++) o += sprintf(o, " OR ");
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
```

- [ ] **Step 5: Update the `Makefile`**

Replace the `LIBS` line and the two build rules:

```make
LIBS = -L$(JSONC)/lib -ljson-c -lsqlite3

cntctr: cntctr.c kb.c kb.h
	$(CC) $(CFLAGS) $(FLAGS) -o $@ cntctr.c kb.c $(LIBS)

cntctr-test: cntctr.c kb.c kb.h
	$(CC) -std=c11 -g -O1 -Wall -Wextra -Werror -fsanitize=address,undefined $(FLAGS) -o $@ cntctr.c kb.c $(LIBS)
```

- [ ] **Step 6: Add the includes to `cntctr.c`**

Add `#include <ctype.h>` after `#include <errno.h>`, add `#include <sys/stat.h>` before `#include <sys/wait.h>`, and add `#include "kb.h"` after `#include <json-c/json.h>`.

- [ ] **Step 7: Add the knowledge helpers**

Insert this right before `/* ---- agents and delivery ---- */`:

```c
/* ---- knowledge ---- */

/* Open the knowledge store: $CNTCTR_DB, else ~/.local/share/cntctr/kb.db. On failure
 * *err says why (caller frees). */
static sqlite3 *kb(char **err) {
    const char *path = getenv("CNTCTR_DB"), *home = getenv("HOME");
    char def[4096];
    if (!path || !*path) {
        home = home ? home : ".";
        snprintf(def, sizeof def, "%s/.local", home);
        mkdir(def, 0755);
        snprintf(def, sizeof def, "%s/.local/share", home);
        mkdir(def, 0755);
        snprintf(def, sizeof def, "%s/.local/share/cntctr", home);
        mkdir(def, 0700);
        snprintf(def, sizeof def, "%s/.local/share/cntctr/kb.db", home);
        path = def;
    }
    char *why = NULL;
    sqlite3 *db = kb_open(path, &why);
    if (!db) *err = fmt("knowledge store unavailable: %s", why);
    free(why);
    return db;
}

struct project { char root[4096], key[1024], base[256]; };

/* git@github.com:X/y.git and https://github.com/X/y/ both become github.com/X/y. */
static void normalize_remote(const char *url, char *out, size_t n) {
    const char *s = strstr(url, "://");
    int scp = !s;
    s = s ? s + 3 : url;
    const char *at = strchr(s, '@'), *slash = strchr(s, '/');
    if (at && (!slash || at < slash)) s = at + 1;
    snprintf(out, n, "%s", s);
    char *colon = strchr(out, ':'), *sl = strchr(out, '/');
    if (scp && colon && (!sl || colon < sl)) *colon = '/';
    size_t len = strlen(out);
    while (len && out[len - 1] == '/') out[--len] = '\0';
    if (len > 4 && strcmp(out + len - 4, ".git") == 0) out[len -= 4] = '\0';
    while (len && out[len - 1] == '/') out[--len] = '\0';
    for (char *c = out; *c && *c != '/'; c++) *c = (char)tolower((unsigned char)*c);
}

/* Project of the agent in `pane` (empty: cntctr's own cwd): the override for its repo
 * root, else the normalized origin remote, else the root path. */
static void resolve_project(sqlite3 *db, const char *pane, struct project *p) {
    char *out = NULL, cwd[4096];
    if (pane && *pane && TMUX(NULL, &out, "display", "-p", "-t", pane, "#{pane_current_path}") == 0 && *out)
        snprintf(cwd, sizeof cwd, "%s", out);
    else if (!getcwd(cwd, sizeof cwd))
        snprintf(cwd, sizeof cwd, ".");
    free(out);
    if (run(NULL, &out, (const char *[]){"git", "-C", cwd, "rev-parse", "--show-toplevel", NULL}) == 0 && *out)
        snprintf(p->root, sizeof p->root, "%s", out);
    else
        snprintf(p->root, sizeof p->root, "%s", cwd);
    free(out);
    const char *slash = strrchr(p->root, '/');
    snprintf(p->base, sizeof p->base, "%s", slash && slash[1] ? slash + 1 : p->root);
    char *key = kb_project_get(db, p->root);
    if (key) {
        snprintf(p->key, sizeof p->key, "%s", key);
        free(key);
        return;
    }
    if (run(NULL, &out, (const char *[]){"git", "-C", p->root, "remote", "get-url", "origin", NULL}) == 0 && *out)
        normalize_remote(out, p->key, sizeof p->key);
    else
        snprintf(p->key, sizeof p->key, "%s", p->root);
    free(out);
}

/* First line of `text`, at most `max` bytes, never cutting a UTF-8 character. */
static char *first_line(const char *text, size_t max) {
    size_t n = strcspn(text, "\n");
    if (n > max)
        for (n = max; n > 0 && (text[n] & 0xC0) == 0x80; n--) {}
    return fmt("%.*s", (int)n, text);
}
```

- [ ] **Step 8: Add the tools**

Insert this right before `/* ---- dispatch ---- */`:

```c
/* ---- knowledge tools ---- */

/* Open the store and find the caller's project; on failure *res says why and NULL returns. */
static sqlite3 *kb_for_caller(struct project *p, char **res) {
    sqlite3 *db = kb(res);
    if (db) resolve_project(db, caller_pane, p);
    return db;
}

static int is_layer(const char *l) {
    return l && (strcmp(l, "insight") == 0 || strcmp(l, "skill") == 0 || strcmp(l, "doc") == 0);
}

static int tool_note(json_object *a, char **res) {
    const char *layer = sarg(a, "layer"), *title = sarg(a, "title"), *summary = sarg(a, "summary");
    const char *body = sarg(a, "body"), *scope = sarg(a, "scope");
    if (!is_layer(layer) || !title || !*title || !summary || !*summary)
        return fail(res, fmt("note needs layer (insight, skill or doc), title and summary"));
    json_object *sup = NULL;
    json_object_object_get_ex(a, "supersedes", &sup);
    size_t nsup = json_object_is_type(sup, json_type_array) ? json_object_array_length(sup) : 0;
    struct project p;
    sqlite3 *db = kb_for_caller(&p, res);
    if (!db) return 1;
    for (size_t i = 0; i < nsup; i++) {   /* check every id before writing anything */
        const char *old = json_object_get_string(json_object_array_get_idx(sup, i));
        char l[16];
        long long mem;
        int bad = !old || kb_lookup(db, old, l, &mem) != 0;
        if (bad || strcmp(l, "history") == 0) {
            sqlite3_close(db);
            return fail(res, bad ? fmt("entry %s not found", old ? old : "(none)") : fmt("history entries cannot be superseded"));
        }
    }
    int global = scope && strcmp(scope, "global") == 0;
    char *line = first_line(summary, 300), id[64];
    struct kb_entry e = {.layer = layer, .scope = global ? "global" : p.key, .title = title, .summary = line,
                         .body = body, .tags = sarg(a, "tags"), .refs = sarg(a, "refs"),
                         .author = getenv("USER"), .agent = caller_name, .visibility = "shared"};
    if (kb_put(db, &e, id) != 0) {
        char *err = fmt("note failed: %s", sqlite3_errmsg(db));
        free(line);
        sqlite3_close(db);
        return fail(res, err);
    }
    for (size_t i = 0; i < nsup; i++) kb_supersede(db, json_object_get_string(json_object_array_get_idx(sup, i)), id);
    free(line);
    sqlite3_close(db);
    return ok(res, fmt("noted %s", id));
}

static int tool_read(json_object *a, char **res) {
    const char *id = sarg(a, "id");
    if (!id) return fail(res, fmt("read needs 'id'"));
    sqlite3 *db = kb(res);
    if (!db) return 1;
    char *text = kb_show(db, id);
    sqlite3_close(db);
    return text ? ok(res, text) : fail(res, fmt("entry %s not found", id));
}

static int tool_project(json_object *a, char **res) {
    const char *key = sarg(a, "key");
    struct project p;
    sqlite3 *db = kb_for_caller(&p, res);
    if (!db) return 1;
    if (key) {
        kb_project_set(db, p.root, key);
        resolve_project(db, caller_pane, &p);
    }
    sqlite3_close(db);
    return ok(res, fmt("project %s (root %s)", p.key, p.root));
}
```

- [ ] **Step 9: Let any tool name its caller, then register the tools**

In `dispatch`, change

```c
        if (TOOL_FNS[i].needs_pane && from && *from) {
```

to

```c
        if (from && *from) {   /* knowledge tools use it to find the caller's project */
```

In `TOOL_FNS`, add these before `{NULL, NULL, 0},`:

```c
    {"note", tool_note, 0},
    {"read", tool_read, 0},
    {"project", tool_project, 0},
```

Right before `static const char TOOLS[] =`, add:

```c
#define KFROM "\"from\":{\"type\":\"string\",\"description\":\"Your agent name. Needed from Codex, whose cntctr runs outside your pane, to find your project\"}"
```

In `TOOLS`, replace the final `"]}";` with:

```c
    ",{\"name\":\"note\",\"description\":\"Store durable knowledge for all agents: insight (a 1-5 line fact or decision), "
    "skill (a reusable how-to) or doc (long text). Point at code as file:symbol instead of copying it. "
    "To replace or merge entries, pass their ids in supersedes.\","
    "\"inputSchema\":{\"type\":\"object\",\"properties\":{"
    "\"layer\":{\"type\":\"string\",\"enum\":[\"insight\",\"skill\",\"doc\"]},"
    "\"title\":{\"type\":\"string\"},"
    "\"summary\":{\"type\":\"string\",\"description\":\"One line; the index shows only this\"},"
    "\"body\":{\"type\":\"string\"},"
    "\"tags\":{\"type\":\"string\",\"description\":\"Extra search words, e.g. synonyms\"},"
    "\"refs\":{\"type\":\"string\",\"description\":\"Source entry or message ids, code pointers\"},"
    "\"scope\":{\"type\":\"string\",\"enum\":[\"project\",\"global\"],\"description\":\"global for knowledge not tied to this repo\"},"
    "\"supersedes\":{\"type\":\"array\",\"items\":{\"type\":\"string\"}}," KFROM "},"
    "\"required\":[\"layer\",\"title\",\"summary\"]}},"
    "{\"name\":\"read\",\"description\":\"Read one knowledge entry in full.\","
    "\"inputSchema\":{\"type\":\"object\",\"properties\":{\"id\":{\"type\":\"string\"}},\"required\":[\"id\"]}},"
    "{\"name\":\"project\",\"description\":\"Show the project key your knowledge is filed under, or set key to override it for this repo (empty key removes the override).\","
    "\"inputSchema\":{\"type\":\"object\",\"properties\":{\"key\":{\"type\":\"string\"}," KFROM "}}}"
    "]}";
```

- [ ] **Step 10: Run the tests and confirm they pass**

Run: `make test 2>&1 | tail -5`
Expected: `103 passed, 0 failed` (the previous 85 plus 18 new checks).

- [ ] **Step 11: Commit**

```bash
git add kb.h kb.c cntctr.c Makefile test.sh
git commit -m "feat: knowledge store with note, read and project tools"
```

---

### Task 2: `recall`, `forget` and supersedes

**Files:**
- Modify: `cntctr.c` (two tools after `tool_project`, plus `TOOL_FNS` and `TOOLS`), `test.sh` (the end of the knowledge section)

**Interfaces:**
- Consumes: `kb_index`, `kb_search`, `kb_lookup` and `kb_supersede` from Task 1, and `kb_for_caller` and `kb`.
- Produces: `tool_recall` and `tool_forget`. Task 5 extends both.

- [ ] **Step 1: Write the failing tests**

Append to the knowledge section of `test.sh`:

```bash
call "$KA" note '{"layer":"skill","title":"Run the tests","summary":"make test runs test.sh under ASan","scope":"global"}' >/dev/null
call "$KR" note '{"layer":"insight","title":"Other repo fact","summary":"only in the other repo"}' >/dev/null
idx=$(txt "$(call "$KA" recall '{}')")
check "index lists the project insight" "$idx" "$nid [insight] Enter in copy-mode — send-keys Enter goes to copy-mode; paste a CR instead"
check "index lists the global skill" "$idx" "[skill] Run the tests — make test runs test.sh under ASan"
same "project entries come before global ones" "$(printf '%s\n' "$idx" | head -n 1 | cut -d' ' -f1)" "$nid"
refute "index leaves out other projects" "$idx" "only in the other repo"
check "other projects see global entries" "$(txt "$(call "$KR" recall '{}')")" "Run the tests"
refute "scope=global leaves out the project" "$(txt "$(call "$KA" recall '{"scope":"global"}')")" "$nid"
check "search finds a body word" "$(txt "$(call "$KA" recall '{"query":"Seen"}')")" "$nid"
check "search finds a tag" "$(txt "$(call "$KA" recall '{"query":"scrollback"}')")" "$nid"
same "search with no hits" "$(txt "$(call "$KA" recall '{"query":"zebra"}')")" "no entries"
same "search text is never FTS syntax" "$(txt "$(call "$KA" recall '{"query":"\"AND ( NEAR"}')")" "no entries"
out=$(call "$KA" note "{\"layer\":\"insight\",\"title\":\"Enter fix\",\"summary\":\"inject pastes a raw CR so copy-mode cannot eat Enter\",\"supersedes\":[\"$nid\"]}")
nid2=$(txt "$out" | sed 's/noted //')
refute "superseded entry leaves the index" "$(txt "$(call "$KA" recall '{}')")" "$nid "
refute "superseded entry leaves search" "$(txt "$(call "$KA" recall '{"query":"scrollback"}')")" "$nid"
check "superseded entry is still readable" "$(txt "$(call "$KA" read "{\"id\":\"$nid\"}")")" "superseded_by: $nid2"
same "supersedes an unknown id" "$(txt "$(call "$KA" note '{"layer":"insight","title":"x","summary":"y","supersedes":["nope"]}')")" "entry nope not found"
fid=$(txt "$(call "$KA" note '{"layer":"doc","title":"Stale","summary":"soon gone"}')" | sed 's/noted //')
same "forget" "$(txt "$(call "$KA" forget "{\"id\":\"$fid\"}")")" "forgot $fid"
refute "forgotten entry leaves the index" "$(txt "$(call "$KA" recall '{}')")" "soon gone"
same "forget an unknown id" "$(txt "$(call "$KA" forget '{"id":"nope"}')")" "entry nope not found"
```

- [ ] **Step 2: Run the tests and confirm they fail**

Run: `make test 2>&1 | tail -30`
Expected: FAIL on `index lists the project insight`, with `got:` containing `unknown tool recall`.

- [ ] **Step 3: Write the tools**

Insert after `tool_project`:

```c
static int tool_recall(json_object *a, char **res) {
    const char *query = sarg(a, "query"), *layer = sarg(a, "layer"), *scope = sarg(a, "scope"), *since = sarg(a, "since");
    json_object *v;
    int limit = json_object_object_get_ex(a, "limit", &v) ? json_object_get_int(v) : 20;
    limit = limit < 1 ? 1 : limit > 200 ? 200 : limit;
    if (layer && !*layer) layer = NULL;
    struct project p;
    sqlite3 *db = kb_for_caller(&p, res);
    if (!db) return 1;
    const char *s1 = p.key, *s2 = "global";
    if (scope && strcmp(scope, "global") == 0) s1 = "global", s2 = NULL;
    else if (scope && strcmp(scope, "project") == 0) s2 = NULL;
    char *out = query && *query ? kb_search(db, s1, s2, query, layer, 1, limit) : kb_index(db, s1, s2, layer, since, limit);
    sqlite3_close(db);
    if (*out) return ok(res, out);
    free(out);
    return ok(res, fmt("no entries"));
}

static int tool_forget(json_object *a, char **res) {
    const char *id = sarg(a, "id");
    if (!id) return fail(res, fmt("forget needs 'id'"));
    sqlite3 *db = kb(res);
    if (!db) return 1;
    char layer[16];
    long long mem = 0;
    int found = kb_lookup(db, id, layer, &mem) == 0, history = found && strcmp(layer, "history") == 0;
    if (found && !history) kb_supersede(db, id, "forgotten");
    sqlite3_close(db);
    if (!found) return fail(res, fmt("entry %s not found", id));
    if (history) return fail(res, fmt("history entries cannot be forgotten"));
    return ok(res, fmt("forgot %s", id));
}
```

Add these to `TOOL_FNS`, after the `project` row:

```c
    {"recall", tool_recall, 0},
    {"forget", tool_forget, 0},
```

In `TOOLS`, replace the final `"]}";` with:

```c
    ",{\"name\":\"recall\",\"description\":\"Read the shared knowledge store before you explore. Without query: the index, "
    "one line per entry, this project first, then global. With query: search, including work history. Use read for an entry's full text.\","
    "\"inputSchema\":{\"type\":\"object\",\"properties\":{\"query\":{\"type\":\"string\"},"
    "\"layer\":{\"type\":\"string\",\"enum\":[\"insight\",\"skill\",\"doc\",\"history\"]},"
    "\"scope\":{\"type\":\"string\",\"enum\":[\"project\",\"global\"]},"
    "\"since\":{\"type\":\"string\",\"description\":\"UTC 'YYYY-MM-DD HH:MM:SS'; index only\"},"
    "\"limit\":{\"type\":\"integer\",\"description\":\"Default 20, at most 200\"}," KFROM "}}},"
    "{\"name\":\"forget\",\"description\":\"Retire a stale or wrong knowledge entry (history cannot be forgotten).\","
    "\"inputSchema\":{\"type\":\"object\",\"properties\":{\"id\":{\"type\":\"string\"}},\"required\":[\"id\"]}}"
    "]}";
```

- [ ] **Step 4: Run the tests and confirm they pass**

Run: `make test 2>&1 | tail -5`
Expected: `N passed, 0 failed`.

- [ ] **Step 5: Commit**

```bash
git add cntctr.c test.sh
git commit -m "feat: recall and forget knowledge entries; supersede on note"
```

---

### Task 3: Automatic history and reply insights

**Files:**
- Modify: `cntctr.c` (`log_history` and `pane_name` in the knowledge section, the `tool_send`, `tool_spawn` and `tool_reply` bodies, and the reply schema in `TOOLS`), `test.sh`

**Interfaces:**
- Consumes: `kb`, `resolve_project`, `first_line` and `kb_put`.
- Produces:
  - `static char *pane_name(const char *pane)`, which returns a malloc'd `@cntctr_name` or NULL.
  - `static void log_history(const char *pane, const char *title, const char *text)`.
  - `static void remember_reply(const char *id, const char *to, const char *sender, const char *text, json_object *a)`. Task 5 adds mirroring to it.

- [ ] **Step 1: Write the failing tests**

Append to the knowledge section of `test.sh`:

```bash
KB=$(newpane kb)
hid=$(txt "$(call "$KA" send '{"to":"kb","text":"measure the paste delay"}')" | sed 's/sent id=//')
call "$KB" reply "{\"id\":\"$hid\",\"text\":\"150 ms is enough\",\"insights\":[\"Claude submits pasted text with no delay before Enter\"]}" >/dev/null
hist=$(txt "$(call "$KA" recall '{"layer":"history"}')")
check "send is logged as history" "$hist" "[history] task $hid ka→kb — measure the paste delay"
check "reply is logged as history" "$hist" "[history] reply $hid kb→ka — 150 ms is enough"
refute "history stays out of the index" "$(txt "$(call "$KA" recall '{}')")" "[history]"
ins=$(txt "$(call "$KA" recall '{"query":"delay before Enter"}')")
check "reply insight is stored" "$ins" "[insight] Claude submits pasted text with no delay before Enter"
iid=$(printf '%s\n' "$ins" | grep '\[insight\] Claude submits' | cut -d' ' -f1)
check "insight refs its message" "$(txt "$(call "$KA" read "{\"id\":\"$iid\"}")")" "refs: $hid"
hent=$(printf '%s\n' "$hist" | grep "task $hid" | cut -d' ' -f1)
check "history is private" "$(txt "$(call "$KA" read "{\"id\":\"$hent\"}")")" "visibility: private"
same "history cannot be forgotten" "$(txt "$(call "$KA" forget "{\"id\":\"$hent\"}")")" "history entries cannot be forgotten"
same "history cannot be superseded" "$(txt "$(call "$KA" note "{\"layer\":\"insight\",\"title\":\"x\",\"summary\":\"y\",\"supersedes\":[\"$hent\"]}")")" "history entries cannot be superseded"
long="x$(printf 'é%.0s' $(seq 60))"   # 121 bytes: byte 80 is inside an é, so the 80-byte title cut must back off
hid=$(txt "$(call "$KA" send '{"to":"kb","text":"unicode"}')" | sed 's/sent id=//')
call "$KB" reply "{\"id\":\"$hid\",\"text\":\"ok\",\"insights\":[\"$long\"]}" >/dev/null
out=$(txt "$(call "$KA" recall '{}')")
check "long unicode insight is listed" "$out" "[insight] xéé"
refute "titles are cut on a character boundary" "$out" "�"
out=$(CNTCTR_DB=/nonexistent/x.db call "$KA" send '{"to":"kb","text":"still delivered"}')
check "send works without a knowledge store" "$(txt "$out")" "sent id="
same "note reports a missing store" "$(txt "$(CNTCTR_DB=/nonexistent/x.db call "$KA" note '{"layer":"insight","title":"x","summary":"y"}')" | cut -c1-30)" "knowledge store unavailable: u"
```

- [ ] **Step 2: Run the tests and confirm they fail**

Run: `make test 2>&1 | tail -30`
Expected: FAIL on `send is logged as history`, with `got: no entries`.

- [ ] **Step 3: Add `pane_name` and `log_history` to the knowledge section**

Add these after `first_line`:

```c
/* The agent name of `pane` (caller frees), or NULL. */
static char *pane_name(const char *pane) {
    char *name;
    if (!pane || !*pane) return NULL;
    if (TMUX(NULL, &name, "show", "-pqv", "-t", pane, "@cntctr_name") == 0 && *name) return name;
    free(name);
    return NULL;
}

/* Log a task or reply as private history in the project of the agent in `pane`. Never fails. */
static void log_history(const char *pane, const char *title, const char *text) {
    char *err = NULL, id[64];
    sqlite3 *db = kb(&err);
    free(err);
    if (!db) return;
    struct project p;
    resolve_project(db, pane, &p);
    char *summary = first_line(text, 200);
    struct kb_entry e = {.layer = "history", .scope = p.key, .title = title, .summary = summary, .body = text,
                         .author = getenv("USER"), .agent = caller_name, .visibility = "private"};
    kb_put(db, &e, id);
    free(summary);
    sqlite3_close(db);
}
```

- [ ] **Step 4: Log sends and spawns**

In `tool_send`, insert this directly after the `if (err) { ... return fail(res, err); }` block that follows `inject`:

```c
    char *title = fmt("task %s %s→%s", id, caller_name, to);
    log_history(caller_pane, title, text);
    free(title);
```

In `tool_spawn`, insert this directly after the two `free(TMUXE(NULL, "set", "-p", ...))` tagging lines:

```c
    char *title = fmt("task %s %s→%s", id, caller_name, name);
    log_history(caller_pane, title, task);
    free(title);
```

- [ ] **Step 5: Store replies and their insights**

Add this right before `static int tool_reply`:

```c
/* Store a reply as history in the sender's project, and its insights in the replier's.
 * ponytail: a reply retried after a failed delivery is stored again; the librarian merges duplicates. */
static void remember_reply(const char *id, const char *to, const char *sender, const char *text, json_object *a) {
    char *me = pane_name(to), *them = pane_name(sender), *title = fmt("reply %s %s→%s", id, me ? me : "?", them ? them : "?");
    log_history(sender, title, text);
    json_object *ins = NULL;
    char *err = NULL;
    sqlite3 *db = json_object_object_get_ex(a, "insights", &ins) && json_object_is_type(ins, json_type_array) ? kb(&err) : NULL;
    free(err);
    if (db) {
        struct project p;
        resolve_project(db, to ? to : caller_pane, &p);
        for (size_t i = 0; i < json_object_array_length(ins); i++) {
            const char *s = json_object_get_string(json_object_array_get_idx(ins, i));
            if (!s || !*s) continue;
            char *t = first_line(s, 80), *sum = first_line(s, 300), eid[64];
            struct kb_entry e = {.layer = "insight", .scope = p.key, .title = t, .summary = sum, .body = s, .refs = id,
                                 .author = getenv("USER"), .agent = me ? me : caller_name, .visibility = "shared"};
            kb_put(db, &e, eid);
            free(t);
            free(sum);
        }
        sqlite3_close(db);
    }
    free(me);
    free(them);
    free(title);
}
```

Replace the whole `tool_reply` with this version. It reads `@cntctr_to_<id>` once at the top, calls `remember_reply`, and reuses `to` for the replier's name:

```c
static int tool_reply(json_object *a, char **res) {
    const char *id = sarg(a, "id"), *text = sarg(a, "text");
    if (!id || !text) return fail(res, fmt("reply needs 'id' and 'text'"));
    char opt[48], buf[40], chan[32], *sender = NULL, *to, *waiting, *env, *err;
    snprintf(opt, sizeof opt, "@cntctr_from_%s", id);
    if (strlen(id) != 8 || strspn(id, "0123456789abcdef") != 8 || !(sender = sopt_get(opt)))
        return fail(res, fmt("unknown id %s", id));
    snprintf(opt, sizeof opt, "@cntctr_to_%s", id);
    to = sopt_get(opt);
    remember_reply(id, to, sender, text, a);

    /* Write the buffer before checking the wait flag; await_reply clears the flag
     * before claiming. That ordering means no reply is lost. */
    snprintf(buf, sizeof buf, "cntctr-reply-%s", id);
    if ((err = TMUXE(text, "load-buffer", "-b", buf, "-"))) {
        free(sender);
        free(to);
        return fail(res, err);
    }
    snprintf(opt, sizeof opt, "@cntctr_wait_%s", id);
    if ((waiting = sopt_get(opt))) {   /* sender is blocked in await_reply: wake it */
        free(waiting);
        free(sender);
        free(to);
        snprintf(chan, sizeof chan, "cntctr-%s", id);
        free(TMUXE(NULL, "wait-for", "-S", chan));
        return ok(res, fmt("ok"));
    }
    /* Nobody waiting: type the reply into the sender's pane, unless a timed-out
     * waiter claimed the buffer first. */
    if ((err = TMUXE(NULL, "delete-buffer", "-b", buf))) {
        free(err);
        free(sender);
        free(to);
        return ok(res, fmt("ok"));
    }
    if (!pane_alive(sender)) {
        free(sender);
        free(to);
        untrack(id);
        return fail(res, fmt("sender gone"));
    }
    char *me = pane_name(to);
    env = fmt("[cntctr reply from=%s id=%s]\n%s", me ? me : *self_name ? self_name : client_name, id, text);
    free(me);
    free(to);
    err = inject(sender, "sender", env);
    free(env);
    free(sender);
    if (err) return fail(res, err);   /* still tracked, so the replier can retry */
    untrack(id);
    return ok(res, fmt("ok"));
}
```

In `TOOLS`, add `insights` to the `reply` schema by replacing

```c
    "\"inputSchema\":{\"type\":\"object\",\"properties\":{\"id\":{\"type\":\"string\"},\"text\":{\"type\":\"string\"}},"
    "\"required\":[\"id\",\"text\"]}},"
```

with

```c
    "\"inputSchema\":{\"type\":\"object\",\"properties\":{\"id\":{\"type\":\"string\"},\"text\":{\"type\":\"string\"},"
    "\"insights\":{\"type\":\"array\",\"items\":{\"type\":\"string\"},\"description\":\"Durable facts other agents should know; each is stored in the shared knowledge store\"}},"
    "\"required\":[\"id\",\"text\"]}},"
```

- [ ] **Step 6: Run the tests and confirm they pass**

Run: `make test 2>&1 | tail -5`
Expected: `N passed, 0 failed`.

- [ ] **Step 7: Commit**

```bash
git add cntctr.c test.sh
git commit -m "feat: log tasks and replies as history; store reply insights"
```

---

### Task 4: Envelope hints and `initialize` instructions

**Files:**
- Modify: `cntctr.c` (`knowledge_hints` in the knowledge section, `envelope`, `GUIDE` and `instructions` before `initialize`, and `initialize`), `test.sh` (the existing `reply hint` check at line 113, plus new checks)

**Interfaces:**
- Consumes: `kb`, `resolve_project`, `kb_search` and `kb_index`.
- Produces: the envelope format `[cntctr from=…]\n<text>\n[cntctr knowledge: call recall for more]\n<lines>\n[when done: …]`, and the `instructions` field of the initialize result.

- [ ] **Step 1: Write the failing tests**

In `test.sh`, replace the `reply hint` check on line 113 with:

```bash
expect_screen "reply hint" "$B" "[when done: call the reply tool of the cntctr MCP server with id=$id and your answer, plus insights=[...] with durable facts other agents should know; it is an MCP tool, not a shell command. Your agent name is b: pass from=b when you call send, spawn or kill]"
```

Append to the knowledge section:

```bash
call "$KA" send '{"to":"kb","text":"why does Enter get lost in copy-mode?"}' >/dev/null
expect_screen "envelope points at recall" "$KB" "[cntctr knowledge: call recall for more]"
expect_screen "envelope lists matching knowledge" "$KB" "$nid2 [insight] Enter fix — inject pastes a raw CR so copy-mode cannot eat Enter"
words=$(printf 'word%d ' $(seq 3000))
out=$(call "$KA" send "{\"to\":\"kb\",\"text\":\"$words\"}")
check "a 3000-word task is still sent" "$(txt "$out")" "sent id="
ins=$(session "$KA" 1 "$INIT" | jq -r .result.instructions)
check "initialize explains the knowledge tools" "$ins" "call recall"
check "initialize carries the project index" "$ins" "Enter fix — inject pastes a raw CR so copy-mode cannot eat Enter"
ins=$(session "" 1 "$INIT" | jq -r .result.instructions)
check "paneless instructions ask for from" "$ins" "pass from="
check "paneless index shows global entries" "$ins" "Run the tests"
refute "paneless index leaves out project entries" "$ins" "Enter fix"
```

- [ ] **Step 2: Run the tests and confirm they fail**

Run: `make test 2>&1 | tail -30`
Expected: FAIL on `reply hint`, `envelope points at recall` and the `initialize` checks.

- [ ] **Step 3: Add the hints and change the envelope**

Add this after `log_history` in the knowledge section:

```c
/* Up to 5 stored entries matching `text`, as an envelope block; "" if none. */
static char *knowledge_hints(const char *text) {
    char *err = NULL;
    sqlite3 *db = kb(&err);
    free(err);
    if (!db) return strdup("");
    struct project p;
    resolve_project(db, caller_pane, &p);
    char *lines = kb_search(db, p.key, "global", text, NULL, 0, 5);
    sqlite3_close(db);
    if (!*lines) return lines;
    char *block = fmt("[cntctr knowledge: call recall for more]\n%s\n", lines);
    free(lines);
    return block;
}
```

Replace `envelope` with:

```c
static char *envelope(const char *id, const char *text, const char *you) {
    char *hints = knowledge_hints(text);
    char *env = fmt("[cntctr from=%s id=%s]\n%s\n%s[when done: call the reply tool of the cntctr MCP server with id=%s and your answer, "
                    "plus insights=[...] with durable facts other agents should know; it is an MCP tool, not a shell command. "
                    "Your agent name is %s: pass from=%s when you call send, spawn or kill]",
                    caller_name, id, text, hints, id, you, you);
    free(hints);
    return env;
}
```

- [ ] **Step 4: Add the instructions**

Insert this right before `static json_object *initialize`:

```c
static const char GUIDE[] =
    "cntctr keeps a knowledge store shared by all agents (Claude, Codex, agy) across sessions. "
    "Before exploring a codebase or problem, call recall: no query lists the index, a query searches; read shows an entry in full. "
    "When you learn something durable (a fact, decision, gotcha, procedure, or the summary of a long analysis), store it with note: "
    "layer insight (1-5 lines), skill (a how-to) or doc (long text); point at code as file:symbol instead of copying it. "
    "When you reply to a task, add insights=[...].";

/* Usage guide plus the knowledge index: our project's and global entries, or only
 * global ones for a server outside any pane (Codex), capped at 40 lines and 4 KB. */
static char *instructions(void) {
    char *err = NULL;
    sqlite3 *db = kb(&err);
    free(err);
    if (!db) return strdup(GUIDE);
    struct project p;
    resolve_project(db, self_pane, &p);
    char *index = *self_pane ? kb_index(db, p.key, "global", NULL, NULL, 40) : kb_index(db, "global", NULL, NULL, NULL, 40);
    sqlite3_close(db);
    if (strlen(index) > 4096) {
        index[4096] = '\0';
        char *nl = strrchr(index, '\n');
        if (nl) *nl = '\0';
    }
    char *r = fmt("%s%s\n\nKnowledge index (%s):\n%s", GUIDE,
                  *self_pane ? "" : " This cntctr runs outside your tmux pane: pass from=<your agent name> to the knowledge tools.",
                  *self_pane ? p.key : "global only", *index ? index : "(empty)");
    free(index);
    return r;
}
```

In `initialize`, add this after `json_object_object_add(r, "serverInfo", server);`:

```c
    char *guide = instructions();
    json_object_object_add(r, "instructions", json_object_new_string(guide));
    free(guide);
```

- [ ] **Step 5: Run the tests and confirm they pass**

Run: `make test 2>&1 | tail -5`
Expected: `N passed, 0 failed`.

- [ ] **Step 6: Commit**

```bash
git add cntctr.c test.sh
git commit -m "feat: show matching knowledge in envelopes and the index in MCP instructions"
```

---

### Task 5: claude-mem mirror

**Files:**
- Modify: `cntctr.c` (mirror functions in the knowledge section, plus `tool_note`, `tool_forget`, `tool_recall` and `remember_reply`), `test.sh`

**Interfaces:**
- Consumes: `run`, `fmt`, `kb_set_mem`, `kb_lookup` and `kb_by_mem`, and `struct project`'s `base`.
- Produces:
  - `static long long mem_save(const char *project, const char *id, const char *layer, const char *scope, const char *title, const char *summary, const char *body)`
  - `static void mem_delete(long long mem)`
  - `static char *mem_search(const char *query, const char *project, int limit)`
  - `static char *merge_mem(sqlite3 *db, char *out, const char *table)`

- [ ] **Step 1: Write the failing tests**

Append to the knowledge section of `test.sh`:

```bash
cat > "$TMPD/mem.py" <<'EOF'
# Fake claude-mem worker: logs every request, answers like claude-mem 13.15.
import http.server, json, sys
log = open(sys.argv[1], "a")
class H(http.server.BaseHTTPRequestHandler):
    def answer(self, body):
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps(body).encode())
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0))).decode()
        log.write("POST %s %s\n" % (self.path, body)); log.flush()
        self.answer({"success": True, "id": 7})
    def do_GET(self):
        log.write("GET %s\n" % self.path); log.flush()
        self.answer({"content": [{"type": "text", "text": "| ID | Time | T | Title | Read |\n|----|------|---|-------|------|\n"
                                  "| #7 | 1:00 PM | o | Mirror me | ~10 |\n| #9 | 1:00 PM | o | Claude saw this | ~10 |"}]})
    def do_DELETE(self):
        log.write("DELETE %s\n" % self.path); log.flush()
        self.answer({"success": True})
    def log_message(self, *a): pass
s = http.server.HTTPServer(("127.0.0.1", 0), H)
print(s.server_port, flush=True)
s.serve_forever()
EOF
python3 "$TMPD/mem.py" "$TMPD/mem.log" > "$TMPD/mem.port" &
MEMPID=$!
for _ in $(seq 50); do [ -s "$TMPD/mem.port" ] && break; sleep 0.1; done
MEM=http://127.0.0.1:$(cat "$TMPD/mem.port")
base=$(basename "$(git -C "$(t display -p -t "$KA" '#{pane_current_path}')" rev-parse --show-toplevel 2>/dev/null || t display -p -t "$KA" '#{pane_current_path}')")
mid=$(txt "$(CNTCTR_MEM_URL=$MEM call "$KA" note '{"layer":"doc","title":"Mirror me","summary":"mirrored doc","body":"long text"}')" | sed 's/noted //')
check "note posts to claude-mem" "$(cat "$TMPD/mem.log")" "POST /api/memory/save"
check "mirror files under the repo basename" "$(cat "$TMPD/mem.log")" "\"project\":\"$base\""
check "mirror carries the cntctr id" "$(cat "$TMPD/mem.log")" "\"cntctr_id\":\"$mid\""
out=$(txt "$(CNTCTR_MEM_URL=$MEM call "$KA" recall '{"query":"zzz"}')")
check "search asks for observations only" "$(cat "$TMPD/mem.log")" "GET /api/search/observations?query=zzz&project=$base"
check "claude-mem hit maps to the cntctr entry" "$out" "$mid [doc] Mirror me — mirrored doc"
check "other claude-mem hits are shown" "$out" "claude-mem #9 Claude saw this"
CNTCTR_MEM_URL=$MEM call "$KA" forget "{\"id\":\"$mid\"}" >/dev/null
check "forget deletes the claude-mem copy" "$(cat "$TMPD/mem.log")" "DELETE /api/observation/7"
kill "$MEMPID"
wait "$MEMPID" 2>/dev/null
check "note works with claude-mem down" "$(txt "$(CNTCTR_MEM_URL=$MEM call "$KA" note '{"layer":"insight","title":"t","summary":"s"}')")" "noted "
```

- [ ] **Step 2: Run the tests and confirm they fail**

Run: `make test 2>&1 | tail -30`
Expected: FAIL on `note posts to claude-mem`, with the log file empty.

- [ ] **Step 3: Add the mirror functions**

Add these after `knowledge_hints` in the knowledge section:

```c
/* claude-mem mirror: best effort; a failure never fails the caller. */
static const char *mem_url(void) {
    const char *u = getenv("CNTCTR_MEM_URL");
    return u ? u : "http://127.0.0.1:37701";
}

/* Save an entry as a claude-mem observation under `project` (a directory basename,
 * as claude-mem names projects). Returns the observation id, or 0. */
static long long mem_save(const char *project, const char *id, const char *layer, const char *scope,
                          const char *title, const char *summary, const char *body) {
    if (!*mem_url()) return 0;
    json_object *req = json_object_new_object(), *meta = json_object_new_object(), *resp, *v;
    char *text = fmt("%s\n\n%s", summary, body ? body : ""), *url = fmt("%s/api/memory/save", mem_url()), *out;
    json_object_object_add(meta, "cntctr_id", json_object_new_string(id));
    json_object_object_add(meta, "layer", json_object_new_string(layer));
    json_object_object_add(meta, "scope", json_object_new_string(scope));
    json_object_object_add(req, "title", json_object_new_string(title));
    json_object_object_add(req, "text", json_object_new_string(text));
    json_object_object_add(req, "project", json_object_new_string(project));
    json_object_object_add(req, "metadata", meta);
    long long mem = 0;
    if (run(json_object_to_json_string_ext(req, JSON_C_TO_STRING_PLAIN | JSON_C_TO_STRING_NOSLASHESCAPE), &out,
            (const char *[]){"curl", "-s", "-m", "2", "-X", "POST", "-H", "Content-Type: application/json",
                             "--data-binary", "@-", url, NULL}) == 0 && (resp = json_tokener_parse(out))) {
        if (json_object_object_get_ex(resp, "id", &v)) mem = json_object_get_int64(v);
        json_object_put(resp);
    }
    free(out);
    free(url);
    free(text);
    json_object_put(req);
    return mem;
}

static void mem_delete(long long mem) {
    if (!mem || !*mem_url()) return;
    char *url = fmt("%s/api/observation/%lld", mem_url(), mem), *out;
    run(NULL, &out, (const char *[]){"curl", "-s", "-m", "2", "-X", "DELETE", url, NULL});
    free(out);
    free(url);
}

/* claude-mem observation search: its markdown table text, or NULL. Observations only:
 * /api/search mixes in session and prompt ids. */
static char *mem_search(const char *query, const char *project, int limit) {
    if (!*mem_url()) return NULL;
    char *q = fmt("query=%s", query), *pr = fmt("project=%s", project), *lim = fmt("limit=%d", limit);
    char *url = fmt("%s/api/search/observations", mem_url()), *out, *text = NULL;
    json_object *resp, *content, *item, *t;
    if (run(NULL, &out, (const char *[]){"curl", "-s", "-m", "2", "-G", "--data-urlencode", q, "--data-urlencode", pr,
                                          "--data-urlencode", lim, url, NULL}) == 0 && (resp = json_tokener_parse(out))) {
        if (json_object_object_get_ex(resp, "content", &content) && json_object_is_type(content, json_type_array)
            && (item = json_object_array_get_idx(content, 0)) && json_object_object_get_ex(item, "text", &t))
            text = strdup(json_object_get_string(t));
        json_object_put(resp);
    }
    free(out);
    free(url);
    free(lim);
    free(pr);
    free(q);
    return text;
}

/* Append claude-mem hits (rows "| #<id> | time | type | title | ..." of `table`) to `out`:
 * as the cntctr entry mirrored there, else as "claude-mem #<id> <title>". Frees `out`. */
static char *merge_mem(sqlite3 *db, char *out, const char *table) {
    if (!table) return out;
    char *copy = strdup(table), *save;
    for (char *row = strtok_r(copy, "\n", &save); row; row = strtok_r(NULL, "\n", &save)) {
        long long mem;
        if (sscanf(row, "| #%lld |", &mem) != 1) continue;
        char *line = kb_by_mem(db, mem), *add = NULL, idsp[72];
        if (line) {
            snprintf(idsp, sizeof idsp, "%.*s ", (int)strcspn(line, " "), line);
            if (!strstr(out, idsp)) add = line, line = NULL;
        } else {
            char *t = row, *end;
            for (int i = 0; i < 3 && t; i++) t = strchr(t + 1, '|');
            if (t && (end = strchr(t + 1, '|'))) {
                for (t++; *t == ' '; t++) {}
                while (end > t && end[-1] == ' ') end--;
                add = fmt("claude-mem #%lld %.*s", mem, (int)(end - t), t);
            }
        }
        if (add) {
            char *n = fmt(*out ? "%s\n%s" : "%s%s", out, add);
            free(out);
            out = n;
            free(add);
        }
        free(line);
    }
    free(copy);
    return out;
}
```

- [ ] **Step 4: Mirror writes, deletes and searches**

In `tool_note`, replace

```c
    for (size_t i = 0; i < nsup; i++) kb_supersede(db, json_object_get_string(json_object_array_get_idx(sup, i)), id);
    free(line);
```

with

```c
    for (size_t i = 0; i < nsup; i++) {
        const char *old = json_object_get_string(json_object_array_get_idx(sup, i));
        char l[16];
        long long mem = 0;
        kb_lookup(db, old, l, &mem);
        mem_delete(mem);
        kb_supersede(db, old, id);
    }
    long long mem = mem_save(global ? "cntctr-global" : p.base, id, layer, e.scope, title, line, body);
    if (mem) kb_set_mem(db, id, mem);
    free(line);
```

In `tool_forget`, replace

```c
    if (found && !history) kb_supersede(db, id, "forgotten");
```

with

```c
    if (found && !history) {
        mem_delete(mem);
        kb_supersede(db, id, "forgotten");
    }
```

In `tool_recall`, replace

```c
    char *out = query && *query ? kb_search(db, s1, s2, query, layer, 1, limit) : kb_index(db, s1, s2, layer, since, limit);
```

with

```c
    char *out;
    if (query && *query) {
        char *table = mem_search(query, strcmp(s1, "global") == 0 ? "cntctr-global" : p.base, limit);
        out = merge_mem(db, kb_search(db, s1, s2, query, layer, 1, limit), table);
        free(table);
    } else {
        out = kb_index(db, s1, s2, layer, since, limit);
    }
```

In `remember_reply`, replace

```c
            kb_put(db, &e, eid);
```

with

```c
            if (kb_put(db, &e, eid) == 0) {
                long long mem = mem_save(p.base, eid, "insight", p.key, t, sum, s);
                if (mem) kb_set_mem(db, eid, mem);
            }
```

- [ ] **Step 5: Run the tests and confirm they pass**

Run: `make test 2>&1 | tail -5`
Expected: `N passed, 0 failed`.

- [ ] **Step 6: Commit**

```bash
git add cntctr.c test.sh
git commit -m "feat: mirror knowledge to claude-mem and merge its semantic hits into recall"
```

---

### Task 6: The `distill` librarian, a concurrency check, tools/list, and the README

**Files:**
- Modify: `cntctr.c` (`LIBRARIAN` and `tool_distill` after `tool_forget`, plus `TOOL_FNS` and `TOOLS`), `test.sh` (the tools/list loop at line 73, plus new checks), `README.md`

**Interfaces:**
- Consumes: `kb_for_caller`, `kb_meta_get`, `kb_meta_set`, `find_agent` and `tool_spawn`.
- Produces: `tool_distill`.

- [ ] **Step 1: Write the failing tests**

In `test.sh`, change line 73 to:

```bash
for tool in spawn send reply list kill note recall read forget project distill; do check "tools/list has $tool" "$out" "\"name\":\"$tool\""; done
```

Append to the knowledge section:

```bash
out=$(call "$KA" distill '{}')
check "distill spawns a librarian" "$(txt "$out")" "spawned librarian-1 in %"
LB=$(txt "$out" | sed 's/.* in \(%[0-9]*\) .*/\1/')
expect_screen "librarian gets its task" "$LB" "You are the cntctr librarian for project"
expect_screen "first librarian reads all history" "$LB" 'since="1970-01-01 00:00:00"'
out=$(call "$KA" distill '{}')
check "next librarian gets a new name" "$(txt "$out")" "spawned librarian-2 in %"
LB2=$(txt "$out" | sed 's/.* in \(%[0-9]*\) .*/\1/')
expect_screen "next librarian starts at the last distill" "$LB2" 'since="20'
for i in $(seq 20); do
    call "$KA" note "{\"layer\":\"insight\",\"title\":\"par $i\",\"summary\":\"parallel note $i\"}" > "$TMPD/par.$i" &
done
wait
same "20 parallel notes all succeed" "$(cat "$TMPD"/par.* | jq -r '.result.content[0].text' | grep -c '^noted ')" 20
```

- [ ] **Step 2: Run the tests and confirm they fail**

Run: `make test 2>&1 | tail -30`
Expected: FAIL on `tools/list has note` (and the other new tools until all are listed) and on `distill spawns a librarian`.

- [ ] **Step 3: Write the tool**

Insert after `tool_forget`:

```c
static const char LIBRARIAN[] =
    "You are the cntctr librarian for project %s. Use the tools of the cntctr MCP server.\n"
    "1. Call recall with layer=history, since=\"%s\" and limit=200 to read new work history, and recall with no query to read the index.\n"
    "2. For each durable fact or procedure in that history, write an insight or skill with note, with refs set to the source ids.\n"
    "3. Merge duplicate or contradicting entries: write one entry with note supersedes=[their ids]. "
    "Entries that are not specific to this project go in scope=global.\n"
    "4. Call forget on entries whose code pointers (file:symbol) no longer exist; check them with Serena if you have it.\n"
    "5. Reply with a short summary of what you changed.";

static int tool_distill(json_object *a, char **res) {
    struct project p;
    sqlite3 *db = kb_for_caller(&p, res);
    if (!db) return 1;
    char *mk = fmt("last_distill:%s", p.key), *since = kb_meta_get(db, mk), stamp[32], name[32], *pane;
    time_t now = time(NULL);
    strftime(stamp, sizeof stamp, "%Y-%m-%d %H:%M:%S", gmtime(&now));
    char *task = fmt(LIBRARIAN, p.key, since ? since : "1970-01-01 00:00:00");
    kb_meta_set(db, mk, stamp);
    sqlite3_close(db);
    free(since);
    free(mk);
    for (int n = 1;; n++) {
        snprintf(name, sizeof name, "librarian-%d", n);
        if (!(pane = find_agent(name))) break;
        free(pane);
    }
    const char *harness = sarg(a, "harness");
    json_object *args = json_object_new_object(), *v;
    json_object_object_add(args, "harness", json_object_new_string(harness ? harness : "claude"));
    json_object_object_add(args, "name", json_object_new_string(name));
    json_object_object_add(args, "task", json_object_new_string(task));
    json_object_object_add(args, "wait", json_object_new_boolean(barg(a, "wait")));
    if (json_object_object_get_ex(a, "timeout", &v)) json_object_object_add(args, "timeout", json_object_get(v));
    int r = tool_spawn(args, res);
    json_object_put(args);
    free(task);
    return r;
}
```

Add this to `TOOL_FNS`, after the `forget` row:

```c
    {"distill", tool_distill, 1},
```

In `TOOLS`, replace the final `"]}";` with:

```c
    ",{\"name\":\"distill\",\"description\":\"Spawn a librarian agent that turns recent work history into insights and skills "
    "and merges duplicates in the knowledge store. Returns like spawn.\","
    "\"inputSchema\":{\"type\":\"object\",\"properties\":{"
    "\"harness\":{\"type\":\"string\",\"enum\":[\"claude\",\"codex\",\"agy\"],\"description\":\"Default claude\"},"
    "\"wait\":{\"type\":\"boolean\"},\"timeout\":{\"type\":\"integer\"},"
    "\"from\":{\"type\":\"string\",\"description\":\"Who you are, if this fails with a pane error (Codex): your agent name, or $TMUX_PANE\"}}}}"
    "]}";
```

- [ ] **Step 4: Document it in the README**

Add this section to `README.md`, after the usage table:

```markdown
## Knowledge

cntctr keeps a knowledge store that every agent shares across sessions. It lives in
SQLite at `~/.local/share/cntctr/kb.db`, or at `$CNTCTR_DB` if that is set.

| Tool | What it does |
|---|---|
| `note` | Store an `insight` (1–5 lines), a `skill` (a how-to) or a `doc` (long text), for this project or `scope=global`. `supersedes=[ids]` replaces older entries. |
| `recall` | With no query, list the index: this project's entries first, then global ones. With a query, search, including work history and claude-mem observations. |
| `read` | Show one entry in full. |
| `forget` | Retire a stale entry. History entries can't be forgotten. |
| `project` | Show the project key, which is the normalized `origin` remote, or override it for this repo. |
| `distill` | Spawn a librarian worker that turns recent history into insights and skills and merges duplicates. |

Every `send`, `spawn` and `reply` is logged as private history. Replies can add
`insights=[...]`. Every message includes up to 5 matching entries, and every agent gets
its project's index at startup through MCP `instructions`.

Insights, skills and docs are also copied to claude-mem (`$CNTCTR_MEM_URL`, default
`http://127.0.0.1:37701`; set it empty to turn copying off), so `recall` gets semantic
matches. If claude-mem is down, recall uses keyword search alone.
```

- [ ] **Step 5: Run the tests and confirm they pass**

Run: `make test 2>&1 | tail -5`
Expected: `N passed, 0 failed`.

- [ ] **Step 6: Commit**

```bash
git add cntctr.c test.sh README.md
git commit -m "feat: distill spawns a librarian over the knowledge store; document knowledge tools"
```
