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
swift run agentctl
swift run agentctl repo inspect
swift run agentctl task new "first task" --prompt "Reply briefly."
swift run agentctl task send first-task "Continue."
swift run agentctl db schema
```

The root command starts the interactive Codex shell. It currently supports:

```text
/help
/info
/tasks
/new [title]
/resume <task>
/events
/raw
/exit
```

## Postgres Store

The default store is `auto`: if `AGENTCTL_DATABASE_URL` is set, `agentctl`
uses Postgres; otherwise it falls back to local `.agentctl/` storage. Postgres
is the intended shared store across machines:

```bash
export AGENTCTL_DATABASE_URL='postgres://agentctl:agentctl@localhost:55432/agentctl?sslmode=disable'

swift run agentctl db migrate
swift run agentctl task new "postgres task"
swift run agentctl task list
swift run agentctl task send postgres-task "Continue."
```

You can also pass `--database-url` directly instead of using the environment
variable. Use `--store local` to force the local fallback, or `--store postgres`
to require Postgres even when the environment variable is not set.
