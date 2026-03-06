"""
Episodes API: query dramas + episodes from DB
"""
from pathlib import Path
from typing import List

from fastapi import APIRouter, Request

from dubora.pipeline.core.store import PipelineStore

router = APIRouter()


def _get_store(videos_dir: Path) -> PipelineStore:
    return PipelineStore(videos_dir / "pipeline.db")


@router.get("/dramas")
async def list_dramas(request: Request) -> List[dict]:
    """Return all dramas from DB."""
    videos_dir: Path = request.app.state.videos_dir
    store = _get_store(videos_dir)
    rows = store._conn.execute(
        "SELECT id, name, synopsis FROM dramas ORDER BY id",
    ).fetchall()
    return [dict(r) for r in rows]


@router.get("/episodes")
async def list_episodes(request: Request) -> List[dict]:
    """
    Return all episodes from DB, grouped info included.

    Response:
    [
      {
        "id": 1,
        "drama": "家里家外",
        "drama_id": 10001,
        "episode": "5",
        "path": "videos/家里家外/5.mp4",
        "status": "not_started",
        "has_asr_result": true,
        "has_asr_model": false,
        "has_subtitle_model": false,
        "video_file": "家里家外/5.mp4"
      }
    ]
    """
    videos_dir: Path = request.app.state.videos_dir
    store = _get_store(videos_dir)

    rows = store._conn.execute(
        """SELECT e.id, e.name, e.path, e.status, e.drama_id,
                  d.name AS drama_name
           FROM episodes e
           JOIN dramas d ON e.drama_id = d.id
           ORDER BY d.id, CAST(e.name AS INTEGER), e.name""",
    ).fetchall()

    # Batch-query output artifacts (dubbed video + subtitles)
    artifact_rows = store._conn.execute(
        """SELECT episode_id, key, relpath FROM artifacts
           WHERE key IN ('burn.video', 'subs.en_srt', 'subs.zh_srt')""",
    ).fetchall()
    # episode_id → {key: relpath}
    artifact_map: dict[int, dict[str, str]] = {}
    for ar in artifact_rows:
        artifact_map.setdefault(ar["episode_id"], {})[ar["key"]] = ar["relpath"]

    episodes = []
    for r in rows:
        ep_id = r["id"]
        video_path = Path(r["path"]) if r["path"] else None
        # Derive workdir for checking artifacts
        workdir = video_path.parent / "dub" / video_path.stem if video_path else None

        has_asr_result = False
        has_asr_model = False
        has_subtitle_model = False
        video_file = ""
        dubbed_video = ""
        subtitle_file = ""

        if workdir:
            input_dir = workdir / "input"
            state_dir = workdir / "state"
            has_asr_result = input_dir.is_dir() and (input_dir / "asr-result.json").is_file()
            has_asr_model = state_dir.is_dir() and (state_dir / "dub.json").is_file()
            has_subtitle_model = state_dir.is_dir() and (state_dir / "subtitle.model.json").is_file()

            # Check dubbed output artifacts from DB
            ep_artifacts = artifact_map.get(ep_id, {})
            if "burn.video" in ep_artifacts:
                dubbed_path = workdir / ep_artifacts["burn.video"]
                if dubbed_path.is_file():
                    dubbed_video = str(dubbed_path)
            if "subs.en_srt" in ep_artifacts:
                srt_path = workdir / ep_artifacts["subs.en_srt"]
                if srt_path.is_file():
                    subtitle_file = str(srt_path)

        if video_path and video_path.is_file():
            video_file = f"{r['drama_name']}/{video_path.name}"

        episodes.append({
            "id": ep_id,
            "drama": r["drama_name"],
            "drama_id": r["drama_id"],
            "episode": r["name"],
            "path": r["path"] or "",
            "status": r["status"],
            "video_file": video_file,
            "has_asr_result": has_asr_result,
            "has_asr_model": has_asr_model,
            "has_subtitle_model": has_subtitle_model,
            "dubbed_video": dubbed_video,
            "subtitle_file": subtitle_file,
        })

    return episodes
