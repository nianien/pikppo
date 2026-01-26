"""
Doubao ASR 格式转换：Segment → SRT

职责：
- Segment[] → SrtCue[]（去掉 speaker）
- 时间格式转换（毫秒 → SRT 时间格式）
- 写入 SRT 文件
"""
from typing import List
from .types import Segment, SrtCue
from pikppo.utils.timecode import srt_timestamp, write_srt_from_segments


def ms_to_srt_time(ms: int) -> str:
    """
    将毫秒转换为 SRT 时间格式 (HH:MM:SS,mmm)。
    
    Args:
        ms: 毫秒数
    
    Returns:
        SRT 时间格式字符串
    """
    return srt_timestamp(ms / 1000.0)


def to_srt(segments: List[Segment]) -> List[SrtCue]:
    """
    将 Segment[] 转换为 SrtCue[]（去掉 speaker）。
    
    Args:
        segments: 带 speaker 的 Segment 列表
    
    Returns:
        不带 speaker 的 SrtCue 列表
    """
    return [
        SrtCue(
            start_ms=seg.start_ms,
            end_ms=seg.end_ms,
            text=seg.text,  # 不包含 speaker 标签
        )
        for seg in segments
    ]


def write_srt(srt_cues: List[SrtCue], output_path: str) -> None:
    """
    将 SrtCue[] 写入 SRT 文件。
    
    Args:
        srt_cues: SrtCue 列表
        output_path: 输出文件路径
    """
    # 转换为字典格式（供 write_srt_from_segments 使用）
    segments = [
        {
            "start": cue.start_ms / 1000.0,  # 毫秒转秒
            "end": cue.end_ms / 1000.0,
            "text": cue.text,
        }
        for cue in srt_cues
    ]
    
    write_srt_from_segments(segments, output_path, text_key="text")
