"""
PipelineStore: SQLite-backed storage for pipeline state.

5 tables:
  dramas     — business entity (INTEGER PK)
  episodes   — business entity (INTEGER PK), status tracks pipeline progress
  tasks      — task queue (type = phase name or gate key)
  events     — audit log (task lifecycle events)
  artifacts  — episode-level file registry for manifest
"""
import json
import sqlite3
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


class PipelineStore:
    """SQLite storage for pipeline state."""

    def __init__(self, db_path: Path):
        self.db_path = Path(db_path)
        self.db_path.parent.mkdir(parents=True, exist_ok=True)
        self._conn = sqlite3.connect(str(self.db_path), check_same_thread=False)
        self._conn.row_factory = sqlite3.Row
        self._conn.execute("PRAGMA journal_mode=WAL")
        self._conn.execute("PRAGMA foreign_keys=ON")
        self._init_schema()

    def _init_schema(self) -> None:
        self._conn.executescript("""
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
        """)

    def close(self) -> None:
        self._conn.close()

    # ── Dramas & Episodes ─────────────────────────────────────

    def ensure_drama(self, *, name: str, synopsis: str = "") -> int:
        """Insert or update a drama. Returns the drama id."""
        now = _now_iso()
        self._conn.execute(
            """INSERT INTO dramas (name, synopsis, created_at, updated_at)
               VALUES (?, ?, ?, ?)
               ON CONFLICT(name) DO UPDATE SET
                   updated_at=excluded.updated_at""",
            (name, synopsis, now, now),
        )
        self._conn.commit()
        row = self._conn.execute(
            "SELECT id FROM dramas WHERE name=?", (name,),
        ).fetchone()
        return row["id"]

    def ensure_episode(self, *, drama_id: int, name: str, path: str = "") -> int:
        """Insert or update an episode. Returns the episode id."""
        now = _now_iso()
        self._conn.execute(
            """INSERT INTO episodes (drama_id, name, path, created_at, updated_at)
               VALUES (?, ?, ?, ?, ?)
               ON CONFLICT(drama_id, name) DO UPDATE SET
                   path=excluded.path, updated_at=excluded.updated_at""",
            (drama_id, name, path, now, now),
        )
        self._conn.commit()
        row = self._conn.execute(
            "SELECT id FROM episodes WHERE drama_id=? AND name=?",
            (drama_id, name),
        ).fetchone()
        return row["id"]

    def get_drama_by_name(self, name: str) -> Optional[dict]:
        row = self._conn.execute(
            "SELECT * FROM dramas WHERE name=?", (name,),
        ).fetchone()
        return dict(row) if row else None

    def get_episode_by_names(self, drama_name: str, episode_name: str) -> Optional[dict]:
        """Look up episode by drama name + episode name."""
        row = self._conn.execute(
            """SELECT e.* FROM episodes e
               JOIN dramas d ON e.drama_id = d.id
               WHERE d.name=? AND e.name=?""",
            (drama_name, episode_name),
        ).fetchone()
        return dict(row) if row else None

    def update_episode_status(self, episode_id: int, status: str) -> None:
        self._conn.execute(
            "UPDATE episodes SET status=?, updated_at=? WHERE id=?",
            (status, _now_iso(), episode_id),
        )
        self._conn.commit()

    def get_episode(self, episode_id: int) -> Optional[dict]:
        row = self._conn.execute(
            "SELECT * FROM episodes WHERE id=?", (episode_id,),
        ).fetchone()
        return dict(row) if row else None

    def get_episodes(self, drama_id: int) -> list[dict]:
        rows = self._conn.execute(
            "SELECT * FROM episodes WHERE drama_id=? ORDER BY name",
            (drama_id,),
        ).fetchall()
        return [dict(r) for r in rows]

    # ── Task queue ────────────────────────────────────────────

    def create_task(
        self, episode_id: int, task_type: str, *, context: Optional[dict] = None,
    ) -> int:
        """Create a pending task. Returns the task id."""
        ep = self._conn.execute(
            "SELECT drama_id FROM episodes WHERE id=?", (episode_id,),
        ).fetchone()
        drama_id = ep["drama_id"] if ep else 0
        now = _now_iso()
        cur = self._conn.execute(
            """INSERT INTO tasks (drama_id, episode_id, type, status, context, created_at)
               VALUES (?, ?, ?, 'pending', ?, ?)""",
            (drama_id, episode_id, task_type,
             json.dumps(context or {}, ensure_ascii=False), now),
        )
        self._conn.commit()
        return cur.lastrowid

    def claim_next_task(
        self, episode_id: int, *, executable_types: Optional[list[str]] = None,
    ) -> Optional[dict]:
        """Atomically claim the next pending task for a specific episode."""
        if executable_types:
            placeholders = ",".join("?" for _ in executable_types)
            row = self._conn.execute(
                f"""SELECT * FROM tasks
                    WHERE episode_id=? AND status='pending' AND type IN ({placeholders})
                    ORDER BY id LIMIT 1""",
                [episode_id, *executable_types],
            ).fetchone()
        else:
            row = self._conn.execute(
                "SELECT * FROM tasks WHERE episode_id=? AND status='pending' ORDER BY id LIMIT 1",
                (episode_id,),
            ).fetchone()
        return self._claim_row(row)

    def claim_any_pending_task(
        self, *, executable_types: list[str],
    ) -> Optional[dict]:
        """Atomically claim the earliest pending task across all episodes."""
        placeholders = ",".join("?" for _ in executable_types)
        row = self._conn.execute(
            f"""SELECT * FROM tasks
                WHERE status='pending' AND type IN ({placeholders})
                ORDER BY id LIMIT 1""",
            executable_types,
        ).fetchone()
        return self._claim_row(row)

    def _claim_row(self, row) -> Optional[dict]:
        if row is None:
            return None
        now = _now_iso()
        self._conn.execute(
            "UPDATE tasks SET status='running', claimed_at=? WHERE id=?",
            (now, row["id"]),
        )
        self._conn.commit()
        d = dict(row)
        d["status"] = "running"
        d["claimed_at"] = now
        return d

    def complete_task(self, task_id: int) -> None:
        self._conn.execute(
            "UPDATE tasks SET status='succeeded', finished_at=? WHERE id=?",
            (_now_iso(), task_id),
        )
        self._conn.commit()

    def fail_task(self, task_id: int, *, error: Optional[str] = None) -> None:
        self._conn.execute(
            "UPDATE tasks SET status='failed', finished_at=?, error=? WHERE id=?",
            (_now_iso(), error, task_id),
        )
        self._conn.commit()

    def pass_gate_task(self, episode_id: int, gate_key: str) -> Optional[int]:
        """Mark a gate task as succeeded. Returns task id or None."""
        row = self._conn.execute(
            """SELECT id FROM tasks
               WHERE episode_id=? AND type=? AND status='pending'
               ORDER BY id DESC LIMIT 1""",
            (episode_id, gate_key),
        ).fetchone()
        if row is None:
            return None
        self._conn.execute(
            "UPDATE tasks SET status='succeeded', finished_at=? WHERE id=?",
            (_now_iso(), row["id"]),
        )
        self._conn.commit()
        return row["id"]

    def delete_pending_tasks(self, episode_id: int) -> int:
        """Delete all pending tasks for an episode. Returns count deleted."""
        cur = self._conn.execute(
            "DELETE FROM tasks WHERE episode_id=? AND status='pending'",
            (episode_id,),
        )
        self._conn.commit()
        return cur.rowcount

    def has_running_tasks(self, episode_id: int) -> bool:
        row = self._conn.execute(
            "SELECT 1 FROM tasks WHERE episode_id=? AND status='running' LIMIT 1",
            (episode_id,),
        ).fetchone()
        return row is not None

    def derive_episode_status(self, episode_id: int) -> str:
        """Derive episode status from latest task."""
        tasks = self.get_tasks(episode_id)
        if not tasks:
            return "ready"
        latest = tasks[-1]
        if latest["status"] == "running":
            return "running"
        if latest["status"] == "pending":
            return "review"
        if latest["status"] == "failed":
            return "failed"
        return "ready"

    def get_latest_task(self, episode_id: int) -> Optional[dict]:
        row = self._conn.execute(
            "SELECT * FROM tasks WHERE episode_id=? ORDER BY id DESC LIMIT 1",
            (episode_id,),
        ).fetchone()
        return dict(row) if row else None

    def get_tasks(self, episode_id: int) -> list[dict]:
        rows = self._conn.execute(
            "SELECT * FROM tasks WHERE episode_id=? ORDER BY id",
            (episode_id,),
        ).fetchall()
        return [dict(r) for r in rows]

    def update_task_context(self, task_id: int, updates: dict) -> None:
        """Merge updates into the task's context JSON."""
        row = self._conn.execute(
            "SELECT context FROM tasks WHERE id=?", (task_id,),
        ).fetchone()
        if row is None:
            return
        ctx = json.loads(row["context"] or "{}")
        ctx.update(updates)
        self._conn.execute(
            "UPDATE tasks SET context=? WHERE id=?",
            (json.dumps(ctx, ensure_ascii=False), task_id),
        )
        self._conn.commit()

    def get_latest_succeeded_task(
        self, episode_id: int, task_type: str,
    ) -> Optional[dict]:
        """Get the latest succeeded task of a given type for an episode."""
        row = self._conn.execute(
            """SELECT * FROM tasks
               WHERE episode_id=? AND type=? AND status='succeeded'
               ORDER BY id DESC LIMIT 1""",
            (episode_id, task_type),
        ).fetchone()
        return dict(row) if row else None

    def get_gate_task(self, episode_id: int, gate_key: str) -> Optional[dict]:
        """Get the latest gate task for an episode."""
        row = self._conn.execute(
            """SELECT * FROM tasks
               WHERE episode_id=? AND type=?
               ORDER BY id DESC LIMIT 1""",
            (episode_id, gate_key),
        ).fetchone()
        return dict(row) if row else None

    # ── Events (audit log) ────────────────────────────────────

    def insert_event(self, task_id: int, kind: str, data: Optional[dict] = None) -> None:
        self._conn.execute(
            "INSERT INTO events (task_id, ts, kind, data) VALUES (?, ?, ?, ?)",
            (task_id, _now_iso(), kind, json.dumps(data or {}, ensure_ascii=False)),
        )
        self._conn.commit()

    def get_events_for_episode(self, episode_id: int) -> list[dict]:
        rows = self._conn.execute(
            """SELECT e.* FROM events e
               JOIN tasks t ON e.task_id = t.id
               WHERE t.episode_id=?
               ORDER BY e.id""",
            (episode_id,),
        ).fetchall()
        return [dict(r) for r in rows]

    # ── Artifacts (episode-level) ─────────────────────────────

    def upsert_artifact(
        self, episode_id: int, key: str, relpath: str, kind: str, fingerprint: str,
    ) -> None:
        self._conn.execute(
            """INSERT INTO artifacts (episode_id, key, relpath, kind, fingerprint)
               VALUES (?, ?, ?, ?, ?)
               ON CONFLICT(episode_id, key) DO UPDATE SET
                   relpath=excluded.relpath, kind=excluded.kind,
                   fingerprint=excluded.fingerprint""",
            (episode_id, key, relpath, kind, fingerprint),
        )
        self._conn.commit()

    def get_artifact(self, episode_id: int, key: str) -> Optional[dict]:
        row = self._conn.execute(
            "SELECT key, relpath, kind, fingerprint FROM artifacts WHERE episode_id=? AND key=?",
            (episode_id, key),
        ).fetchone()
        return dict(row) if row else None

    def get_all_artifacts(self, episode_id: int) -> list[dict]:
        rows = self._conn.execute(
            "SELECT key, relpath, kind, fingerprint FROM artifacts WHERE episode_id=?",
            (episode_id,),
        ).fetchall()
        return [dict(r) for r in rows]
