"""
字幕处理模块

职责：
- 根据 ASR 结果生成字幕文件（segments.json, srt）
- ASS 字幕格式处理
"""
from .subtitles import (
    generate_subtitles,
    generate_subtitles_from_preset,
    check_cached_subtitles,
    get_segments_path,
    get_srt_path,
)

__all__ = [
    "generate_subtitles",
    "generate_subtitles_from_preset",
    "check_cached_subtitles",
    "get_segments_path",
    "get_srt_path",
]
