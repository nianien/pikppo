-- Pipeline DB schema v1
-- 5 tables: dramas, episodes, tasks, events, artifacts

PRAGMA journal_mode=WAL;
PRAGMA foreign_keys=ON;

CREATE TABLE IF NOT EXISTS dramas (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    name        TEXT NOT NULL UNIQUE,
    synopsis    TEXT NOT NULL DEFAULT '',
    created_at  TEXT NOT NULL,
    updated_at  TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS episodes (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    drama_id    INTEGER NOT NULL REFERENCES dramas(id),
    name        TEXT NOT NULL,
    path        TEXT NOT NULL DEFAULT '',
    status      TEXT NOT NULL DEFAULT 'ready',
    created_at  TEXT NOT NULL,
    updated_at  TEXT NOT NULL,
    UNIQUE(drama_id, name)
);

CREATE TABLE IF NOT EXISTS tasks (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    drama_id    INTEGER NOT NULL,
    episode_id  INTEGER NOT NULL REFERENCES episodes(id),
    type        TEXT NOT NULL,
    status      TEXT NOT NULL DEFAULT 'pending',
    context     TEXT NOT NULL DEFAULT '{}',
    created_at  TEXT NOT NULL,
    claimed_at  TEXT,
    finished_at TEXT,
    error       TEXT
);

CREATE TABLE IF NOT EXISTS events (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    task_id     INTEGER NOT NULL REFERENCES tasks(id),
    ts          TEXT NOT NULL,
    kind        TEXT NOT NULL,
    data        TEXT NOT NULL DEFAULT '{}'
);
CREATE INDEX IF NOT EXISTS idx_events_task ON events(task_id);

CREATE TABLE IF NOT EXISTS artifacts (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    episode_id  INTEGER NOT NULL REFERENCES episodes(id),
    key         TEXT NOT NULL,
    relpath     TEXT NOT NULL,
    kind        TEXT NOT NULL,
    fingerprint TEXT NOT NULL,
    UNIQUE(episode_id, key)
);
