# Codex Backend Spike

Codex is the first-class backend.

## Goal

Prove that `agentctl` can drive Codex through the app-server/exec-server path
without PTY passthrough.

## Questions

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

- Start Codex app-server from `agentctl`.
- Send one prompt.
- Print assistant output in the CLI.
- Persist normalized events.
- Cancel a running prompt.
- Record Codex backend session metadata when available.
