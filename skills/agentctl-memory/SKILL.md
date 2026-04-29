# agentctl-memory

Use `agentctl memory` to read and write durable agent memory. The memory CLI emits JSON by default for agent consumption.

## Read Before Assuming

- Run `agentctl memory recent --limit 10` when starting or resuming work in a repo.
- Run `agentctl memory search "<query>" --limit 10` before assuming durable user preferences, project conventions, prior decisions, or known gotchas.
- Prefer specific searches over broad scans when you know the area you are touching.

## Write Sparingly

Write only durable information with clear future value:

- User preferences that should apply again.
- Project conventions that are not obvious from the code.
- Important decisions and their rationale.
- Non-obvious gotchas, setup details, or operational constraints.

Do not save transient chat, speculative summaries, routine progress updates, broad memories without a clear retrieval use, or facts that are already obvious in committed docs or source.

## Commands

```sh
agentctl memory recent --limit 10
agentctl memory search "release checklist" --limit 5
agentctl memory write --title "Use local store in tests" --body "Tests should use --store local unless they are explicitly covering Postgres." --scope repo --tag tests
agentctl memory archive "00000000-0000-0000-0000-000000000000"
```

Use `--scope repo` for project conventions, `--scope global-personal` or `--scope global-work` for durable user-level preferences, and narrower scopes only when the current task or session identity is known.
