CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS pg_trgm;

CREATE TABLE IF NOT EXISTS machines (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    stable_name text NOT NULL UNIQUE,
    hostname text NOT NULL,
    kind text NOT NULL DEFAULT 'mac',
    created_at timestamptz NOT NULL DEFAULT now(),
    last_seen_at timestamptz NOT NULL DEFAULT now(),
    metadata jsonb NOT NULL DEFAULT '{}'::jsonb
);

CREATE TABLE IF NOT EXISTS repos (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    canonical_remote_url text NOT NULL UNIQUE,
    default_branch text,
    created_at timestamptz NOT NULL DEFAULT now(),
    metadata jsonb NOT NULL DEFAULT '{}'::jsonb
);

CREATE TABLE IF NOT EXISTS repo_paths (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    repo_id uuid NOT NULL REFERENCES repos(id) ON DELETE CASCADE,
    machine_id uuid NOT NULL REFERENCES machines(id) ON DELETE CASCADE,
    path text NOT NULL,
    last_seen_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (repo_id, machine_id, path)
);

CREATE TABLE IF NOT EXISTS tasks (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    repo_id uuid REFERENCES repos(id) ON DELETE SET NULL,
    title text NOT NULL,
    slug text NOT NULL,
    backend_preference text NOT NULL DEFAULT 'codex',
    state text NOT NULL DEFAULT 'open',
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    metadata jsonb NOT NULL DEFAULT '{}'::jsonb
);

CREATE INDEX IF NOT EXISTS tasks_repo_id_idx ON tasks(repo_id);
CREATE INDEX IF NOT EXISTS tasks_state_idx ON tasks(state);
CREATE UNIQUE INDEX IF NOT EXISTS tasks_repo_slug_open_idx
    ON tasks(repo_id, slug)
    WHERE state IN ('open', 'blocked');

CREATE TABLE IF NOT EXISTS sessions (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    task_id uuid NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
    backend text NOT NULL,
    backend_session_id text,
    machine_id uuid REFERENCES machines(id) ON DELETE SET NULL,
    cwd text NOT NULL,
    state text NOT NULL DEFAULT 'starting',
    started_at timestamptz NOT NULL DEFAULT now(),
    ended_at timestamptz,
    metadata jsonb NOT NULL DEFAULT '{}'::jsonb
);

CREATE INDEX IF NOT EXISTS sessions_task_id_idx ON sessions(task_id);
CREATE INDEX IF NOT EXISTS sessions_backend_session_id_idx ON sessions(backend, backend_session_id);

CREATE TABLE IF NOT EXISTS events (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    task_id uuid REFERENCES tasks(id) ON DELETE CASCADE,
    session_id uuid REFERENCES sessions(id) ON DELETE CASCADE,
    seq bigint,
    kind text NOT NULL,
    occurred_at timestamptz NOT NULL DEFAULT now(),
    payload jsonb NOT NULL DEFAULT '{}'::jsonb
);

CREATE INDEX IF NOT EXISTS events_task_id_seq_idx ON events(task_id, seq);
CREATE INDEX IF NOT EXISTS events_session_id_idx ON events(session_id);
CREATE INDEX IF NOT EXISTS events_kind_idx ON events(kind);
CREATE UNIQUE INDEX IF NOT EXISTS events_task_seq_unique_idx
    ON events(task_id, seq)
    WHERE task_id IS NOT NULL AND seq IS NOT NULL;

CREATE TABLE IF NOT EXISTS checkpoints (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    task_id uuid NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
    repo_id uuid REFERENCES repos(id) ON DELETE SET NULL,
    machine_id uuid REFERENCES machines(id) ON DELETE SET NULL,
    branch text NOT NULL,
    commit_sha text,
    remote_name text NOT NULL DEFAULT 'origin',
    pushed_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now(),
    dirty_summary jsonb NOT NULL DEFAULT '{}'::jsonb,
    metadata jsonb NOT NULL DEFAULT '{}'::jsonb
);

CREATE INDEX IF NOT EXISTS checkpoints_task_id_idx ON checkpoints(task_id);
CREATE INDEX IF NOT EXISTS checkpoints_branch_idx ON checkpoints(branch);

CREATE TABLE IF NOT EXISTS artifacts (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    task_id uuid REFERENCES tasks(id) ON DELETE CASCADE,
    session_id uuid REFERENCES sessions(id) ON DELETE SET NULL,
    kind text NOT NULL,
    title text NOT NULL,
    content_ref text NOT NULL,
    content_type text,
    created_at timestamptz NOT NULL DEFAULT now(),
    metadata jsonb NOT NULL DEFAULT '{}'::jsonb
);

CREATE INDEX IF NOT EXISTS artifacts_task_id_idx ON artifacts(task_id);

CREATE TABLE IF NOT EXISTS memory_items (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    scope_kind text NOT NULL,
    scope_id uuid,
    repo_id uuid REFERENCES repos(id) ON DELETE CASCADE,
    task_id uuid REFERENCES tasks(id) ON DELETE CASCADE,
    title text NOT NULL,
    body text NOT NULL,
    summary text,
    tags text[] NOT NULL DEFAULT '{}',
    status text NOT NULL DEFAULT 'active',
    created_by text NOT NULL,
    confidence real NOT NULL DEFAULT 1.0,
    source_event_id uuid REFERENCES events(id) ON DELETE SET NULL,
    expires_at timestamptz,
    archived_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
    search_vector tsvector GENERATED ALWAYS AS (
        setweight(to_tsvector('english', coalesce(title, '')), 'A') ||
        setweight(to_tsvector('english', coalesce(array_to_string(tags, ' '), '')), 'A') ||
        setweight(to_tsvector('english', coalesce(summary, '')), 'B') ||
        setweight(to_tsvector('english', coalesce(body, '')), 'C')
    ) STORED
);

CREATE INDEX IF NOT EXISTS memory_items_scope_idx ON memory_items(scope_kind, scope_id);
CREATE INDEX IF NOT EXISTS memory_items_repo_id_idx ON memory_items(repo_id);
CREATE INDEX IF NOT EXISTS memory_items_task_id_idx ON memory_items(task_id);
CREATE INDEX IF NOT EXISTS memory_items_search_idx ON memory_items USING gin(search_vector);
CREATE INDEX IF NOT EXISTS memory_items_tags_idx ON memory_items USING gin(tags);
CREATE INDEX IF NOT EXISTS memory_items_title_trgm_idx ON memory_items USING gin(title gin_trgm_ops);

CREATE TABLE IF NOT EXISTS memory_access_log (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    memory_id uuid NOT NULL REFERENCES memory_items(id) ON DELETE CASCADE,
    task_id uuid REFERENCES tasks(id) ON DELETE SET NULL,
    session_id uuid REFERENCES sessions(id) ON DELETE SET NULL,
    access_kind text NOT NULL,
    query text,
    occurred_at timestamptz NOT NULL DEFAULT now(),
    metadata jsonb NOT NULL DEFAULT '{}'::jsonb
);

CREATE INDEX IF NOT EXISTS memory_access_log_memory_id_idx ON memory_access_log(memory_id);
CREATE INDEX IF NOT EXISTS memory_access_log_task_id_idx ON memory_access_log(task_id);
