# agentctl

`agentctl` is a Swift single-binary task/session manager for coding agents.

The durable workflow belongs to `agentctl`; Codex, Pi, and Claude are backend executors.
Codex is the primary backend. Pi RPC support is available for lighter polishing
turns, while Claude support remains deferred.

## Design

```text
agentctl
  -> local .agentctl task/event store now
  -> Postgres task/event/memory store
  -> local git/GitHub
  -> Codex exec --json/resume backend now
  -> Pi --mode rpc backend for lighter model turns
  -> Codex app-server / exec-server backend later
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
backend runtime boundary
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
swift run agentctl task new "polish task" --backend pi --model openai/gpt-4o-mini --prompt "Tighten README wording."
swift run agentctl task checkpoint first-task
swift run agentctl db schema
```

The root command starts the interactive agent shell. Use `--backend pi` when
creating a new interactive task with Pi instead of Codex:

```bash
swift run agentctl --backend pi --model openai/gpt-4o-mini --tools read,grep,edit
```

The interactive shell currently supports:

```text
/help
/info
/tasks
/new [title]
/resume <task> [--checkpoint <id|latest>] [--force]
/checkpoint [--push]
/checkpoints
/artifacts
/continue [path]
/release
/export [path]
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

## Git Checkpoints

`task checkpoint` and `/checkpoint` create or reuse `agent/<task-slug>`, commit
current git changes when the worktree is dirty, and record the checkpoint in
the task store. Checkpoints include a lightweight handoff manifest in metadata:
changed files, generated files, command output snippets, test result slots, and
what to inspect next.

Push is explicit. `task resume` and interactive `/resume` restore the latest
checkpoint automatically when one exists, fetching pushed checkpoint branches on
another machine before switching. `--checkpoint` targets a specific checkpoint
id prefix or `latest`. Postgres-backed resume claims the task with a short lease
so another machine cannot resume the same task in parallel. `/release` releases
this machine's claim; `--force` steals a stale or intentionally transferred
claim:

```bash
swift run agentctl task checkpoint first-task
swift run agentctl task checkpoint first-task --push
swift run agentctl task resume first-task
swift run agentctl task resume first-task --checkpoint latest
swift run agentctl task release first-task
swift run agentctl task checkpoints first-task
swift run agentctl task artifacts first-task
swift run agentctl task continue first-task
```

`/export [path]` writes the current task transcript as Markdown. Without a path
it writes to `.agentctl/exports/<task>-transcript-<timestamp>.md` in the repo.
`/continue [path]` writes a portable continuation prompt for another agent,
including task metadata, latest checkpoint, artifacts, recent commands/tests,
and recent transcript context.
