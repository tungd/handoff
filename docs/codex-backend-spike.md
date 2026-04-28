# Codex Backend Spike

Codex is the first-class backend.

The first end-to-end CLI path uses `codex exec --json` and
`codex exec resume --json <thread-id>` because it is available now and gives a
structured JSONL stream. This is turn-at-a-time multi-turn, not a live app-server
client.

## Goal

Prove that `agentctl` can drive Codex without PTY passthrough.

Current v1 path:

```text
agentctl task new --prompt ...
  -> codex exec --json
  -> store thread_id

agentctl task send <task> ...
  -> codex exec resume --json <thread_id>
```

Next path:

```text
agentctl
  -> codex app-server
  -> live turn start/steer/cancel events
```

## Questions

Resolved for v1:

- `codex exec --json` emits JSONL.
- `codex exec resume --json <thread-id>` supports turn-at-a-time multi-turn.

Still open for app-server:

- How does `codex app-server --listen stdio://` frame messages?
- Is the generated JSON schema enough to implement a client?
- Which messages create/open sessions?
- Which messages send prompts?
- Which stream events represent assistant text, tool calls, permissions, and completion?
- How does cancellation work?
- Does native Codex resume expose useful session identifiers?

## Useful Commands

```bash
codex app-server --help
codex app-server generate-json-schema
codex app-server generate-ts
codex app-server --listen stdio://
codex exec-server --listen ws://127.0.0.1:0
```

## Expected Adapter Shape

```swift
protocol AgentBackendAdapter {
    var descriptor: BackendDescriptor { get }
}

struct CodexBackendAdapter {
    func startSession(task: TaskRecord, cwd: URL) async throws -> SessionRecord
    func send(message: String, session: SessionRecord) async throws -> AsyncThrowingStream<AgentEvent, Error>
    func cancel(session: SessionRecord) async throws
}
```

## Acceptance Criteria

V1:

- Start a task and run one Codex turn.
- Store the Codex `thread_id`.
- Resume the same thread on a later `task send`.
- Persist normalized local events.

App-server phase:

- Start Codex app-server from `agentctl`.
- Send one prompt.
- Print assistant output in the CLI.
- Persist normalized events.
- Cancel a running prompt.
- Record Codex backend session metadata when available.
