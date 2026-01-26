"""
SRT 文件解析器：将 SRT 文件转换为 segments 格式
"""
from pathlib import Path
from typing import List, Dict
import re


def parse_srt(srt_path: str) -> List[Dict[str, any]]:
    """
    解析 SRT 文件，返回 segments 列表。
    
    Args:
        srt_path: SRT 文件路径
    
    Returns:
        segments 列表，每个 segment 包含：
        - start: 开始时间（秒，float）
        - end: 结束时间（秒，float）
        - text: 字幕文本（str）
    
    SRT 格式示例：
        1
        00:00:01,234 --> 00:00:03,456
        这是第一行字幕
        这是第二行字幕
        
        2
        00:00:04,567 --> 00:00:06,789
        这是第二段字幕
    """
    srt_file = Path(srt_path)
    if not srt_file.exists():
        raise FileNotFoundError(f"SRT file not found: {srt_path}")
    
    with open(srt_file, "r", encoding="utf-8") as f:
        content = f.read()
    
    # 使用正则表达式匹配 SRT 块
    # 格式：序号\n时间轴\n文本（可能多行）\n空行
    pattern = r'(\d+)\s*\n(\d{2}:\d{2}:\d{2},\d{3})\s*-->\s*(\d{2}:\d{2}:\d{2},\d{3})\s*\n(.*?)(?=\n\d+\s*\n|\n*$)'
    matches = re.finditer(pattern, content, re.MULTILINE | re.DOTALL)
    
    segments = []
    for match in matches:
        index = match.group(1)
        start_str = match.group(2)
        end_str = match.group(3)
        text = match.group(4).strip()
        
        # 转换时间格式：HH:MM:SS,mmm -> 秒（float）
        start_seconds = _srt_time_to_seconds(start_str)
        end_seconds = _srt_time_to_seconds(end_str)
        
        # 清理文本（移除多余的换行和空格）
        text = re.sub(r'\s+', ' ', text).strip()
        
        if text:  # 只添加非空文本
            segments.append({
                "start": start_seconds,
                "end": end_seconds,
                "text": text,
            })
    
    return segments


def _srt_time_to_seconds(time_str: str) -> float:
    """
    将 SRT 时间格式 (HH:MM:SS,mmm) 转换为秒（float）。
    
    Args:
        time_str: SRT 时间字符串，例如 "00:01:23,456"
    
    Returns:
        秒数（float），例如 83.456
    """
    # 格式：HH:MM:SS,mmm
    parts = time_str.split(',')
    if len(parts) != 2:
        raise ValueError(f"Invalid SRT time format: {time_str}")
    
    time_part = parts[0]  # HH:MM:SS
    ms_part = int(parts[1])  # mmm
    
    time_parts = time_part.split(':')
    if len(time_parts) != 3:
        raise ValueError(f"Invalid SRT time format: {time_str}")
    
    hours = int(time_parts[0])
    minutes = int(time_parts[1])
    seconds = int(time_parts[2])
    
    total_seconds = hours * 3600 + minutes * 60 + seconds + ms_part / 1000.0
    return total_seconds
