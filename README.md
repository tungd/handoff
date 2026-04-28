# agentctl

`agentctl` is a Swift single-binary task/session manager for coding agents.

The durable workflow belongs to `agentctl`; Codex and Claude are backend executors.
Codex is the first-class backend. Claude support comes after the Codex loop is stable.

## Design

```text
agentctl
  -> local .agentctl task/event store now
  -> Postgres task/event/memory store
  -> local git/GitHub
  -> Codex exec --json/resume backend now
  -> Codex app-server / exec-server backend next
  -> Claude stream-json backend later
  -> optional Hummingbird PWA/API mode later
```

Core rules:

- No PTY compatibility layer in v1.
- No ACP foundation in v1.
- Resume is keyed by `agentctl` task IDs, not native backend session IDs.
- Memory/context live in Postgres. Generated files are compatibility artifacts only.
- GitHub credentials stay local per machine through `git`, `gh`, and Keychain.

## First Milestone

```text
Swift package
Postgres schema
repo detection
task/session/event model
Codex backend boundary
memory MCP boundary
basic CLI commands
```

Run:

```bash
swift build
swift run agentctl repo inspect
swift run agentctl task new "first task" --prompt "Reply briefly."
swift run agentctl task send first-task "Continue."
swift run agentctl db schema
```

## Postgres Store

Local `.agentctl/` storage is the default. Use Postgres when you want shared task
state across machines:

```bash
export AGENTCTL_DATABASE_URL='postgres://agentctl:agentctl@localhost:55432/agentctl?sslmode=disable'

swift run agentctl db migrate
swift run agentctl task new "postgres task" --store postgres
swift run agentctl task list --store postgres
swift run agentctl task send postgres-task "Continue." --store postgres
```

You can also pass `--database-url` directly instead of using the environment
variable.
