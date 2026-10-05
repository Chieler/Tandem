# cntctr knowledge store — Design Spec

Date: 2026-10-05
Status: Design agreed in conversation; pending written-spec review.

## Context

Agents spawned through cntctr start cold. Each one re-reads the same files and re-discovers the same facts, and whatever a worker learns is lost once its reply has been read. This spec adds a persistent knowledge store that every cntctr agent (Claude, Codex, agy) can read from and write to, so knowledge builds up across agents, sessions and projects.

This is sub-project 1 of 2. Sub-project 2, a cross-machine signal layer covering your own machines over SSH and other people's machines, comes later. This spec only adds the fields that sync will need, and builds no networking.

## Decisions

| Topic | Decision |
|---|---|
| What persists | Project knowledge and work history. |
| Layers | `insight` (a distilled fact, 1–5 lines), `skill` (a reusable procedure), `doc` (long text), `history` (raw tasks and replies, logged automatically). Every entry has a one-line `summary`, and the index shows only that. |
| Distillation | Both paths. Workers attach `insights` when they reply, and a `distill` librarian pass merges, dedupes and promotes entries. |
| Source of truth | SQLite with FTS5, owned by cntctr, at `~/.local/share/cntctr/kb.db`. WAL mode with `busy_timeout`, because many cntctr processes write to it. System `libsqlite3`, so no new dependency. |
| Semantic search | claude-mem (worker at `127.0.0.1:37701`) acts as an optional index. Non-history entries are mirrored to it, and recall merges its hits with FTS5. If claude-mem is down, cntctr falls back to FTS5 alone and nothing fails. |
| Serena | Not a store. Entries point at code (`cntctr.c:inject`) instead of copying it, and agents read the code through Serena. Serena memories are neither imported nor written. |
| Headroom | No integration. It compresses large recalls inside each agent on its own. |
| Project key | The normalized git remote `origin` (`github.com/x/y`), falling back to the repo root path, then to the cwd. A `project` tool can override the key per repo root, and the override is stored in the database. |
| Scopes | A project key, or `global`. Recall shows project entries first, then global ones. |
| Network readiness | Ids are unique across machines. Every entry records author, machine and visibility. History is append-only, and replaced entries are superseded rather than deleted. |

## Architecture

```
 agent ──MCP──► cntctr.c ──► kb.c ──► ~/.local/share/cntctr/kb.db (SQLite + FTS5)
                   │
                   ├──► git (project key)            via run(): fork/execvp, argv only
                   └──► curl ──► claude-mem :37701   via run(): best effort, 2 s timeout
```

- **`kb.c` / `kb.h`** is the store. It owns the schema and SQL and knows nothing about tmux, MCP or processes. Each tool call opens its own connection (`kb_open`) and closes it at the end. That's cheap, and connections are never shared between threads.
- **`cntctr.c`** adds project resolution, the claude-mem mirror, the tools, and auto-logging. It reuses `run()`, so it runs `git` and `curl` as separate processes and needs neither libgit nor libcurl.
- **The schema** (`kb_open` creates it if it doesn't exist; the version is stored in `meta`):

```sql
CREATE TABLE entries(
  id TEXT PRIMARY KEY,          -- <machine>-<ms since epoch, hex>-<4 random hex>
  layer TEXT NOT NULL,          -- insight | skill | doc | history
  scope TEXT NOT NULL,          -- project key or 'global'
  title TEXT NOT NULL,
  summary TEXT NOT NULL,        -- one line
  body TEXT NOT NULL DEFAULT '',
  tags TEXT NOT NULL DEFAULT '',
  refs TEXT NOT NULL DEFAULT '',-- free text: source entry/message ids, code pointers
  author TEXT, machine TEXT, agent TEXT,
  visibility TEXT NOT NULL,     -- 'private' for history, 'shared' otherwise
  created INTEGER, updated INTEGER,
  superseded_by TEXT,           -- id of the replacing entry, or 'forgotten'
  mem_id INTEGER                -- claude-mem observation id once mirrored
);
CREATE VIRTUAL TABLE entries_fts USING fts5(title, summary, body, tags, content='entries', content_rowid='rowid');
-- plus the standard insert, update and delete triggers that keep entries_fts in sync
CREATE TABLE projects(root TEXT PRIMARY KEY, key TEXT NOT NULL);
CREATE TABLE meta(k TEXT PRIMARY KEY, v TEXT);   -- schema, machine, last_distill:<scope>
```

`machine` is a random 8-hex-character id, generated on first open and stored in `meta`, followed by `-` and the short hostname. `author` is `$USER`.

## Project resolution

1. Find the caller's cwd: `tmux display -p -t <caller_pane> '#{pane_current_path}'`. A caller without a pane, such as Codex's shared daemon, uses the pane of its `from=`. Failing both, it uses cntctr's own cwd.
2. `git -C <cwd> rev-parse --show-toplevel` gives the root. If that fails, root = cwd.
3. If `projects` has an entry for that root, use its key.
4. Otherwise, take `git -C <root> remote get-url origin` and normalize it:
   - Strip the scheme and `user@`.
   - Turn the `:` after the host into `/`.
   - Strip a trailing `.git` and `/`.
   - Lowercase the host.

   So `git@github.com:X/y.git` and `https://github.com/X/y` both become `github.com/X/y`.
5. With no remote, the key is the root path.

## Tools

The new tools are `note`, `recall`, `read`, `forget`, `project` and `distill`, and `reply` gets one new argument. Every new tool takes an optional `from`, the same as `send`, so it works from Codex.

| Tool | Args | Behavior |
|---|---|---|
| `note` | `layer` (insight, skill or doc), `title`, `summary`, `body`?, `tags`?, `refs`?, `scope` (`project` by default, or `global`), `supersedes`? (array of ids) | Inserts an entry and mirrors it to claude-mem. Each id in `supersedes` gets `superseded_by` set to the new id, and its claude-mem copy is deleted. Returns the new id. |
| `recall` | `query`?, `layer`?, `scope`?, `limit` (default 20) | Without `query`, it returns the **index**: live entries for the project, then global ones, insights and skills first, newest first, one line each as `id [layer] title — summary`. With `query`, it runs FTS5 bm25 over live entries (history included), merged with claude-mem search hits. A hit that maps to a cntctr entry through `mem_id` is shown as that entry. Any other hit is shown as `claude-mem #<n> <title>`, which brings Claude's own observations into recall. |
| `read` | `id` | The full entry: every field, including `body` and `refs`. A superseded entry is still readable and shows `superseded_by`. |
| `forget` | `id` | Sets `superseded_by = 'forgotten'` and deletes the claude-mem copy. History can't be forgotten. |
| `project` | `key`? | With no args, shows the resolved key and the root. With `key`, sets the override for this root, and an empty key removes it. Existing entries keep their old scope, since retagging is the librarian's job. |
| `distill` | `harness` (default `claude`), `wait`? | Spawns a worker named `librarian-<n>` with a fixed task, described below, and then behaves like `spawn`. |
| `reply` (extended) | `insights`? (array of strings) | Each string becomes an `insight` entry in the replier's project scope. It uses the first 80 characters as its title, the first line as its summary, and the full text as its body, with `refs` set to the message id. |

### Automatic history

Logging writes history in the **sender's** project scope, without mirroring it, as `private`, and never fails the tool call:

- On every `send` and `spawn`, cntctr logs the task text (title `task <id> <from>→<to>`).
- On every `reply`, it logs the reply text (title `reply <id> <from>→<to>`).

### What agents see automatically

- **`initialize` instructions.** The `instructions` field of the result carries two short paragraphs explaining when to `recall`, `note` and attach `insights`. It also carries the project index, capped at 40 lines or 4 KB. A server with no pane, such as Codex's, carries only the global index and tells the agent to call `recall` with `from`.
- **Envelope.** Every `send` and `spawn` envelope gets a block before the reply hint. It lists up to 5 live entries from an FTS5 search on the task text, as `id: summary`, followed by `[knowledge: call recall for more; when you reply, pass insights=[...] with durable facts others should know]`. The block is left out when there are no matches.

### Librarian task (`distill`)

The task is fixed text, filled in with the scope and the last distill time:

> You are the cntctr librarian for `<scope>`.
> 1. Call recall with layer=history to read the history since `<time>`, and call recall to read the index.
> 2. Write new insights and skills for the durable facts and procedures you find, using note with refs to the source ids.
> 3. Merge duplicate or contradicting entries into one with note supersedes=[...]. Promote entries that aren't project-specific to scope=global.
> 4. Call forget on entries whose code pointers no longer resolve (check them with Serena if you have it).
> 5. Reply with a summary of your changes.

`meta.last_distill:<scope>` is set when the librarian is spawned.

## claude-mem mirror

- The base URL comes from `CNTCTR_MEM_URL`, defaulting to `http://127.0.0.1:37701`. An empty value turns mirroring off.
- **Save** runs `curl -s -m 2 -X POST -H 'Content-Type: application/json' --data-binary @- <url>/api/memory/save`, with the body `{"title","text": summary + "\n\n" + body,"project": scope,"metadata":{"cntctr_id","layer"}}`. The returned `id` is stored in `mem_id`.
- **Delete** runs `curl -s -m 2 -X DELETE <url>/api/observation/<mem_id>`.
- **Search** runs `curl -s -m 2 '<url>/api/search?query=<q>&project=<scope>&limit=<n>'`. The response text is a markdown table, and the observation ids are the `#<n>` tokens in it.
- Any failure, whether a timeout, a non-JSON reply or a missing id, is ignored. The entry stays unmirrored (`mem_id` NULL).
- **Known limit:** there's no retry queue, so entries written while claude-mem is down never get mirrored. The librarian pass can re-mirror rows with a NULL `mem_id` later, if that matters.

## Error handling

| Case | Result |
|---|---|
| The database can't be opened or created | The knowledge tools return `knowledge store unavailable: <sqlite error>`, and messaging tools keep working with logging skipped. |
| `note` is missing `layer`, `title` or `summary`, or has a bad layer | `note needs layer (insight, skill or doc), title and summary` |
| Unknown id in `read`, `forget` or `supersedes` | `entry <id> not found` (`note` fails before inserting anything) |
| `forget` on history | `history entries cannot be forgotten` |
| `SQLITE_BUSY` after `busy_timeout` (5 s) | Returned as a tool error |
| claude-mem down or slow | Ignored. Recall uses FTS5 only. |

## Testing

`test.sh` gets a **knowledge** section. Every test sets `CNTCTR_DB=$TMPD/kb.db` and `CNTCTR_MEM_URL=` (mirroring off), except the mirror tests.

1. `note`, then `read`, round-trips every field, and the id has the form `<machine>-<hex>-<hex>`.
2. `recall` with no query lists project entries before global ones, one line each. Entries from another project are excluded.
3. `recall` with a query finds an entry by a body word. Superseded and forgotten entries don't appear in the results.
4. `note supersedes=[a]` hides `a` from recall, and `read a` shows `superseded_by`.
5. `forget` on a history entry fails.
6. `send` and `reply` create two history entries in the sender's scope. `reply insights=[...]` creates insight entries with `refs` set to the message id.
7. The envelope of a `send` whose text matches an existing insight contains that insight's summary and the knowledge hint.
8. `initialize` returns `instructions` containing the project index.
9. Project key: in a temporary git repo whose origin is `git@github.com:X/y.git`, `project` reports `github.com/X/y`, and after `project key=foo` it reports `foo`.
10. Concurrency: 20 parallel `note` calls from separate processes all succeed.
11. Mirror: a Python `http.server` stub on a random port records requests and answers `/api/memory/save` with `{"id":7}` and `/api/search` with `#7`.
    - `note` posts the entry and stores `mem_id` 7, `recall query` returns the entry through `#7`, and `forget` sends `DELETE /api/observation/7`.
    - With the stub stopped, `note` still succeeds.

## Files

| File | Change |
|---|---|
| `kb.c`, `kb.h` | New: the schema, `kb_open`, `kb_put`, `kb_get`, `kb_index`, `kb_search`, `kb_supersede`, `kb_set_mem`, `kb_project_get` / `kb_project_set` and `kb_meta`. |
| `cntctr.c` | Project resolution, the mirror, 6 new tools, the `reply` insights, auto-logging, the envelope block and the `initialize` instructions. |
| `Makefile` | Builds `kb.c` and adds `-lsqlite3`. |
| `test.sh` | The knowledge section. |
| `README.md` | The knowledge tools, `CNTCTR_DB` and `CNTCTR_MEM_URL`. |

## Out of scope (v1)

- Cross-machine sync and visibility enforcement (sub-project 2).
- Embeddings in cntctr itself.
- Importing Serena memories.
- A retry queue for claude-mem.
- Scheduling the librarian automatically.
- Editing entries in place: replace an entry with `note` plus `supersedes`.
