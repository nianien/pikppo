"""
Export API: 从 DB cues 按需生成 SRT 字幕。

仅在 pipeline 全部成功后允许导出。
"""
from pathlib import Path

import srt
from datetime import timedelta
from fastapi import APIRouter, HTTPException, Request
from fastapi.responses import PlainTextResponse

from dubora.pipeline.core.store import PipelineStore

router = APIRouter()


def _get_store(db_path: Path) -> PipelineStore:
    return PipelineStore(db_path)


def _ensure_episode(store: PipelineStore, drama: str, ep: str) -> int:
    drama_id = store.ensure_drama(name=drama)
    return store.ensure_episode(drama_id=drama_id, name=ep)


def _check_pipeline_done(store: PipelineStore, episode_id: int) -> None:
    """Raise if pipeline hasn't completed successfully."""
    tasks = store.get_tasks(episode_id)
    if not tasks:
        raise HTTPException(status_code=409, detail="Pipeline has not been run yet")
    latest = tasks[-1]
    if latest["status"] != "succeeded":
        raise HTTPException(
            status_code=409,
            detail=f"Pipeline not completed (latest task: {latest['type']} = {latest['status']})",
        )


def _build_srt(cues: list[dict], text_key: str = "text") -> str:
    """Build SRT content from cue rows."""
    subs = []
    for i, c in enumerate(cues, start=1):
        text = (c.get(text_key) or "").strip()
        if not text:
            continue
        subs.append(srt.Subtitle(
            index=i,
            start=timedelta(milliseconds=c["start_ms"]),
            end=timedelta(milliseconds=c["end_ms"]),
            content=text,
        ))
    return srt.compose(subs)


@router.get("/episodes/{drama}/{ep}/export/{lang}.srt")
async def export_srt(request: Request, drama: str, ep: str, lang: str) -> PlainTextResponse:
    """导出 SRT 字幕。lang = zh (text) | en (text_en)。"""
    if lang not in ("zh", "en"):
        raise HTTPException(status_code=400, detail="lang must be 'zh' or 'en'")

    store = _get_store(request.app.state.db_path)
    episode_id = _ensure_episode(store, drama, ep)
    _check_pipeline_done(store, episode_id)

    cues = store.get_cues(episode_id)
    if not cues:
        raise HTTPException(status_code=404, detail="No cues found")

    text_key = "text" if lang == "zh" else "text_en"
    content = _build_srt(cues, text_key=text_key)
    filename = f"{lang}.srt"
    return PlainTextResponse(
        content,
        media_type="text/plain; charset=utf-8",
        headers={"Content-Disposition": f'attachment; filename="{filename}"'},
    )
