"""
PipelineStore: SQLite-backed storage for pipeline state.

Tables:
  dramas            — business entity (INTEGER PK)
  episodes          — business entity (INTEGER PK), status tracks pipeline progress
  tasks             — task queue (type = phase name or gate key)
  events            — audit log (task lifecycle events)
  artifacts         — episode-level file registry for manifest
  cues              — atomic segments (SRC=source, DST=subtitle), content entity
  utterances        — grouping shell + TTS cache (content via utterance_cues → cues)
  utterance_cues    — junction: utterance ↔ SRC cues
"""
import json
import sqlite3
from datetime import datetime, timezone
from hashlib import sha256
from pathlib import Path
from typing import Optional


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def _compute_source_hash(src_cues: list[dict]) -> str:
    """子 cue 内容指纹 (text_cn + timing + speaker + emotion)。任一变化触发 MT 重跑。"""
    parts: list[str] = []
    for c in src_cues:
        parts.append(c.get("text", ""))
        parts.append(str(c.get("start_ms", 0)))
        parts.append(str(c.get("end_ms", 0)))
        parts.append(str(c.get("speaker", "")))
        parts.append(c.get("emotion", "neutral"))
    return sha256("|".join(parts).encode()).hexdigest()[:16]


def _compute_voice_hash(text_en: str, speaker: str = "", emotion: str = "") -> str:
    """utterance.text_en + speaker + emotion 的 hash。变了触发 TTS 重跑。"""
    data = f"{text_en}|{speaker}|{emotion}"
    return sha256(data.encode()).hexdigest()[:16]


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
        self._maybe_migrate_to_v2()
        self._ensure_cues_text_en()
        self._ensure_utterance_text_columns()
        self._ensure_utterance_cues_table()
        self._ensure_utterance_caches()
        self._migrate_dicts_from_files()
        self._migrate_speaker_to_role_id()
        self._ensure_roles_role_type()
        self._drop_cues_type_column()

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

            CREATE TABLE IF NOT EXISTS utterances (
                id              INTEGER PRIMARY KEY AUTOINCREMENT,
                episode_id      INTEGER NOT NULL REFERENCES episodes(id),
                text_cn         TEXT NOT NULL DEFAULT '',
                text_en         TEXT NOT NULL DEFAULT '',
                speaker         TEXT NOT NULL DEFAULT '',
                emotion         TEXT NOT NULL DEFAULT 'neutral',
                gender          TEXT,
                kind            TEXT NOT NULL DEFAULT 'speech',
                tts_policy      TEXT,
                source_hash     TEXT,
                voice_hash      TEXT,
                audio_path      TEXT,
                tts_duration_ms INTEGER,
                tts_rate        REAL,
                tts_error       TEXT,
                created_at      TEXT NOT NULL,
                updated_at      TEXT NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_utterances_episode ON utterances(episode_id);

            CREATE TABLE IF NOT EXISTS utterance_cues (
                utterance_id INTEGER NOT NULL REFERENCES utterances(id),
                cue_id       INTEGER NOT NULL REFERENCES cues(id),
                PRIMARY KEY (utterance_id, cue_id)
            );

            CREATE TABLE IF NOT EXISTS cues (
                id           INTEGER PRIMARY KEY AUTOINCREMENT,
                episode_id   INTEGER NOT NULL REFERENCES episodes(id),
                text         TEXT NOT NULL DEFAULT '',
                text_en      TEXT NOT NULL DEFAULT '',
                start_ms     INTEGER NOT NULL,
                end_ms       INTEGER NOT NULL,
                speaker      TEXT NOT NULL DEFAULT '',
                emotion      TEXT NOT NULL DEFAULT 'neutral',
                gender       TEXT,
                kind         TEXT NOT NULL DEFAULT 'speech',
                cv           INTEGER NOT NULL DEFAULT 1,
                created_at   TEXT NOT NULL,
                updated_at   TEXT NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_cues_episode ON cues(episode_id);

            CREATE TABLE IF NOT EXISTS roles (
                id          INTEGER PRIMARY KEY AUTOINCREMENT,
                drama_id    INTEGER NOT NULL REFERENCES dramas(id),
                name        TEXT NOT NULL,
                voice_type  TEXT NOT NULL DEFAULT '',
                role_type   TEXT NOT NULL DEFAULT 'extra',
                UNIQUE(drama_id, name)
            );

            CREATE TABLE IF NOT EXISTS dictionary (
                id          INTEGER PRIMARY KEY AUTOINCREMENT,
                drama_id    INTEGER NOT NULL REFERENCES dramas(id),
                type        TEXT NOT NULL,
                src         TEXT NOT NULL,
                target      TEXT NOT NULL DEFAULT '',
                UNIQUE(drama_id, type, src)
            );
        """)

    # ── V1 → V2 Migration ─────────────────────────────────────

    def _maybe_migrate_to_v2(self) -> None:
        """Detect v1 schema and migrate to v2 (cues + utterances)."""
        # Check if old v1 utterances table exists (has source_text column)
        try:
            cols = self._conn.execute("PRAGMA table_info(utterances)").fetchall()
        except Exception:
            return
        col_names = {row[1] for row in cols}
        if "source_text" not in col_names:
            return  # Already v2 or fresh

        import shutil
        backup_path = self.db_path.with_suffix(".db.v1-backup")
        if not backup_path.exists():
            shutil.copy2(self.db_path, backup_path)

        self._migrate_to_v2()

    def _migrate_to_v2(self) -> None:
        """Migrate v1 three-table schema to v2 two-table schema."""
        now = _now_iso()

        has_segments = self._conn.execute(
            "SELECT name FROM sqlite_master WHERE type='table' AND name='segments'"
        ).fetchone() is not None

        # Step 1: Rename old tables
        self._conn.execute("ALTER TABLE utterances RENAME TO _old_utterances")
        self._conn.execute("ALTER TABLE translation_units RENAME TO _old_translation_units")
        if has_segments:
            self._conn.execute("ALTER TABLE segments RENAME TO _old_segments")

        # Step 2: Create new tables
        self._init_schema()

        # Step 3: Migrate old utterances → SRC cues
        old_utts = self._conn.execute(
            "SELECT * FROM _old_utterances ORDER BY id"
        ).fetchall()

        # Track old utterance → old unit_id mapping for grouping
        old_unit_members: dict[int, list[dict]] = {}
        for u in old_utts:
            u = dict(u)
            # Insert SRC cue
            self._conn.execute(
                """INSERT INTO cues
                   (episode_id, type, text, start_ms, end_ms,
                    speaker, emotion, gender, kind, cv, created_at, updated_at)
                   VALUES (?, 'SRC', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
                (
                    u["episode_id"],
                    u.get("source_text", ""),
                    u["start_ms"],
                    u["end_ms"],
                    u.get("speaker", ""),
                    u.get("emotion", "neutral"),
                    u.get("gender"),
                    u.get("type", "speech"),
                    u.get("cv", 1),
                    u.get("created_at", now),
                    now,
                ),
            )
            unit_id = u.get("unit_id")
            if unit_id:
                old_unit_members.setdefault(unit_id, []).append(u)

        # Step 4: Migrate old translation_units → utterances (with content fields)
        old_units = self._conn.execute(
            "SELECT * FROM _old_translation_units ORDER BY id"
        ).fetchall()

        for unit in old_units:
            unit = dict(unit)
            members = old_unit_members.get(unit["id"], [])
            # Compute content fields from member utterances
            text_cn = "".join(m.get("source_text", "") for m in members)
            text_en = " ".join(
                m.get("translated_text", "").strip() for m in members
                if m.get("translated_text", "").strip()
            )
            start_ms = members[0]["start_ms"] if members else 0
            end_ms = members[-1]["end_ms"] if members else 0
            speaker = members[0].get("speaker", "") if members else ""
            emotion = members[0].get("emotion", "neutral") if members else "neutral"
            gender = members[0].get("gender") if members else None
            kind = members[0].get("type", "speech") if members else "speech"

            # Map v1 column names to v2 for hash computation
            mapped = [{"text": m.get("source_text", ""), "speaker": m.get("speaker", ""),
                        "emotion": m.get("emotion", "neutral"),
                        "start_ms": m["start_ms"], "end_ms": m["end_ms"]}
                       for m in members]
            source_hash = _compute_source_hash(mapped) if mapped else None
            voice_hash = _compute_voice_hash(text_en) if text_en else None

            self._conn.execute(
                """INSERT INTO utterances
                   (episode_id, text_cn, text_en, start_ms, end_ms,
                    speaker, emotion, gender, kind, source_hash, voice_hash,
                    tts_policy, audio_path, tts_duration_ms, tts_rate, tts_error,
                    created_at, updated_at)
                   VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
                (
                    unit["episode_id"],
                    text_cn, text_en, start_ms, end_ms,
                    speaker, emotion, gender, kind, source_hash, voice_hash,
                    unit.get("tts_policy"),
                    unit.get("audio_path"),
                    unit.get("tts_duration_ms"),
                    unit.get("tts_rate"),
                    unit.get("tts_error"),
                    unit.get("created_at", now),
                    now,
                ),
            )

        # Step 5: Migrate old segments → DST cues
        if has_segments:
            old_segs = self._conn.execute(
                "SELECT * FROM _old_segments ORDER BY id"
            ).fetchall()
            for seg in old_segs:
                seg = dict(seg)
                self._conn.execute(
                    """INSERT INTO cues
                       (episode_id, type, text, start_ms, end_ms,
                        speaker, emotion, gender, kind, cv, created_at, updated_at)
                       VALUES (?, 'DST', ?, ?, ?, '', 'neutral', NULL, 'speech', 1, ?, ?)""",
                    (
                        seg["episode_id"],
                        seg.get("text", ""),
                        seg["start_ms"],
                        seg["end_ms"],
                        now, now,
                    ),
                )

        # Step 6: Drop old tables
        self._conn.executescript("""
            PRAGMA foreign_keys=OFF;
            DROP TABLE IF EXISTS _old_segments;
            DROP TABLE IF EXISTS _old_utterances;
            DROP TABLE IF EXISTS _old_translation_units;
            PRAGMA foreign_keys=ON;
        """)
        self._conn.commit()

    def _ensure_cues_text_en(self) -> None:
        """Add text_en column to cues table if missing (schema migration)."""
        cols = self._conn.execute("PRAGMA table_info(cues)").fetchall()
        col_names = {row[1] for row in cols}
        if "text_en" not in col_names:
            self._conn.execute(
                "ALTER TABLE cues ADD COLUMN text_en TEXT NOT NULL DEFAULT ''"
            )
            self._conn.commit()

    def _ensure_utterance_text_columns(self) -> None:
        """Add text_cn/text_en columns to utterances if missing (fresh DB from previous code)."""
        cols = self._conn.execute("PRAGMA table_info(utterances)").fetchall()
        col_names = {row[1] for row in cols}
        if "text_cn" not in col_names:
            self._conn.execute(
                "ALTER TABLE utterances ADD COLUMN text_cn TEXT NOT NULL DEFAULT ''"
            )
        if "text_en" not in col_names:
            self._conn.execute(
                "ALTER TABLE utterances ADD COLUMN text_en TEXT NOT NULL DEFAULT ''"
            )
        self._conn.commit()

    def _ensure_utterance_cues_table(self) -> None:
        """Migration: ensure utterance_cues junction links exist and backfill cue text_en.

        Detection: if utterance_cues table is empty but utterances exist, we need to
        backfill. This handles both fresh creation and the case where _init_schema
        already created an empty table.
        """
        # Table is created by _init_schema; check if it needs populating
        has_links = self._conn.execute(
            "SELECT 1 FROM utterance_cues LIMIT 1"
        ).fetchone()
        has_utts = self._conn.execute(
            "SELECT 1 FROM utterances LIMIT 1"
        ).fetchone()
        if has_links or not has_utts:
            return  # Already populated, or no utterances to backfill

        # Check if old utterances have text_en column (pre-junction schema)
        utt_cols = self._conn.execute("PRAGMA table_info(utterances)").fetchall()
        utt_col_names = {row[1] for row in utt_cols}
        has_old_text_en = "text_en" in utt_col_names and "start_ms" in utt_col_names

        # Backfill: copy text_en from old utterances → SRC cues (by time range + speaker)
        now = _now_iso()
        episodes = self._conn.execute(
            "SELECT DISTINCT episode_id FROM utterances"
        ).fetchall()
        for ep_row in episodes:
            episode_id = ep_row[0]

            if has_old_text_en:
                old_utts = self._conn.execute(
                    "SELECT * FROM utterances WHERE episode_id=? ORDER BY start_ms",
                    (episode_id,),
                ).fetchall()
                src_cues = self._conn.execute(
                    "SELECT * FROM cues WHERE episode_id=? AND type='SRC' ORDER BY start_ms",
                    (episode_id,),
                ).fetchall()

                for utt in old_utts:
                    utt = dict(utt)
                    text_en = (utt.get("text_en") or "").strip()
                    if not text_en:
                        continue
                    utt_start = utt.get("start_ms", 0)
                    utt_end = utt.get("end_ms", 0)
                    utt_speaker = utt.get("speaker", "")
                    for cue in src_cues:
                        cue = dict(cue)
                        if (cue["start_ms"] >= utt_start
                                and cue["end_ms"] <= utt_end
                                and cue["speaker"] == utt_speaker
                                and not (cue.get("text_en") or "").strip()):
                            self._conn.execute(
                                "UPDATE cues SET text_en=?, updated_at=? WHERE id=?",
                                (text_en, now, cue["id"]),
                            )

            # Rebuild utterances with proper junction links
            self._conn.commit()
            self.calculate_utterances(episode_id)

    def _ensure_utterance_caches(self) -> None:
        """Sync utterance text_cn/text_en caches from linked cues if empty."""
        needs_sync = self._conn.execute("""
            SELECT DISTINCT u.episode_id FROM utterances u
            JOIN utterance_cues uc ON uc.utterance_id = u.id
            WHERE u.text_cn = '' OR u.text_cn IS NULL
            LIMIT 1
        """).fetchone()
        if not needs_sync:
            return
        episodes = self._conn.execute(
            "SELECT DISTINCT episode_id FROM utterances"
        ).fetchall()
        for ep_row in episodes:
            self.sync_utterance_text_cache(ep_row[0])

    def _ensure_roles_role_type(self) -> None:
        """Add role_type column to roles table if missing (schema migration)."""
        cols = self._conn.execute("PRAGMA table_info(roles)").fetchall()
        col_names = {row[1] for row in cols}
        if "role_type" not in col_names:
            self._conn.execute(
                "ALTER TABLE roles ADD COLUMN role_type TEXT NOT NULL DEFAULT 'extra'"
            )
            self._conn.commit()

    def _drop_cues_type_column(self) -> None:
        """Migration: delete DST cues and drop the type column."""
        cols = self._conn.execute("PRAGMA table_info(cues)").fetchall()
        col_names = {row[1] for row in cols}
        if "type" not in col_names:
            return  # Already migrated
        self._conn.execute("PRAGMA foreign_keys=OFF")
        # Delete utterance_cues links to DST cues first (FK safety)
        self._conn.execute(
            "DELETE FROM utterance_cues WHERE cue_id IN "
            "(SELECT id FROM cues WHERE type='DST')"
        )
        self._conn.execute("DELETE FROM cues WHERE type='DST'")
        self._conn.execute("DROP INDEX IF EXISTS idx_cues_type")
        self._conn.execute("ALTER TABLE cues DROP COLUMN type")
        self._conn.execute("PRAGMA foreign_keys=ON")
        self._conn.commit()

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
                   path = CASE WHEN excluded.path != '' THEN excluded.path ELSE episodes.path END,
                   updated_at=excluded.updated_at""",
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
        row = self._conn.execute(
            """SELECT * FROM tasks
               WHERE episode_id=? AND type=? AND status='succeeded'
               ORDER BY id DESC LIMIT 1""",
            (episode_id, task_type),
        ).fetchone()
        return dict(row) if row else None

    def get_gate_task(self, episode_id: int, gate_key: str) -> Optional[dict]:
        row = self._conn.execute(
            """SELECT * FROM tasks
               WHERE episode_id=? AND type=?
               ORDER BY id DESC LIMIT 1""",
            (episode_id, gate_key),
        ).fetchone()
        return dict(row) if row else None

    def reset_to_gate(self, episode_id: int, gate_key: str) -> None:
        """Reset pipeline back to a gate.

        Only acts if the gate was already passed (succeeded). If the gate task
        is still pending (user is currently in review), this is a no-op — the
        pipeline is already at the right state.

        Deletes the gate task and all downstream phase/gate tasks,
        then creates a fresh pending gate task.
        Episode status is derived from the resulting task state.

        Used when user edits cues after a gate was already passed:
        - cv field change → reset to source_review
        - text_en change  → reset to translation_review
        """
        # Only reset if the gate was already passed
        existing_gate = self.get_gate_task(episode_id, gate_key)
        if not existing_gate or existing_gate["status"] != "succeeded":
            return

        from dubora.pipeline.phases import GATES, ALL_PHASES

        # Build ordered list: [phase, phase, gate, phase, gate, phase, ...]
        phase_names = [p.name for p in ALL_PHASES]
        gate_map = {g["after"]: g["key"] for g in GATES}

        ordered: list[str] = []
        for pname in phase_names:
            ordered.append(pname)
            gk = gate_map.get(pname)
            if gk:
                ordered.append(gk)

        # Find the gate position, delete everything from the gate onward
        if gate_key not in ordered:
            return
        gate_idx = ordered.index(gate_key)
        types_to_delete = ordered[gate_idx:]

        if types_to_delete:
            placeholders = ",".join("?" for _ in types_to_delete)
            self._conn.execute(
                f"""DELETE FROM tasks
                    WHERE episode_id=? AND type IN ({placeholders})""",
                [episode_id, *types_to_delete],
            )

        # Create fresh pending gate task
        self.create_task(episode_id, gate_key)
        # Derive and sync episode status
        status = self.derive_episode_status(episode_id)
        self.update_episode_status(episode_id, status)

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

    # ── Cues (atomic segments, no FK to utterances) ────────────

    def has_cues(self, episode_id: int) -> bool:
        """Check if an episode has any cues."""
        row = self._conn.execute(
            "SELECT 1 FROM cues WHERE episode_id = ? LIMIT 1",
            (episode_id,),
        ).fetchone()
        return row is not None

    def insert_cues(self, episode_id: int, rows: list[dict]) -> list[int]:
        """Batch insert cues. Returns list of new IDs."""
        now = _now_iso()
        ids = []
        for row in rows:
            cur = self._conn.execute(
                """INSERT INTO cues
                   (episode_id, text, text_en, start_ms, end_ms,
                    speaker, emotion, gender, kind, cv, created_at, updated_at)
                   VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
                (
                    episode_id,
                    row.get("text", ""),
                    row.get("text_en", ""),
                    row.get("start_ms", 0),
                    row.get("end_ms", 0),
                    row.get("speaker", ""),
                    row.get("emotion", "neutral"),
                    row.get("gender"),
                    row.get("kind", "speech"),
                    row.get("cv", 1),
                    now, now,
                ),
            )
            ids.append(cur.lastrowid)
        self._conn.commit()
        return ids

    @staticmethod
    def _cast_speaker(d: dict) -> dict:
        """Cast speaker field from TEXT to int (SQLite stores as TEXT, app layer uses int)."""
        try:
            d["speaker"] = int(d["speaker"])
        except (ValueError, TypeError, KeyError):
            pass
        return d

    def get_cues(self, episode_id: int) -> list[dict]:
        """Get all cues for an episode, ordered by start_ms."""
        rows = self._conn.execute(
            "SELECT * FROM cues WHERE episode_id=? ORDER BY start_ms",
            (episode_id,),
        ).fetchall()
        return [self._cast_speaker(dict(r)) for r in rows]

    def update_cue(self, cue_id: int, **fields) -> None:
        """Update specific fields of a cue."""
        if not fields:
            return
        fields["updated_at"] = _now_iso()
        set_clause = ", ".join(f"{k}=?" for k in fields)
        values = list(fields.values()) + [cue_id]
        self._conn.execute(
            f"UPDATE cues SET {set_clause} WHERE id=?",
            values,
        )
        self._conn.commit()

    def delete_cues(self, ids: list[int]) -> None:
        """Batch delete cues and their junction links."""
        if not ids:
            return
        placeholders = ",".join("?" for _ in ids)
        self._conn.execute(
            f"DELETE FROM utterance_cues WHERE cue_id IN ({placeholders})",
            ids,
        )
        self._conn.execute(
            f"DELETE FROM cues WHERE id IN ({placeholders})",
            ids,
        )
        self._conn.commit()

    def delete_episode_cues(self, episode_id: int) -> int:
        """Delete all cues for an episode."""
        cur = self._conn.execute(
            "DELETE FROM cues WHERE episode_id=?",
            (episode_id,),
        )
        self._conn.commit()
        return cur.rowcount

    def diff_and_save(self, episode_id: int, incoming: list[dict]) -> list[dict]:
        """Diff incoming SRC cues against DB, apply cv bumps.

        Rules:
        - text/speaker/start_ms/end_ms/emotion/kind/gender changed → cv++
        - New rows → INSERT (cv=1)
        - Missing rows → DELETE

        Returns updated SRC cue list.
        """
        existing = self.get_cues(episode_id)
        existing_by_id = {c["id"]: c for c in existing}
        incoming_ids = set()

        _CV_FIELDS = ("text", "speaker", "start_ms", "end_ms", "emotion", "kind", "gender")
        has_cv_change = False
        has_text_en_change = False

        for inc in incoming:
            cid = inc.get("id")
            if cid and cid in existing_by_id:
                incoming_ids.add(cid)
                old = existing_by_id[cid]
                updates = {}

                cv_changed = False
                for f in _CV_FIELDS:
                    old_val = old.get(f, "")
                    new_val = inc.get(f, "")
                    if str(old_val) != str(new_val):
                        updates[f] = new_val
                        cv_changed = True

                if cv_changed:
                    updates["cv"] = old["cv"] + 1
                    has_cv_change = True

                # text_en: save without cv bump (translation review edits)
                old_en = old.get("text_en", "")
                new_en = inc.get("text_en", "")
                if new_en != old_en:
                    updates["text_en"] = new_en
                    has_text_en_change = True

                if updates:
                    self.update_cue(cid, **updates)
            else:
                # New row
                row = {
                    "start_ms": inc.get("start_ms", 0),
                    "end_ms": inc.get("end_ms", 0),
                    "text": inc.get("text", ""),
                    "text_en": inc.get("text_en", ""),
                    "speaker": inc.get("speaker", ""),
                    "emotion": inc.get("emotion", "neutral"),
                    "kind": inc.get("kind", "speech"),
                    "gender": inc.get("gender"),
                    "cv": 1,
                }
                new_ids = self.insert_cues(episode_id, [row])
                if new_ids:
                    incoming_ids.add(new_ids[0])

        # Delete missing rows
        to_delete = [cid for cid in existing_by_id if cid not in incoming_ids]
        if to_delete:
            self.delete_cues(to_delete)

        # Recalculate utterances after cue changes
        self.calculate_utterances(episode_id)
        # Sync text_cn/text_en caches (handles translation_review edits)
        self.sync_utterance_text_cache(episode_id)

        # Reset to appropriate gate so downstream phases re-run
        if has_cv_change:
            # cv fields changed (text/speaker/timing/emotion) → back to source_review
            self.reset_to_gate(episode_id, "source_review")
        elif has_text_en_change:
            # text_en changed → back to translation_review
            self.reset_to_gate(episode_id, "translation_review")

        return self.get_cues(episode_id)

    # ── Utterances (self-contained, computed from SRC cues) ────

    def get_cues_for_utterance(self, utterance_id: int) -> list[dict]:
        """Get SRC cues linked to an utterance, ordered by start_ms."""
        rows = self._conn.execute(
            """SELECT c.* FROM cues c
               JOIN utterance_cues uc ON uc.cue_id = c.id
               WHERE uc.utterance_id = ?
               ORDER BY c.start_ms""",
            (utterance_id,),
        ).fetchall()
        return [self._cast_speaker(dict(r)) for r in rows]

    def get_utterances(self, episode_id: int) -> list[dict]:
        """Get all utterances for an episode.

        text_cn and text_en are read directly from DB (redundant caches).
        start_ms and end_ms are computed from linked cues via junction table.
        """
        utts = self._conn.execute(
            "SELECT * FROM utterances WHERE episode_id=? ORDER BY id",
            (episode_id,),
        ).fetchall()
        if not utts:
            return []

        # Batch-load cue times for start_ms/end_ms computation
        all_links = self._conn.execute(
            """SELECT uc.utterance_id, c.start_ms, c.end_ms
               FROM utterance_cues uc
               JOIN cues c ON uc.cue_id = c.id
               JOIN utterances u ON uc.utterance_id = u.id
               WHERE u.episode_id = ?
               ORDER BY uc.utterance_id, c.start_ms""",
            (episode_id,),
        ).fetchall()

        from collections import defaultdict
        cue_times: dict[int, list[tuple[int, int]]] = defaultdict(list)
        for row in all_links:
            cue_times[row[0]].append((row[1], row[2]))

        result = []
        for r in utts:
            d = dict(r)
            if d.get("tts_policy") and isinstance(d["tts_policy"], str):
                d["tts_policy"] = json.loads(d["tts_policy"])

            # text_cn and text_en read from DB directly
            # Compute start_ms, end_ms from linked cues
            times = cue_times.get(d["id"], [])
            d["start_ms"] = times[0][0] if times else 0
            d["end_ms"] = times[-1][1] if times else 0

            self._cast_speaker(d)
            result.append(d)

        result.sort(key=lambda x: x.get("start_ms", 0))
        return result

    def get_dirty_utterances_for_translate(self, episode_id: int) -> list[dict]:
        """Get utterances needing translation.

        Dirty if:
        - source_hash is NULL (never translated)
        - source_hash differs from current merged text_cn hash (cues changed)
        - Any linked cue has empty text_en (translation incomplete)
        """
        utts = self.get_utterances(episode_id)
        dirty = []
        for utt in utts:
            if utt.get("kind") == "singing":
                continue
            # Never translated
            if not utt.get("source_hash"):
                dirty.append(utt)
                continue
            # text_cn changed since last translation
            cues = self.get_cues_for_utterance(utt["id"])
            current_hash = _compute_source_hash(cues)
            if current_hash != utt["source_hash"]:
                dirty.append(utt)
                continue
            # Any cue missing text_en
            if any(not (c.get("text_en") or "").strip() for c in cues):
                dirty.append(utt)
        return dirty

    def get_dirty_utterances_for_tts(self, episode_id: int) -> list[dict]:
        """Get utterances needing TTS: voice_hash mismatch (text_en + speaker + emotion)."""
        utts = self.get_utterances(episode_id)
        dirty = []
        for utt in utts:
            text_en = utt.get("text_en", "")
            if not text_en:
                continue
            current_hash = _compute_voice_hash(
                text_en, utt.get("speaker", ""), utt.get("emotion", ""),
            )
            if utt.get("voice_hash") != current_hash:
                dirty.append(utt)
        return dirty

    def update_utterance(self, utterance_id: int, **fields) -> None:
        """Update specific fields of an utterance."""
        if not fields:
            return
        if "tts_policy" in fields and fields["tts_policy"] is not None:
            if not isinstance(fields["tts_policy"], str):
                fields["tts_policy"] = json.dumps(fields["tts_policy"], ensure_ascii=False)
        fields["updated_at"] = _now_iso()
        set_clause = ", ".join(f"{k}=?" for k in fields)
        values = list(fields.values()) + [utterance_id]
        self._conn.execute(
            f"UPDATE utterances SET {set_clause} WHERE id=?",
            values,
        )
        self._conn.commit()

    def delete_utterances(self, ids: list[int]) -> None:
        """Batch delete utterances and their junction links."""
        if not ids:
            return
        placeholders = ",".join("?" for _ in ids)
        self._conn.execute(
            f"DELETE FROM utterance_cues WHERE utterance_id IN ({placeholders})",
            ids,
        )
        self._conn.execute(
            f"DELETE FROM utterances WHERE id IN ({placeholders})",
            ids,
        )
        self._conn.commit()

    def delete_episode_utterances(self, episode_id: int) -> int:
        """Delete all utterances and junction links for an episode."""
        self._conn.execute(
            """DELETE FROM utterance_cues WHERE utterance_id IN
               (SELECT id FROM utterances WHERE episode_id=?)""",
            (episode_id,),
        )
        cur = self._conn.execute(
            "DELETE FROM utterances WHERE episode_id=?",
            (episode_id,),
        )
        self._conn.commit()
        return cur.rowcount

    def sync_utterance_text_cache(self, episode_id: int) -> None:
        """Sync text_cn and text_en caches on utterances from linked cues.

        Also recalculates voice_hash for utterances whose text_en changed.
        Called after user edits cue text_en (translation_review).
        """
        utts = self._conn.execute(
            "SELECT * FROM utterances WHERE episode_id=?",
            (episode_id,),
        ).fetchall()
        now = _now_iso()
        for utt in utts:
            utt = dict(utt)
            cues = self.get_cues_for_utterance(utt["id"])
            text_cn = "".join(c.get("text", "") for c in cues)
            text_en = " ".join(
                c.get("text_en", "").strip() for c in cues
                if c.get("text_en", "").strip()
            )
            updates: dict = {}
            if text_cn != (utt.get("text_cn") or ""):
                updates["text_cn"] = text_cn
            if text_en != (utt.get("text_en") or ""):
                updates["text_en"] = text_en
                updates["voice_hash"] = _compute_voice_hash(
                    text_en, utt.get("speaker", ""), utt.get("emotion", "neutral"),
                )
            if updates:
                updates["updated_at"] = now
                set_clause = ", ".join(f"{k}=?" for k in updates)
                values = list(updates.values()) + [utt["id"]]
                self._conn.execute(
                    f"UPDATE utterances SET {set_clause} WHERE id=?", values,
                )
        self._conn.commit()

    # ── calculate_utterances: greedy merge SRC cues → utterances ───

    def calculate_utterances(
        self, episode_id: int, *, max_gap_ms: int = 500, max_duration_ms: int = 10000,
    ) -> list[dict]:
        """Greedy-merge SRC cues into utterances.

        Match by cue id set (not source_hash):
        1. 读 SRC cues → greedy merge (same speaker+emotion, gap, duration)
        2. 每组算 cue_id 集合，跟 DB 现有 utterance 对比
        3. 相同的保留（TTS 缓存复用），新的插入，多余的删除
        4. 每次都重建 utterance_cues 关联

        source_hash 不在此处更新 — 由 translate phase 在翻译成功后写入。
        """
        src_cues = self._conn.execute(
            "SELECT * FROM cues WHERE episode_id=? ORDER BY start_ms",
            (episode_id,),
        ).fetchall()
        src_cues = [dict(r) for r in src_cues]

        if not src_cues:
            self.delete_episode_utterances(episode_id)
            return []

        # ── Step 1: Greedy merge ──
        groups: list[list[dict]] = []
        current_group: list[dict] = [src_cues[0]]

        for cue in src_cues[1:]:
            prev = current_group[-1]
            gap = cue["start_ms"] - prev["end_ms"]
            group_duration = cue["end_ms"] - current_group[0]["start_ms"]
            same_speaker = cue["speaker"] == current_group[0]["speaker"]
            same_emotion = cue.get("emotion", "neutral") == current_group[0].get("emotion", "neutral")

            if same_speaker and same_emotion and gap <= max_gap_ms and group_duration <= max_duration_ms:
                current_group.append(cue)
            else:
                groups.append(current_group)
                current_group = [cue]

        groups.append(current_group)

        # ── Step 2: Build cue_id sets for each group ──
        new_groups_with_ids: list[tuple[frozenset[int], list[dict]]] = []
        for group in groups:
            cue_ids = frozenset(c["id"] for c in group)
            new_groups_with_ids.append((cue_ids, group))

        # ── Step 3: Load existing utterance → cue_id sets ──
        existing_utts = self._conn.execute(
            "SELECT * FROM utterances WHERE episode_id=? ORDER BY id",
            (episode_id,),
        ).fetchall()
        existing_utts = [dict(r) for r in existing_utts]

        existing_cue_sets: dict[int, frozenset[int]] = {}
        for utt in existing_utts:
            links = self._conn.execute(
                "SELECT cue_id FROM utterance_cues WHERE utterance_id=?",
                (utt["id"],),
            ).fetchall()
            existing_cue_sets[utt["id"]] = frozenset(r[0] for r in links)

        # Build reverse map: cue_id_set → existing utterance
        cue_set_to_utt: dict[frozenset[int], dict] = {}
        for utt in existing_utts:
            cs = existing_cue_sets[utt["id"]]
            if cs:  # skip utterances with no links (legacy)
                cue_set_to_utt[cs] = utt

        # ── Step 4: Match by cue id set ──
        matched_utt_ids: set[int] = set()
        now = _now_iso()

        for cue_ids, group in new_groups_with_ids:
            matched_utt = cue_set_to_utt.get(cue_ids)
            text_cn = "".join(c["text"] for c in group)

            if matched_utt and matched_utt["id"] not in matched_utt_ids:
                matched_utt_ids.add(matched_utt["id"])

                # Always overwrite speaker/emotion/gender/kind from current cues
                speaker = group[0]["speaker"]
                emotion = group[0].get("emotion", "neutral")
                gender = group[0].get("gender")
                kind = group[0].get("kind", "speech")

                # source_hash comparison: decide whether to clear (trigger MT re-run)
                current_hash = _compute_source_hash(group)
                old_hash = matched_utt.get("source_hash") or ""
                new_source_hash = matched_utt.get("source_hash") if current_hash == old_hash else None

                self._conn.execute(
                    """UPDATE utterances
                       SET text_cn=?, speaker=?, emotion=?, gender=?, kind=?,
                           source_hash=?, updated_at=?
                       WHERE id=?""",
                    (text_cn, speaker, emotion, gender, kind,
                     new_source_hash, now, matched_utt["id"]),
                )

                # Rebuild junction links (idempotent)
                self._conn.execute(
                    "DELETE FROM utterance_cues WHERE utterance_id=?",
                    (matched_utt["id"],),
                )
                for cue in group:
                    self._conn.execute(
                        "INSERT INTO utterance_cues (utterance_id, cue_id) VALUES (?, ?)",
                        (matched_utt["id"], cue["id"]),
                    )
            else:
                # New utterance — source_hash=NULL (never translated)
                cur = self._conn.execute(
                    """INSERT INTO utterances
                       (episode_id, text_cn, speaker, emotion, gender, kind,
                        created_at, updated_at)
                       VALUES (?, ?, ?, ?, ?, ?, ?, ?)""",
                    (
                        episode_id,
                        text_cn,
                        group[0]["speaker"],
                        group[0].get("emotion", "neutral"),
                        group[0].get("gender"),
                        group[0].get("kind", "speech"),
                        now, now,
                    ),
                )
                utt_id = cur.lastrowid
                for cue in group:
                    self._conn.execute(
                        "INSERT INTO utterance_cues (utterance_id, cue_id) VALUES (?, ?)",
                        (utt_id, cue["id"]),
                    )

        # ── Step 5: Delete unmatched ──
        to_delete = [u["id"] for u in existing_utts if u["id"] not in matched_utt_ids]
        if to_delete:
            self.delete_utterances(to_delete)

        self._conn.commit()
        return self.get_utterances(episode_id)

    # ── Roles (per-drama) ─────────────────────────────────────

    def get_roles(self, drama_id: int) -> list[dict]:
        """Get all roles for a drama."""
        rows = self._conn.execute(
            "SELECT * FROM roles WHERE drama_id=? ORDER BY name",
            (drama_id,),
        ).fetchall()
        return [dict(r) for r in rows]

    def get_roles_map(self, drama_id: int) -> dict[str, str]:
        """Get {name: voice_type} map for a drama. Legacy compatibility."""
        rows = self._conn.execute(
            "SELECT name, voice_type FROM roles WHERE drama_id=?",
            (drama_id,),
        ).fetchall()
        return {r[0]: r[1] for r in rows}

    def ensure_role(self, drama_id: int, name: str, voice_type: str = "", role_type: str = "extra") -> int:
        """Upsert a role by name. Returns role.id."""
        self._conn.execute(
            """INSERT INTO roles (drama_id, name, voice_type, role_type)
               VALUES (?, ?, ?, ?)
               ON CONFLICT(drama_id, name) DO NOTHING""",
            (drama_id, name, voice_type, role_type),
        )
        self._conn.commit()
        row = self._conn.execute(
            "SELECT id FROM roles WHERE drama_id=? AND name=?",
            (drama_id, name),
        ).fetchone()
        return row["id"]

    def get_roles_by_id(self, drama_id: int) -> dict[int, str]:
        """Get {role_id: voice_type} map for a drama. Used by TTS."""
        rows = self._conn.execute(
            "SELECT id, voice_type FROM roles WHERE drama_id=?",
            (drama_id,),
        ).fetchall()
        return {r[0]: r[1] for r in rows}

    def get_role_name_map(self, drama_id: int) -> dict[int, str]:
        """Get {role_id: name} map for a drama. Used for display."""
        rows = self._conn.execute(
            "SELECT id, name FROM roles WHERE drama_id=?",
            (drama_id,),
        ).fetchall()
        return {r[0]: r[1] for r in rows}

    def set_roles_by_list(self, drama_id: int, roles: list[dict]) -> list[dict]:
        """Upsert roles from list of {id?, name, voice_type, role_type?}. Returns updated list."""
        seen_ids: set[int] = set()
        for role in roles:
            rid = role.get("id")
            name = role.get("name", "")
            voice_type = role.get("voice_type", "")
            role_type = role.get("role_type", "extra")
            if rid and rid > 0:
                # Update existing
                self._conn.execute(
                    "UPDATE roles SET name=?, voice_type=?, role_type=? WHERE id=? AND drama_id=?",
                    (name, voice_type, role_type, rid, drama_id),
                )
                seen_ids.add(rid)
            else:
                # Insert new
                cur = self._conn.execute(
                    """INSERT INTO roles (drama_id, name, voice_type, role_type)
                       VALUES (?, ?, ?, ?)
                       ON CONFLICT(drama_id, name) DO UPDATE SET voice_type=excluded.voice_type, role_type=excluded.role_type""",
                    (drama_id, name, voice_type, role_type),
                )
                row = self._conn.execute(
                    "SELECT id FROM roles WHERE drama_id=? AND name=?",
                    (drama_id, name),
                ).fetchone()
                if row:
                    seen_ids.add(row["id"])
        # Delete roles not in the incoming list, but keep roles still referenced by cues
        if seen_ids:
            placeholders = ",".join("?" for _ in seen_ids)
            self._conn.execute(
                f"""DELETE FROM roles WHERE drama_id=? AND id NOT IN ({placeholders})
                    AND CAST(id AS TEXT) NOT IN (
                        SELECT DISTINCT c.speaker FROM cues c
                        JOIN episodes e ON c.episode_id = e.id
                        WHERE e.drama_id = ?
                    )""",
                [drama_id, *seen_ids, drama_id],
            )
        else:
            self._conn.execute(
                """DELETE FROM roles WHERE drama_id=?
                   AND CAST(id AS TEXT) NOT IN (
                       SELECT DISTINCT c.speaker FROM cues c
                       JOIN episodes e ON c.episode_id = e.id
                       WHERE e.drama_id = ?
                   )""",
                (drama_id, drama_id),
            )
        self._conn.commit()
        return self.get_roles(drama_id)

    def upsert_role(self, drama_id: int, name: str, voice_type: str, role_type: str = "extra") -> None:
        self._conn.execute(
            """INSERT INTO roles (drama_id, name, voice_type, role_type)
               VALUES (?, ?, ?, ?)
               ON CONFLICT(drama_id, name) DO UPDATE SET voice_type=excluded.voice_type, role_type=excluded.role_type""",
            (drama_id, name, voice_type, role_type),
        )
        self._conn.commit()

    def delete_role(self, drama_id: int, name: str) -> None:
        self._conn.execute(
            "DELETE FROM roles WHERE drama_id=? AND name=?",
            (drama_id, name),
        )
        self._conn.commit()

    def set_roles(self, drama_id: int, roles: dict[str, str]) -> None:
        """Full replace: delete all then insert."""
        self._conn.execute("DELETE FROM roles WHERE drama_id=?", (drama_id,))
        for name, voice_type in roles.items():
            self._conn.execute(
                "INSERT INTO roles (drama_id, name, voice_type) VALUES (?, ?, ?)",
                (drama_id, name, voice_type),
            )
        self._conn.commit()

    # ── Dictionary (per-drama) ────────────────────────────────

    def get_dict_entries(self, drama_id: int, type: Optional[str] = None) -> list[dict]:
        if type:
            rows = self._conn.execute(
                "SELECT * FROM dictionary WHERE drama_id=? AND type=? ORDER BY src",
                (drama_id, type),
            ).fetchall()
        else:
            rows = self._conn.execute(
                "SELECT * FROM dictionary WHERE drama_id=? ORDER BY type, src",
                (drama_id,),
            ).fetchall()
        return [dict(r) for r in rows]

    def get_dict_map(self, drama_id: int, type: str) -> dict[str, str]:
        """Get {src: target} map for a drama + type."""
        rows = self._conn.execute(
            "SELECT src, target FROM dictionary WHERE drama_id=? AND type=?",
            (drama_id, type),
        ).fetchall()
        return {r[0]: r[1] for r in rows}

    def upsert_dict_entry(self, drama_id: int, type: str, src: str, target: str) -> None:
        self._conn.execute(
            """INSERT INTO dictionary (drama_id, type, src, target)
               VALUES (?, ?, ?, ?)
               ON CONFLICT(drama_id, type, src) DO UPDATE SET target=excluded.target""",
            (drama_id, type, src, target),
        )
        self._conn.commit()

    def set_dict_entries(self, drama_id: int, type: str, entries: dict[str, str]) -> None:
        """Full replace for a given type."""
        self._conn.execute(
            "DELETE FROM dictionary WHERE drama_id=? AND type=?",
            (drama_id, type),
        )
        for src, target in entries.items():
            self._conn.execute(
                "INSERT INTO dictionary (drama_id, type, src, target) VALUES (?, ?, ?, ?)",
                (drama_id, type, src, target),
            )
        self._conn.commit()

    # ── Migration: files → DB ─────────────────────────────────

    def _migrate_dicts_from_files(self) -> None:
        """One-time migration: import roles.json + names.json + slang.json into DB."""
        has_roles = self._conn.execute("SELECT 1 FROM roles LIMIT 1").fetchone()
        has_dict = self._conn.execute("SELECT 1 FROM dictionary LIMIT 1").fetchone()
        if has_roles and has_dict:
            return

        episodes = self._conn.execute(
            "SELECT DISTINCT e.drama_id, e.path "
            "FROM episodes e WHERE e.path != ''"
        ).fetchall()

        imported_dramas: set[int] = set()
        for ep in episodes:
            drama_id = ep[0]
            if drama_id in imported_dramas:
                continue
            ep_path = ep[1]
            if not ep_path:
                continue
            dict_dir = Path(ep_path).parent / "dub" / "dict"
            if not dict_dir.is_dir():
                continue
            imported_dramas.add(drama_id)

            # Import roles.json
            roles_file = dict_dir / "roles.json"
            if roles_file.exists() and not has_roles:
                try:
                    data = json.loads(roles_file.read_text(encoding="utf-8"))
                    roles = data.get("roles", {})
                    if isinstance(roles, list):
                        roles = {e["role_id"]: e["voice_type"] for e in roles if e.get("role_id")}
                    for name, voice_type in roles.items():
                        self._conn.execute(
                            """INSERT OR IGNORE INTO roles (drama_id, name, voice_type)
                               VALUES (?, ?, ?)""",
                            (drama_id, name, voice_type),
                        )
                except Exception:
                    pass

            # Import names.json
            names_file = dict_dir / "names.json"
            if names_file.exists() and not has_dict:
                try:
                    data = json.loads(names_file.read_text(encoding="utf-8"))
                    for src, target in data.items():
                        self._conn.execute(
                            """INSERT OR IGNORE INTO dictionary (drama_id, type, src, target)
                               VALUES (?, 'name', ?, ?)""",
                            (drama_id, src, target),
                        )
                except Exception:
                    pass

            # Import slang.json
            slang_file = dict_dir / "slang.json"
            if slang_file.exists() and not has_dict:
                try:
                    data = json.loads(slang_file.read_text(encoding="utf-8"))
                    for src, target in data.items():
                        self._conn.execute(
                            """INSERT OR IGNORE INTO dictionary (drama_id, type, src, target)
                               VALUES (?, 'slang', ?, ?)""",
                            (drama_id, src, target),
                        )
                except Exception:
                    pass

        self._conn.commit()

    def _migrate_speaker_to_role_id(self) -> None:
        """One-time migration: convert text speaker names to role.id integers in cues/utterances."""
        # Quick check: if no cues exist, nothing to migrate
        sample = self._conn.execute("SELECT speaker FROM cues LIMIT 1").fetchone()
        if not sample:
            return
        speaker_val = sample[0]
        # If speaker is already a valid integer matching a role.id, skip
        try:
            int(speaker_val)
            # Check if this integer corresponds to a role.id
            role_exists = self._conn.execute(
                "SELECT 1 FROM roles WHERE id=? LIMIT 1", (int(speaker_val),),
            ).fetchone()
            if role_exists:
                return  # Already migrated
        except (ValueError, TypeError):
            pass  # Non-integer speaker, needs migration

        # Collect distinct (drama_id, speaker_text) from cues
        rows = self._conn.execute("""
            SELECT DISTINCT e.drama_id, c.speaker
            FROM cues c
            JOIN episodes e ON c.episode_id = e.id
            WHERE c.speaker != ''
        """).fetchall()

        if not rows:
            return

        # Build mapping: (drama_id, speaker_text) → role_id
        mapping: dict[tuple[int, str], int] = {}
        for row in rows:
            drama_id, speaker_text = row[0], row[1]
            key = (drama_id, speaker_text)
            if key not in mapping:
                mapping[key] = self.ensure_role(drama_id, speaker_text)

        # Update cues
        for (drama_id, speaker_text), role_id in mapping.items():
            self._conn.execute("""
                UPDATE cues SET speaker = ?
                WHERE speaker = ? AND episode_id IN (
                    SELECT id FROM episodes WHERE drama_id = ?
                )
            """, (str(role_id), speaker_text, drama_id))

        # Update utterances
        for (drama_id, speaker_text), role_id in mapping.items():
            self._conn.execute("""
                UPDATE utterances SET speaker = ?
                WHERE speaker = ? AND episode_id IN (
                    SELECT id FROM episodes WHERE drama_id = ?
                )
            """, (str(role_id), speaker_text, drama_id))

        self._conn.commit()
