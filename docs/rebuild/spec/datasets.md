# Datasets (v1)

Status: approved direction (owner, 2026-10-20). First item of the data-first roadmap (`docs/rebuild/study/racky-features-data.html`).

## Goal

Everything subagents collect becomes a **dataset**: a named table with a schema, a key, rows that are deduplicated across computers, provenance per row and export. A data person opens Racky and sees the table filling live while the agents work, then exports it.

## Scope v1

In: store tables, MCP tools for agents (define, append, import file, read), live dataset page, row provenance, invalid rows, export CSV / JSON Lines / JSON, worker prompt text, automation IDs, tests.
Out (later items): Parquet/Excel, SQL (DuckDB), versions/diff, destinations, recipes/queue, new UI reskin.

## Model

A dataset belongs to a **session** (the parent session of the computers), so every subagent of that session appends to the same table.

Migration `v10_datasets` (never edit published migrations; STRICT tables like the others):

- `dataset`: `id TEXT PK (ULID)`, `session_id TEXT NOT NULL REFERENCES session(id) ON DELETE CASCADE`, `name TEXT NOT NULL` (unique per session, slug `[a-z0-9_-]{1,64}`), `columns TEXT NOT NULL` (JSON array of `{name, type, required}`; type ∈ `string|integer|number|boolean|date|datetime|url|json`), `key TEXT NOT NULL` (JSON array of column names; empty = whole row is the key), `created_at INTEGER`, `updated_at INTEGER`.
- `dataset_row`: `dataset_id TEXT NOT NULL REFERENCES dataset(id) ON DELETE CASCADE`, `row_key TEXT NOT NULL` (SHA-256 hex of the canonical JSON of the key values), `data TEXT NOT NULL` (JSON object, columns only), `valid INTEGER NOT NULL` (0/1), `error TEXT` (why invalid), `computer TEXT`, `run_id TEXT`, `request_id TEXT` (ULID or NULL), `source_url TEXT`, `trust TEXT CHECK (trust IN ('observed','reported','none'))`, `first_seen INTEGER`, `last_seen INTEGER`, `seen_count INTEGER NOT NULL DEFAULT 1`, `PRIMARY KEY (dataset_id, row_key)`. Index on `(dataset_id, last_seen)`.

Upsert rule: same `row_key` → replace `data`, keep `first_seen`, bump `last_seen` and `seen_count`; report as `updated` when data changed, `duplicate` when identical.

Validation: unknown columns are dropped (reported once), missing required → invalid, type coercion (`"12"` → integer 12, `"4,5"` stays invalid for number, dates ISO 8601, url must be http(s)). Invalid rows are stored with `valid=0` and `error`, never silently dropped.

Limits: 5,000 rows per append call, 1 MiB per row, cells are untrusted text (exports keep the existing `safeCell` formula-injection guard; extract `csvCell`/`safeCell` out of `BatchSummary` into a shared helper).

## Agent tools (child, in `ToolCatalog.all`)

- `dataset_define(name, columns[], key[])`: create or extend (adding columns is allowed; changing a type or the key of a dataset with rows is `invalid_argument`). Idempotent.
- `dataset_append(name, rows[])`: each row is an object; optional reserved fields `_request_id` (ULID from this computer's `requests.jsonl`) and `_source_url`. The service resolves `_request_id` against the reqlog: found → `trust: observed|reported` from the record and `source_url` from it; not found → row stored with `trust: none` and a warning in the result. Returns `{inserted, updated, duplicate, invalid, warnings[], total_rows}`. If the dataset does not exist it is created with columns inferred from the first row (all `string` except obvious integers/numbers/booleans) and empty key, and the result says so.
- `dataset_import(name, file, format?)`: CSV (header row, RFC 4180) or JSON Lines or JSON array from a path under `/work` (PathGuard rules: no symlinks, no `..`). Same result shape. Provenance: `trust: none`, `source_url` from a column named `url` when present.
- `dataset_read(name, limit?, offset?, invalid_only?)`: rows back as JSON (max 500).

Parent tools (`parentTools`): `dataset_list` (name, rows, invalid, updated, columns) and `dataset_read` (same as child).

Worker prompt (`OrchestrationInjection`/`OrchestrationProviders`): one short paragraph: "When you collect tabular data, define a dataset with a key and append rows as you go (batches of up to 500), passing `_request_id` from `reqlog_query` for each row's source page. Don't hold everything until the end." Keep the server `instructions` under the 1,500-character cap.

## UI

- Sidebar nav: **Datasets** entry after Computers (page `CenterPage.datasets`).
- **Datasets page**: table of all datasets (name, session, rows, invalid, columns, updated), newest first; empty state explains what fills it.
- **Dataset page** (`CenterPage.dataset(id)`): header with name, session, row count, invalid count, last update; toolbar: filter (all / invalid), search text, Export ▾ (CSV, JSON Lines, JSON) via the existing `NSSavePanel` + automation path pattern of `ComputersController+Batch`. Body: SwiftUI `Table` (or the lightest grid that handles 100k rows: page of 1,000 rows, "Load more"), mono for numbers, refresh every 1 s while any computer of the session is running. Selecting a row shows provenance below/right: source URL (opens in browser), computer, run, request id (opens the existing evidence view), trust badge (reuse the Observed / Agent-reported badge), first/last seen, seen count, error for invalid rows.
- Follow the current design system (no reskin yet). UI never reads files directly; data comes through a controller/loader off the main actor.
- All controls via `ActionButton`/`DSButton` with IDs added to `docs/rebuild/spec/03-screens.md` §22/§24 and regenerated with `scripts/gen-automation-ids.py` (e.g. `page.datasets`, `datasets.row.<id>`, `dataset.export`, `dataset.filter`, `dataset.search`, `dataset.row.<key>`). Strings localized through the String Catalog; `scripts/lint-ui.sh` must pass.

## Tests

- StoreTests: migration chain tail, upsert/dedupe counts, cascade on session delete.
- CoreTests: validation/coercion, key hashing stable across key order, provenance resolution against a seeded reqlog (`RunFixture`), CSV/JSONL import edge cases (quotes, newlines, BOM, empty lines), export escaping (formula injection), limits.
- MCP tool tests next to `ComputerToolServiceTests`.
- UISnapshotTests: datasets list, dataset page with rows + provenance + invalid filter, empty state.
- Full suite green (`swift test` in `Packages/RackyKit`), `scripts/lint-ui.sh` green.
