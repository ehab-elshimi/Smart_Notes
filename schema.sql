-- Smart Notes: PostgreSQL schema (MVP)
-- Laravel also creates its own framework tables via migrations:
-- personal_access_tokens (Sanctum), jobs and failed_jobs (queue), migrations.

CREATE TYPE analysis_status AS ENUM ('pending', 'processing', 'completed', 'failed');
CREATE TYPE content_source  AS ENUM ('ai', 'manual');

-- Users -------------------------------------------------------------------
CREATE TABLE users (
    id                BIGSERIAL PRIMARY KEY,
    name              VARCHAR(255) NOT NULL,
    email             VARCHAR(255) NOT NULL UNIQUE,
    email_verified_at TIMESTAMPTZ,
    password          VARCHAR(255) NOT NULL,
    created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at        TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Notes -------------------------------------------------------------------
CREATE TABLE notes (
    id            BIGSERIAL PRIMARY KEY,
    user_id       BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    title         VARCHAR(255) NOT NULL DEFAULT '',
    body          TEXT NOT NULL CHECK (char_length(body) <= 20000),
    search_vector tsvector GENERATED ALWAYS AS (
                      to_tsvector('simple', coalesce(title, '') || ' ' || coalesce(body, ''))
                  ) STORED,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at    TIMESTAMPTZ,                       -- soft delete
    UNIQUE (id, user_id)                             -- enables the composite FK from tasks
);

CREATE INDEX notes_user_updated_idx ON notes (user_id, updated_at DESC) WHERE deleted_at IS NULL;
CREATE INDEX notes_search_idx       ON notes USING GIN (search_vector);

-- Analyses: one row per AI run, so history, status and cost are tracked -----
CREATE TABLE note_analyses (
    id             BIGSERIAL PRIMARY KEY,
    note_id        BIGINT NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
    status         analysis_status NOT NULL DEFAULT 'pending',
    body_hash      CHAR(64) NOT NULL,                -- SHA-256 of the analyzed body; detects stale results
    summary        TEXT,
    error_message  TEXT,
    model          VARCHAR(100),
    input_tokens   INTEGER,
    output_tokens  INTEGER,
    requested_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    completed_at   TIMESTAMPTZ,
    created_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX note_analyses_note_idx ON note_analyses (note_id, created_at DESC);

-- At most one in-flight analysis per note (blocks double-clicks and duplicate jobs)
CREATE UNIQUE INDEX note_analyses_one_active_idx
    ON note_analyses (note_id) WHERE status IN ('pending', 'processing');

-- Tags --------------------------------------------------------------------
CREATE TABLE tags (
    id       BIGSERIAL PRIMARY KEY,
    user_id  BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    name     VARCHAR(50) NOT NULL,
    UNIQUE (user_id, name)
);

CREATE TABLE note_tag (
    note_id  BIGINT NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
    tag_id   BIGINT NOT NULL REFERENCES tags(id)  ON DELETE CASCADE,
    source   content_source NOT NULL DEFAULT 'ai',
    PRIMARY KEY (note_id, tag_id)
);

CREATE INDEX note_tag_tag_idx ON note_tag (tag_id);

-- Tasks -------------------------------------------------------------------
CREATE TABLE tasks (
    id           BIGSERIAL PRIMARY KEY,
    note_id      BIGINT NOT NULL,
    user_id      BIGINT NOT NULL,
    analysis_id  BIGINT REFERENCES note_analyses(id) ON DELETE SET NULL,
    text         VARCHAR(500) NOT NULL,
    done         BOOLEAN NOT NULL DEFAULT FALSE,
    done_at      TIMESTAMPTZ,
    source       content_source NOT NULL DEFAULT 'ai',
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    -- the task owner must be the note owner
    FOREIGN KEY (note_id, user_id) REFERENCES notes(id, user_id) ON DELETE CASCADE
);

CREATE INDEX tasks_user_done_idx ON tasks (user_id, done, created_at DESC);
CREATE INDEX tasks_note_idx      ON tasks (note_id);

-- Daily usage: per-user limit on AI analyses ----------------------------------
CREATE TABLE usage_daily (
    user_id         BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    day             DATE NOT NULL,
    analyses_count  INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (user_id, day)
);
