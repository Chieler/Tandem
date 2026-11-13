CREATE TABLE IF NOT EXISTS entries(
 id TEXT PRIMARY KEY, layer TEXT NOT NULL, scope TEXT NOT NULL, title TEXT NOT NULL,
 summary TEXT NOT NULL, body TEXT NOT NULL DEFAULT '', tags TEXT NOT NULL DEFAULT '',
 refs TEXT NOT NULL DEFAULT '', author TEXT, machine TEXT, agent TEXT, visibility TEXT NOT NULL,
 created INTEGER, updated INTEGER, superseded_by TEXT, mem_id INTEGER);
CREATE INDEX IF NOT EXISTS entries_scope ON entries(scope, layer, updated);
CREATE INDEX IF NOT EXISTS entries_mem ON entries(mem_id);
CREATE VIRTUAL TABLE IF NOT EXISTS entries_fts USING fts5(title, summary, body, tags,
 content='entries', content_rowid='rowid');
CREATE TRIGGER IF NOT EXISTS entries_ai AFTER INSERT ON entries BEGIN
 INSERT INTO entries_fts(rowid, title, summary, body, tags) VALUES (new.rowid, new.title, new.summary, new.body, new.tags); END;
CREATE TRIGGER IF NOT EXISTS entries_ad AFTER DELETE ON entries BEGIN
 INSERT INTO entries_fts(entries_fts, rowid, title, summary, body, tags)
 VALUES ('delete', old.rowid, old.title, old.summary, old.body, old.tags); END;
CREATE TRIGGER IF NOT EXISTS entries_au AFTER UPDATE OF title, summary, body, tags ON entries BEGIN
 INSERT INTO entries_fts(entries_fts, rowid, title, summary, body, tags)
 VALUES ('delete', old.rowid, old.title, old.summary, old.body, old.tags);
 INSERT INTO entries_fts(rowid, title, summary, body, tags) VALUES (new.rowid, new.title, new.summary, new.body, new.tags); END;
CREATE TABLE IF NOT EXISTS projects(root TEXT PRIMARY KEY, key TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS meta(k TEXT PRIMARY KEY, v TEXT);
CREATE TABLE IF NOT EXISTS posts(scope TEXT NOT NULL, sender TEXT NOT NULL, text TEXT NOT NULL, at INTEGER NOT NULL);
INSERT OR IGNORE INTO meta VALUES ('schema', '1');
