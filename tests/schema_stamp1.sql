-- a database stamped user_version 1: SCHEMA and the 13 MIGRATIONS columns of kb.c. A table added to SCHEMA needs KB_SCHEMA_VERSION raised (see kb.c); f8_4 opens this file and compares it with a new database.
CREATE TABLE entries( id TEXT PRIMARY KEY, layer TEXT NOT NULL, scope TEXT NOT NULL, title TEXT NOT NULL, summary TEXT NOT NULL, body TEXT NOT NULL DEFAULT '', tags TEXT NOT NULL DEFAULT '', refs TEXT NOT NULL DEFAULT '', author TEXT, machine TEXT, agent TEXT, visibility TEXT NOT NULL, created INTEGER, updated INTEGER, superseded_by TEXT, mem_id INTEGER);
CREATE INDEX entries_scope ON entries(scope, layer, updated);
CREATE INDEX entries_mem ON entries(mem_id);
CREATE VIRTUAL TABLE entries_fts USING fts5(title, summary, body, tags, content='entries', content_rowid='rowid')
;
CREATE TRIGGER entries_ai AFTER INSERT ON entries BEGIN INSERT INTO entries_fts(rowid, title, summary, body, tags) VALUES (new.rowid, new.title, new.summary, new.body, new.tags); END;
CREATE TRIGGER entries_ad AFTER DELETE ON entries BEGIN INSERT INTO entries_fts(entries_fts, rowid, title, summary, body, tags) VALUES ('delete', old.rowid, old.title, old.summary, old.body, old.tags); END;
CREATE TRIGGER entries_au AFTER UPDATE OF title, summary, body, tags ON entries BEGIN INSERT INTO entries_fts(entries_fts, rowid, title, summary, body, tags) VALUES ('delete', old.rowid, old.title, old.summary, old.body, old.tags); INSERT INTO entries_fts(rowid, title, summary, body, tags) VALUES (new.rowid, new.title, new.summary, new.body, new.tags); END;
CREATE TABLE projects(root TEXT PRIMARY KEY, key TEXT NOT NULL);
CREATE TABLE meta(k TEXT PRIMARY KEY, v TEXT);
CREATE TABLE mail(post INTEGER PRIMARY KEY, name TEXT NOT NULL, pane TEXT NOT NULL, delivered INTEGER NOT NULL DEFAULT 0, state TEXT NOT NULL DEFAULT 'pending', staged_turn TEXT, presentations INTEGER NOT NULL DEFAULT 0, task TEXT NOT NULL DEFAULT '', hooked INTEGER NOT NULL DEFAULT 0, from_pane TEXT NOT NULL DEFAULT '', from_scope TEXT NOT NULL DEFAULT '', socket TEXT NOT NULL DEFAULT '');
CREATE TABLE posts(scope TEXT NOT NULL, sender TEXT NOT NULL, text TEXT NOT NULL, at INTEGER NOT NULL);
CREATE INDEX posts_scope ON posts(scope);
CREATE TABLE hook_sessions( socket TEXT NOT NULL, pane TEXT NOT NULL, harness TEXT NOT NULL, session_id TEXT NOT NULL, harness_pid INTEGER NOT NULL, last_event TEXT NOT NULL, at INTEGER NOT NULL, prompt_seen INTEGER NOT NULL DEFAULT 0, stop_seen INTEGER NOT NULL DEFAULT 0, wake_reserved INTEGER NOT NULL DEFAULT 0, wake_at INTEGER, stop_blocked INTEGER NOT NULL DEFAULT 0, turn INTEGER NOT NULL DEFAULT 0, broken INTEGER NOT NULL DEFAULT 0, server_start INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(socket,pane));
CREATE TABLE task_gate(task TEXT PRIMARY KEY, reminded INTEGER NOT NULL DEFAULT 0, away INTEGER NOT NULL DEFAULT 0, answered INTEGER NOT NULL DEFAULT 0);
CREATE TABLE tools(project TEXT NOT NULL, name TEXT NOT NULL, version INTEGER NOT NULL, status TEXT NOT NULL, author TEXT NOT NULL, author_model TEXT NOT NULL DEFAULT '', description TEXT NOT NULL, input_schema TEXT NOT NULL, interpreter TEXT NOT NULL, script TEXT NOT NULL, net INTEGER NOT NULL DEFAULT 0, timeout INTEGER NOT NULL DEFAULT 60, source TEXT NOT NULL DEFAULT '', reviewer TEXT, reviewer_pane TEXT, reviewer_model TEXT, review_root TEXT, deadline INTEGER, verdict_reason TEXT, calls INTEGER NOT NULL DEFAULT 0, failures INTEGER NOT NULL DEFAULT 0, created INTEGER, PRIMARY KEY(project, name, version, author));
CREATE UNIQUE INDEX tools_version ON tools(project, name, version) WHERE version > 0;
CREATE INDEX tools_name ON tools(project, name, status);
INSERT INTO meta VALUES ('schema', '1');
PRAGMA user_version=1;
