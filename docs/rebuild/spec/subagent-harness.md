# Subagents as separate Codex / OpenCode sessions (app workers, light)

Status: approved by the owner (2026-10-21). Implements the v1.1 "light app worker" of spec 07 (CS-304, CS-306, CS-308) with a per-session choice of who runs the subagents.

## Goal

Default unchanged: a Claude parent spawns Claude's native subagents (Agent/Task + `racky-worker-N`). When the session says so, each subagent instead runs as a **separate session of another agent CLI** (Codex or OpenCode, or Claude as a separate CLI): its own terminal pane next to the parent, its own reserved computer, treated in the UI as that parent's subagent. Results come back through the existing `result_submit` → `box_collect` path and datasets.

## Model

- `enum SubagentHarness: String { claude, codex, opencode, mixed }` in RackyProtocol (`Session.swift`, next to `SubagentComputersMode`). `claude` = native subagents (today). `codex` / `opencode` = app workers of that CLI. `mixed` = the parent picks per task (`agent_spawn(harness:)`; native Agent tool still allowed).
- Migration `v11_subagent_harness` (never edit v1–v10): `session.subagent_harness TEXT NOT NULL DEFAULT 'claude' CHECK (...)`; `orchestration_child.harness TEXT` (NULL = native), `orchestration_child.worker_terminal_id TEXT` (the worker's terminal), `orchestration_child.title TEXT` (short task title for the UI).
- `AppSettings.computers.defaultSubagentHarness` (default `claude`); new sessions seed from it like `defaultSubagentMode`. `ComposerDraft` / `SessionCreation` carry it.
- Changing the session's harness takes effect for the **next** spawn; no restart (the parent tools are already injected; only the skill text differs, see Prompts).

## Parent tools (ToolCatalog `parentTools`, `ComputerToolService.executeParent`)

- `agent_spawn(harness: "codex"|"opencode"|"claude", brief: string, title?: string, name?: string, display?: "headless"|"desktop", model?: string)`:
  reserves a computer exactly like `boxes_reserve` (same gate: ask/full, same queue/capacity), allocates a free child identity, then asks the app to start the worker CLI (`WorkerLauncher` closure injected from the UI layer) and **returns immediately**: `{ name, child_id, harness, state: "starting"|"queued" }`. `harness` defaults to the session's harness (and to `codex` when the session says `mixed` and none is given). Invalid when the session's harness is `claude` and the parent asks for a worker? No: allowed (explicit request), but the skill only teaches it when the session is not `claude`.
- `agent_wait(names: [string], any?: bool, wait_s?: int ≤ 45)`: long-poll until all (or any) named workers are done (worker called `result_submit` and `box_release`, or its process exited, or it failed to start). Returns per name `{ state: running|done|failed|stopped, result_ready: bool, reason? }`. Never blocks longer than `wait_s`.
- `agent_status(names?)`: same shape, no wait.
- `agent_stop(name)`: SIGINT → 5 s → SIGTERM → 5 s → SIGKILL on the worker terminal (via the launcher's stop closure), then release the computer. Only the parent that spawned it.
- `box_collect` / `batch_collect` / `boxes_release` work unchanged for workers.

## Worker launch (app side)

- `WorkerLauncher` (protocol/closure in RackyCore, implemented in RackyUI wiring): `start(parentRunID/parent terminal, sessionID, harness, childID, capability, computerName, title, prompt) async throws -> terminalID` and `stop(terminalID)`.
- The UI implementation opens the worker as a **pane split next to the parent's pane** in the parent's tab (fall back to a new tab of the same session when there is no room), via a session-targeted `WorkspaceModel` API (not `activeTab`-dependent). Terminal title: `"<Harness> · <title>"`.
- `LaunchJob` gets `workerOf: (parentID, childID, capability)`: skips parent orchestration (`subagent` = nil), injects only the worker's own MCP server:
  - Codex: `-c mcp_servers.racky_worker={command, args=[mcp, --child, <childID>, --capability, <cap>]}` with tools auto-approved (`default_tools_approval_mode="approve"` as the pool server does), plus the worker prompt as the initial prompt. Direct child identity: no `_meta.threadId` binding needed.
  - OpenCode: `OPENCODE_CONFIG_CONTENT` with only `mcp.abx-<childID>` and permissions that auto-allow its tools; worker prompt as initial prompt.
  - Claude (separate CLI): `--mcp-config` with only `abx-<childID>`, `--allowedTools mcp__abx-<childID>__*`, initial prompt.
- The computer is reserved before launch; the worker still calls `box_claim(name)` first (it is idempotent and returns `work_path_host`).
- Worker done = `result_submit` + `box_release`, or process exit. Mark `orchestration_child` ended, wake `agent_wait`. The worker pane stays open (the user can read it); it is not killed on done.
- `agent_run` for the worker terminal: `kind = app_worker_light`, `parent_run_id` = parent run (so the activity tree and the sidebar can hang it under the parent).

## Prompts (the important part)

Claude's native subagents already know the Racky workflow from their agent definition and Claude Code's own habits. Codex and OpenCode workers start cold, so their prompt is **heavier and fully explicit**. `OrchestrationText.workerPrompt(harness:computer:brief:title:)`:

1. Who you are: a Racky worker operating exactly one remote computer named `<computer>` through the `racky_worker` / `abx-*` MCP tools only. You are not the main agent; do only the brief.
2. Step 1, always: `box_claim(name: "<computer>")`; if it says queued/provisioning, call it again (each call waits up to 45 s). Keep `work_path_host`.
3. Journal as you go with `journal`: one PLAN, DOING before each step, FOUND with evidence (request ids), BLOCKED when stuck.
4. How to fetch: prefer `http_request` (fast, impersonated TLS); use `browser_open`/`browser_read`/`browser_click`… when the site needs a real browser; `reqlog_query` to find request ids of what you fetched. Never fetch from the host machine.
5. Data: when you collect tabular data, `dataset_define` once (name given in the brief, columns with types, key), then `dataset_append` **page by page** with `_request_id` on every row (from `reqlog_query`). Never hold everything until the end. Show the exact JSON shapes of these calls.
6. Files only under `/work` (scratch in `/work/scratch`, downloads in `/work/downloads`).
7. CAPTCHA / login wall / blocked: `help_request` with what you need, then `help_wait`; don't try to bypass.
8. Finish: `result_submit(result, evidence)` with a short JSON summary (counts, dataset name, notes) and evidence pointers, then `box_release()`. Then reply "DONE" and stop; don't start new work.
9. Failure: if you can't finish, `result_submit` with what you have and the reason, then `box_release()`.
10. The brief (verbatim), and the computer name.

Include a compact tool reference (name → one line) in the prompt. Keep it under ~6 KB. Claude-as-separate-CLI uses the same prompt.

Parent skill text (`OrchestrationText.skill` / Codex `developer_instructions` / OpenCode instructions): when the session's harness is `codex`/`opencode`, add a section: "Subagents in this session run as <Harness> workers: use `agent_spawn(harness:, brief:, title:)` for each subagent (one computer each), then `agent_wait` and `box_collect`; do not use the native Agent/Task tool for site work." `mixed`: describe both and when to pick which. `claude`: unchanged. The skill text must be computed at spawn time from the current session harness for the parts the parent reads via tools: also return a short hint in `boxes_status`/`agent_status` responses with the current harness, so a mid-run change is visible without restart.

## UI (done separately by the lead, not by the backend task)

Composer row "Subagents run as", session menu section, Settings default, sidebar rows from `orchestration_child` (harness logo + badge, click focuses the worker pane), pane header title.

## Tests

- Store: migration, harness on session and child, worker terminal link.
- Core: `agent_spawn` reserves + calls the launcher with the right injection per harness (Codex `-c` args, OpenCode env JSON, Claude mcp-config), returns immediately; `agent_wait` wakes on result_submit+release, on process exit, on failure, and times out at `wait_s`; `agent_stop` order; parent-only enforcement; prompts contain the required steps and the computer name and stay < 6 KB; skill text per harness.
- A fake worker CLI (no real codex/opencode/claude processes, no quota) driving the MCP tools end to end in an isolated `RACKY_HOME`, like `scripts/e2e-subagents.sh`.
