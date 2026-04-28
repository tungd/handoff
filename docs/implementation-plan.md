# Implementation Plan

## Phase 1: Foundation

- SwiftPM package.
- Config and machine identity.
- Git repository detection.
- Task, session, event, checkpoint, repo, and memory models.
- Initial Postgres migration.
- CLI commands for repo inspection and schema printing.
- Local task/event store.
- Postgres task/event store with `db migrate`.

## Phase 2: Codex MVP

- Drive `codex exec --json`.
- Store returned Codex thread id.
- Resume with `codex exec resume --json`.
- Send user messages one turn at a time.
- Receive assistant/tool events from JSONL.
- Normalize Codex events into `AgentEvent`.
- Persist task/session/event records.
- Start an interactive root CLI session backed by the task store.
- Render a full-screen terminal shell with task, info, events, new, resume, and raw-event commands.

## Phase 2.5: Codex App-Server

- Start Codex app-server or exec-server.
- Implement live turn start/steer/cancel.
- Replace turn-at-a-time subprocess execution where useful.

## Phase 3: Resume And Handoff

- List tasks by repo.
- Resume a task from `task_id`.
- Share task/session/event state through Postgres.
- Create checkpoint branch. (initial command implemented)
- Commit and push handoff branch. (initial command implemented)
- Recreate or switch local worktree on another machine. (initial `/resume` restore implemented)

## Phase 4: Memory

- Store memory in Postgres.
- Add full-text search.
- Expose `agentctl mcp memory` for agent self-retrieval.
- Keep durable writes reviewable by default.

## Phase 5: PWA/API

- Add `agentctl serve` with Hummingbird.
- Expose task/session APIs.
- Add SSE event stream.
- Build browser session view.

## Deferred

- Claude backend.
- ACP compatibility backend.
- Semantic search with embeddings.
- Remote unattended runner mode.
