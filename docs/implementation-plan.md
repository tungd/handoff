# Implementation Plan

## Phase 1: Foundation

- SwiftPM package.
- Config and machine identity.
- Git repository detection.
- Task, session, event, checkpoint, repo, and memory models.
- Initial Postgres migration.
- CLI commands for repo inspection and schema printing.

## Phase 2: Codex MVP

- Start Codex app-server or exec-server.
- Send a user message.
- Receive assistant/tool events.
- Normalize Codex events into `AgentEvent`.
- Persist task/session/event records.

## Phase 3: Resume And Handoff

- List tasks by repo.
- Resume a task from `task_id`.
- Create checkpoint branch.
- Commit and push handoff branch.
- Recreate or switch local worktree on another machine.

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
