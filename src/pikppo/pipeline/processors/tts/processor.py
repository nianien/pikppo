"""
TTS Processor: 语音合成（唯一对外入口）

职责：
- 接收 Phase 层的输入（dub_manifest）
- 通过 speakers_to_role.json + role_to_voice.json 解析声线分配
- 合成语音并返回 ProcessorResult（不负责文件 IO）

声线解析链路：
  speakers_to_role.json → role_to_voice.json
  spk_1 → "Ping_An"    → voice_type + params

公共 API：
- run_per_segment(): Timeline-First，输出 per-segment WAVs
"""
from typing import Any, Dict, List, Optional

from .._types import ProcessorResult
from .volcengine import synthesize_tts_per_segment as synthesize_tts_per_segment_volcengine
from pikppo.pipeline.processors.voiceprint.speakers_to_role import resolve_voice_assignments
from pikppo.schema.dub_manifest import DubManifest
from pikppo.schema.tts_report import TTSReport


def run_per_segment(
    dub_manifest: DubManifest,
    segments_dir: str,
    *,
    speakers_to_role_path: Optional[str] = None,
    role_to_voice_path: Optional[str] = None,
    # VolcEngine parameters
    volcengine_app_id: Optional[str] = None,
    volcengine_access_key: Optional[str] = None,
    volcengine_resource_id: str = "seed-tts-1.0",
    volcengine_format: str = "pcm",
    volcengine_sample_rate: int = 24000,
    # Common parameters
    language: str = "en-US",
    max_workers: int = 4,
    temp_dir: str,
) -> ProcessorResult:
    """
    Per-segment TTS synthesis (Timeline-First Architecture).

    每个 utterance 输出独立的 WAV 文件到 segments_dir。
    Mix phase 负责使用 adelay 进行 timeline placement。

    Args:
        dub_manifest: DubManifest 对象（SSOT for dubbing）
        segments_dir: 输出目录（per-segment WAVs）
        speakers_to_role_path: speakers_to_role.json 路径（剧集级）
        role_to_voice_path: role_to_voice.json 路径（剧级）
        volcengine_app_id: VolcEngine APP ID
        volcengine_access_key: VolcEngine Access Key
        volcengine_resource_id: VolcEngine 资源 ID
        volcengine_format: VolcEngine 音频格式
        volcengine_sample_rate: VolcEngine 采样率
        language: 语言代码
        max_workers: 最大并发数
        temp_dir: 临时目录

    Returns:
        ProcessorResult:
        - data.voice_assignment: speaker -> {voice_type, role_id, params}
        - data.tts_report: TTSReport 对象
    """
    from pathlib import Path

    temp_path = Path(temp_dir)
    temp_path.mkdir(parents=True, exist_ok=True)

    # 1. 通过两层映射解析声线分配
    if not speakers_to_role_path or not Path(speakers_to_role_path).exists():
        raise FileNotFoundError(
            f"speakers_to_role.json not found: {speakers_to_role_path}. "
            "Run sub phase first to generate it, then manually assign roles."
        )
    if not role_to_voice_path or not Path(role_to_voice_path).exists():
        raise FileNotFoundError(
            f"role_to_voice.json not found: {role_to_voice_path}. "
            "Create it in dub/voices/ with role_id → voice_type mappings."
        )

    role_map = resolve_voice_assignments(speakers_to_role_path, role_to_voice_path)
    voice_assignment = {"speakers": {}}
    for spk, info_dict in role_map.items():
        voice_assignment["speakers"][spk] = {
            "voice_type": info_dict["voice_type"],
            "role_id": info_dict.get("role_id", ""),
            "params": info_dict.get("params", {}),
        }

    # 2. Per-segment TTS synthesis
    if not volcengine_app_id or not volcengine_access_key:
        raise ValueError("VolcEngine TTS credentials not set")

    tts_report = synthesize_tts_per_segment_volcengine(
        dub_manifest=dub_manifest,
        voice_assignment=voice_assignment,
        segments_dir=segments_dir,
        temp_dir=str(temp_path),
        app_id=volcengine_app_id,
        access_key=volcengine_access_key,
        resource_id=volcengine_resource_id,
        format=volcengine_format,
        sample_rate=volcengine_sample_rate,
        language=language,
        max_workers=max_workers,
    )

    return ProcessorResult(
        outputs=[],
        data={
            "voice_assignment": voice_assignment,
            "tts_report": tts_report,
        },
        metrics={
            "total_segments": tts_report.total_segments,
            "success_count": tts_report.success_count,
            "failed_count": tts_report.failed_count,
        },
    )
