# Product Roadmap

`agentctl` is a lightweight orchestrator for coding agents. It owns durable
tasks, sessions, checkpoints, handoff artifacts, and memory; backend agents do
the execution.

## Current State

Implemented and usable:

- Local and Postgres task/session/event stores.
- Codex backend through `codex exec --json` and `codex exec resume --json`.
- Codex multi-turn resume through `agentctl` task IDs.
- Codex image attachments, including resumed turns.
- Pi RPC backend for cheaper/simple polishing turns.
- Interactive TUI with task lifecycle commands, native terminal scroll, prompt
  queueing, multiline paste/input, readline-like editing, prompt history, image
  paste/drop support, and Markdown transcript rendering.
- Agentctl slash commands in chat:
  `/help`, `/info`, `/tasks`, `/new`, `/resume`, `/checkpoint`, `/checkpoints`,
  `/artifacts`, `/continue`, `/release`, `/export`, `/events`, `/raw`, `/exit`.
- Git checkpoint and handoff V1:
  checkpoint branch creation, commit, optional push, restore on resume,
  dirty-work preflight, checkpoint targeting, pushed branch fetch, divergent
  branch errors, and Postgres claim leases to avoid two machines working the
  same task at the same time.
- Handoff artifacts:
  checkpoint metadata, changed/generated files, command/test output snippets,
  transcript exports, and portable continuation prompts for other agents.

## Next Slice: Memory V1

Goal: make persistent project/task memory useful without turning it into hidden
magic.

- Implement top-level memory commands for agent consumption:
  `agentctl memory search`, `agentctl memory write`,
  `agentctl memory recent`, and `agentctl memory archive`.
- Store memory in Postgres first, with local fallback where practical.
- Use Postgres full-text search before embeddings.
- Add reviewable memory writes by default:
  task/session-scoped writes can be lightweight; durable repo/global writes
  should be explicit.
- Add TUI slash commands for memory:
  `/memory search <query>`, `/memory write ...`, `/memory recent`.
- Add transcript hooks that can suggest memory candidates, but do not auto-save
  broad memories without user intent.
- Add tests around memory persistence, search ranking, and export behavior.

## Then: Memory Tool Boundary

Goal: let backend agents retrieve memory through tools instead of stuffing all
memory into prompts.

- Add an MCP/RPC boundary for memory retrieval.
- Expose memory tools:
  `memory.search`, `memory.get`, `memory.write`, `memory.update`,
  `memory.archive`, `memory.recent`.
- Make `/continue` include memory pointers, not the full memory corpus.
- Keep memory source attribution: task, repo, branch, session, and timestamp.

## Then: PWA/API Read Surface

Goal: inspect and manage task state outside the terminal.

- Add `agentctl serve` with Hummingbird.
- Expose task, session, checkpoint, artifact, transcript, and memory APIs.
- Add SSE event stream for live session views.
- Build a read-first browser UI for reviewing transcript, checkpoints,
  artifacts, and memory.

## Later

- Skills sync:
  track per-machine tools/skills, surface missing capabilities during remote
  resume, and sync metadata without secrets.
- Codex app-server or exec-server backend:
  use it if it materially improves live steering, cancellation, or latency over
  turn-at-a-time `codex exec`.
- Better Pi support:
  keep the native RPC path, improve model display/status, and treat it as a
  worker backend for bounded polishing tasks.
- Restate durable runtime exploration:
  evaluate whether Restate can replace or shrink the transcript checkpoint layer
  for long-running/resumable agent turns, and measure the operational footprint
  before adding it to the runtime path.
- Remote unattended runner mode.
- Semantic memory search with embeddings after full-text search proves useful.

## Deferred

- Claude backend.
- ACP compatibility layer.
- Editor integration.
- Fully automatic global memory writes.
