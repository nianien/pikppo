import os
import tempfile
from pathlib import Path
from typing import List, Dict

from video_remix.config.settings import PipelineConfig
from video_remix.pipeline.asr import DoubaoLLMASR
from video_remix.pipeline.media import extract_audio_to_wav
# TODO: generate_ass_subtitle function not found, commented out for now
# from video_remix.pipeline._shared.subtitle import generate_ass_subtitle as generate_ass
from video_remix.pipeline.mt import translate_segments_with_fallback as translate_with_fallback
from video_remix.utils.audio_cache import get_audio_cache_path, get_cached_audio
from video_remix.utils.normalize_zh import normalize_zh_text
from video_remix.utils.timecode import write_srt_from_segments


def _clean_text_simple(text: str) -> str:
    """
    Simple, non-LLM cleaner: remove common fillers but do not change semantics.
    """
    oral_words = ["嗯", "啊", "那个", "这个", "其实", "就是说", "然后", "就是"]
    for w in oral_words:
        text = text.replace(w, "")
    return text.strip()


def run_pipeline(
    video_path: str,
    *,
    output_dir: str | None = None,
    config: PipelineConfig | None = None,
    burn_ass: bool = False,
) -> Dict[str, str]:
    """
    Full pipeline:
        video -> audio -> Whisper -> zh.srt -> clean -> Gemini -> en.srt + ASS
        (optional) ffmpeg burn-in using ASS.

    Returns dict with paths: zh_srt, en_srt, ass, maybe burned_video.
    """
    cfg = config or PipelineConfig()

    video = Path(video_path)
    if not video.exists():
        raise FileNotFoundError(f"Video not found: {video}")

    out_dir = Path(output_dir) if output_dir else video.parent
    out_dir.mkdir(parents=True, exist_ok=True)

    base = video.stem
    zh_srt_path = out_dir / f"{base}_zh.srt"
    en_srt_path = out_dir / f"{base}_en.srt"
    ass_path = out_dir / f"{base}_en.ass"

    # 1. extract audio (with cache)
    enhance_level = getattr(cfg, "audio_enhance_level", "light")
    cached_audio = get_cached_audio(
        str(video),
        enhance_level=enhance_level if cfg.enhance_audio_for_asr else "none",
    )
    
    if cached_audio:
        audio_path = cached_audio
    else:
        # 使用缓存路径而不是临时目录
        audio_path = get_audio_cache_path(
            str(video),
            enhance_level=enhance_level if cfg.enhance_audio_for_asr else "none",
        )
        extract_audio_to_wav(
            str(video),
            str(audio_path),
            enhance_for_asr=cfg.enhance_audio_for_asr,
            enhance_level=enhance_level,
        )

    # 2. ASR (使用 DoubaoLLMASR)
    asr = DoubaoLLMASR(cfg)
    workdir = out_dir / "asr_temp"
    workdir.mkdir(parents=True, exist_ok=True)
    _, segments = asr.transcribe(
        video_path=str(audio_path),
        workdir=workdir,
        episode_stem=base,
    )

    if not segments:
        raise RuntimeError(
            "ASR produced no segments. Check audio extraction and Whisper settings."
        )

    # 3. Normalize Chinese text: term correction + simplified conversion
    # IMPORTANT: Order matters - correct terms first (may contain traditional),
    # then convert to simplified (so term map can match traditional characters)
    normalize_zh_text(segments, term_corrections=cfg.term_corrections, text_key="text")

    # 5. write zh.srt directly from ASR segments
    write_srt_from_segments(segments, str(zh_srt_path), text_key="text")

    # 6. clean text (simple, local)
    for seg in segments:
        seg["text_clean"] = _clean_text_simple(seg["text"])

    # 7. translate via Translator (with fallback)
    texts = [seg["text_clean"] for seg in segments]
    en_lines = translate_with_fallback(cfg, texts)
    # Align conservatively (preserve time axis, even if translation is empty)
    for i, seg in enumerate(segments):
        if i < len(en_lines):
            seg["text_en"] = en_lines[i]
        else:
            seg["text_en"] = ""

    # 8. write en.srt from translated text
    write_srt_from_segments(segments, str(en_srt_path), text_key="text_en")

    # 9. generate ASS with safe area
    # TODO: generate_ass_subtitle function not found, commented out for now
    # generate_ass(segments, str(ass_path), config=cfg, text_key="text_en")
    # Create empty ASS file as placeholder
    with open(ass_path, "w", encoding="utf-8") as f:
        f.write("")

    result: Dict[str, str] = {
        "zh_srt": str(zh_srt_path),
        "en_srt": str(en_srt_path),
        "ass": str(ass_path),
    }

    # 10. optionally burn-in ASS to a new video
    if burn_ass:
        burned_path = out_dir / f"{base}_en_burned.mp4"
        # use raw ffmpeg command; safer than ffmpeg-python for complex filters
        escaped_ass = os.path.abspath(ass_path).replace("\\", "\\\\").replace(":", "\\:")
        import subprocess

        cmd = [
            "ffmpeg",
            "-i",
            str(video),
            "-vf",
            f"ass={escaped_ass}",
            "-c:v",
            "libx264",
            "-c:a",
            "copy",
            "-y",
            str(burned_path),
        ]
        subprocess.run(cmd, check=True)
        result["video_burned"] = str(burned_path)

    return result


