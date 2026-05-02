# Architecture

## Boundary

`agentctl` owns the durable workflow. Backend agents execute work, but their native
session identifiers are optional metadata.

```text
agentctl task id
  -> sessions
  -> events
  -> checkpoints
  -> backend_session_id?  -- optional
```

## v1 Non-Goals

- No PTY passthrough.
- No Telegram/RayClaw adapter.
- No remote unattended runner.
- No embeddings-only memory.

## ACP Backend

The `agentctl acp` subcommand implements the Agent Client Protocol (ACP) for
integration with ACP-compatible editors:

- Communicates via JSON-RPC 2.0 over stdio.
- Maps ACP sessions to agentctl tasks.
- Streams tool call updates and message chunks.
- Supports session list, load, close, and resume operations.
- Uses the `swift-acp` SDK for protocol implementation.

## Event Model

The normalized event stream is the public contract between backends, storage, CLI,
and future PWA clients.

Initial event kinds:

```text
task.created
session.started
session.ended
user.message
assistant.delta
assistant.done
tool.started
tool.output
tool.finished
permission.requested
permission.resolved
checkpoint.created
handoff.created
memory.written
task.completed
task.failed
```

Backends must map their native stream into these events. UI layers should never
depend directly on Codex or Claude payload shapes.

## Memory

Postgres owns memory and context. Agents retrieve memory through tools, not by
receiving the entire memory corpus in the prompt.

Memory writes should be reviewable by default unless scoped to a task/session.

Search starts with Postgres full-text search:

```sql
search_vector @@ websearch_to_tsquery('english', $1)
```

Hybrid semantic search can be added later with `pgvector`.

## Stores

`agentctl` currently supports two task stores:

```text
auto      default; Postgres when configured, otherwise local fallback
postgres  shared task/session/event store
local     .agentctl/ inside the current git repository
```

Use `AGENTCTL_DATABASE_URL` or `--database-url` for Postgres. Local storage is
kept as the offline/cache path and can be forced with `--store local`.

## Git Handoff

Code movement between machines is done through Git/GitHub:

1. create or reuse `agent/<task-slug>` branch
2. commit checkpoint
3. push branch
4. target machine fetches branch
5. target machine reuses, clones, or creates local worktree
6. task resumes through `agentctl`, not native backend resume

GitHub credentials stay local to each machine.
