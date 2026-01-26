"""
声线分配：为每个 speaker 分配 voice
"""
import json
import hashlib
from pathlib import Path
from typing import Dict, List, Optional

from video_remix.models.voice_pool import VoicePool
from video_remix.utils.logger import info


def assign_voices(
    segments_path: str,
    reference_audio_path: Optional[str],
    voice_pool_path: Optional[str],
    output_dir: str,
) -> str:
    """
    为每个 speaker 分配 voice。
    
    Args:
        segments_path: segments JSON 文件路径
        reference_audio_path: 参考音频路径（可选，用于性别检测）
        voice_pool_path: voice pool JSON 文件路径（可选）
        output_dir: 输出目录
    
    Returns:
        voice_assignment.json 文件路径
    """
    # 读取 segments
    with open(segments_path, "r", encoding="utf-8") as f:
        segments = json.load(f)
    
    # 加载 voice pool
    voice_pool = VoicePool(pool_path=voice_pool_path)
    
    # 统计每个 speaker 的总时长
    speaker_durations: Dict[str, float] = {}
    for seg in segments:
        speaker = seg.get("speaker", "speaker_0")
        duration = seg.get("end", 0.0) - seg.get("start", 0.0)
        speaker_durations[speaker] = speaker_durations.get(speaker, 0.0) + duration
    
    # 按时长排序（降序）
    sorted_speakers = sorted(
        speaker_durations.items(),
        key=lambda x: x[1],
        reverse=True,
    )
    
    # 获取 voice pool 中的 voices
    pool_voices = voice_pool.get_all_voices()
    male_voices = [v for v in pool_voices if v.get("gender") == "male"]
    female_voices = [v for v in pool_voices if v.get("gender") == "female"]
    
    # 如果没有 voices，使用默认值
    if not pool_voices:
        # 使用默认的 voice_id
        default_male = {"voice_id": "en-US-GuyNeural", "name": "Guy", "gender": "male"}
        default_female = {"voice_id": "en-US-JennyNeural", "name": "Jenny", "gender": "female"}
        male_voices = [default_male]
        female_voices = [default_female]
        pool_voices = [default_male, default_female]
    
    # 交替分配策略
    assignment: Dict[str, Dict[str, str]] = {}
    
    for rank, (speaker, duration) in enumerate(sorted_speakers):
        if rank < len(male_voices) + len(female_voices):
            # 交替分配：rank 0 → male_0, rank 1 → female_0, rank 2 → male_1, ...
            if rank % 2 == 0:
                # 偶数 → male
                voice_idx = rank // 2
                if voice_idx < len(male_voices):
                    voice = male_voices[voice_idx]
                else:
                    # 超出范围，使用最后一个
                    voice = male_voices[-1] if male_voices else pool_voices[0]
            else:
                # 奇数 → female
                voice_idx = rank // 2
                if voice_idx < len(female_voices):
                    voice = female_voices[voice_idx]
                else:
                    # 超出范围，使用最后一个
                    voice = female_voices[-1] if female_voices else pool_voices[0]
        else:
            # 其余 speaker 使用 hash 稳定映射
            speaker_hash = int(hashlib.md5(speaker.encode()).hexdigest(), 16)
            if speaker_hash % 2 == 0:
                voice = male_voices[0] if male_voices else pool_voices[0]
            else:
                voice = female_voices[0] if female_voices else pool_voices[0]
        
        assignment[speaker] = {
            "voice_id": voice.get("voice_id", voice.get("name", "en-US-GuyNeural")),
            "name": voice.get("name", "Guy"),
            "gender": voice.get("gender", "male"),
        }
    
    # 保存 assignment
    output_path = Path(output_dir)
    output_path.mkdir(parents=True, exist_ok=True)
    assignment_path = output_path / "voice-assignment.json"
    
    assignment_data = {
        "speakers": assignment,
        "total_speakers": len(assignment),
    }
    
    with open(assignment_path, "w", encoding="utf-8") as f:
        json.dump(assignment_data, f, indent=2, ensure_ascii=False)
    
    info(f"Voice assignment saved: {assignment_path} ({len(assignment)} speakers)")
    
    return str(assignment_path)
