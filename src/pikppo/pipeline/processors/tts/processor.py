"""
TTS Processor: 语音合成（唯一对外入口）

职责：
- 接收 Phase 层的输入（segments）
- 分配声线并合成语音
- 返回 ProcessorResult（不负责文件 IO）

架构原则：
- processor.py 是唯一对外接口
- 内部实现放在 impl.py, assign_voices.py, azure.py, volcengine.py
- Phase 层只调用 processor.run()

注意：
- 当前实现仍包含文件 IO（向后兼容）
- 后续需要重构以完全分离文件 IO
"""
from typing import Any, Dict, List, Optional

from .._types import ProcessorResult
from .assign_voices import assign_voices
from .azure import synthesize_tts as synthesize_tts_azure
from .volcengine import synthesize_tts as synthesize_tts_volcengine


def run(
    segments: List[Dict[str, Any]],
    *,
    reference_audio_path: Optional[str] = None,
    voice_pool_path: Optional[str] = None,
    engine: str = "azure",  # "azure" or "volcengine"
    # Azure parameters
    azure_key: Optional[str] = None,
    azure_region: Optional[str] = None,
    # VolcEngine parameters
    volcengine_app_id: Optional[str] = None,
    volcengine_access_key: Optional[str] = None,
    volcengine_resource_id: str = "seed-tts-1.0",
    volcengine_format: str = "pcm",
    volcengine_sample_rate: int = 24000,
    volcengine_enable_timestamp: bool = False,  # TTS1.0 支持
    volcengine_enable_subtitle: bool = False,  # TTS2.0/ICL2.0 支持
    # Common parameters
    language: str = "en-US",
    max_workers: int = 4,
    temp_dir: str,
) -> ProcessorResult:
    """
    分配声线并合成语音。
    
    Args:
        segments: segments 列表
        reference_audio_path: 参考音频路径（可选）
        voice_pool_path: voice pool JSON 文件路径（可选）
        engine: TTS 引擎 ("azure" 或 "volcengine")
        azure_key: Azure TTS key (Azure 引擎必需)
        azure_region: Azure region (Azure 引擎必需)
        volcengine_app_id: VolcEngine APP ID (VolcEngine 引擎必需)
        volcengine_access_key: VolcEngine Access Key (VolcEngine 引擎必需)
        volcengine_resource_id: VolcEngine 资源 ID (默认: "seed-tts-1.0")
        volcengine_format: VolcEngine 音频格式 (默认: "pcm")
        volcengine_sample_rate: VolcEngine 采样率 (默认: 24000)
        volcengine_enable_timestamp: 启用时间戳 (TTS1.0 支持)
        volcengine_enable_subtitle: 启用字幕 (TTS2.0/ICL2.0 支持)
        language: 语言代码
        max_workers: 最大并发数
        temp_dir: 临时目录（用于文件操作，后续应移除）
    
        Returns:
        ProcessorResult:
        - data.voice_assignment: speaker -> voice_id 映射
        - data.audio_path: 合成的音频文件路径（临时，后续应返回音频数据）
        - data.sentences: sentence 数据列表（仅 VolcEngine，包含时间戳/字幕）
        - meta: 元数据
    """
    # TODO: 重构以完全分离文件 IO
    # 当前实现仍使用文件路径，后续应改为返回音频数据
    
    # 1. 分配声线（需要临时文件，后续应改为纯内存操作）
    import tempfile
    import json
    from pathlib import Path
    
    temp_path = Path(temp_dir)
    temp_path.mkdir(parents=True, exist_ok=True)
    
    segments_file = temp_path / "segments.json"
    with open(segments_file, "w", encoding="utf-8") as f:
        json.dump(segments, f, indent=2, ensure_ascii=False)
    
    voice_assignment_path = assign_voices(
        str(segments_file),
        reference_audio_path,
        voice_pool_path,
        str(temp_path),
    )
    
    # 读取 voice assignment
    with open(voice_assignment_path, "r", encoding="utf-8") as f:
        voice_assignment = json.load(f)
    
    # 2. TTS 合成（根据引擎选择）
    sentences = []  # 默认没有 sentence 数据
    if engine == "azure":
        if not azure_key or not azure_region:
            raise ValueError("Azure TTS credentials not set (azure_key and azure_region required)")
        audio_path = synthesize_tts_azure(
            str(segments_file),
            voice_assignment_path,
            voice_pool_path,
            str(temp_path),
            azure_key=azure_key,
            azure_region=azure_region,
            language=language,
            max_workers=max_workers,
        )
    elif engine == "volcengine":
        if not volcengine_app_id or not volcengine_access_key:
            raise ValueError("VolcEngine TTS credentials not set (volcengine_app_id and volcengine_access_key required)")
        audio_path, sentences = synthesize_tts_volcengine(
            str(segments_file),
            voice_assignment_path,
            voice_pool_path,
            str(temp_path),
            app_id=volcengine_app_id,
            access_key=volcengine_access_key,
            resource_id=volcengine_resource_id,
            format=volcengine_format,
            sample_rate=volcengine_sample_rate,
            language=language,
            max_workers=max_workers,
            enable_timestamp=volcengine_enable_timestamp,
            enable_subtitle=volcengine_enable_subtitle,
        )
    else:
        raise ValueError(f"Unknown TTS engine: {engine}. Supported engines: 'azure', 'volcengine'")
    
    return ProcessorResult(
        outputs=[],  # 由 Phase 声明 outputs，processor 只负责业务处理
        data={
            "voice_assignment": voice_assignment,
            "audio_path": audio_path,  # 临时：后续应返回音频数据
            "sentences": sentences if engine == "volcengine" else [],  # sentence 数据（仅 VolcEngine）
        },
        metrics={
            "segments_count": len(segments),
            "speakers_count": len(set(seg.get("speaker", "speaker_0") for seg in segments)),
            "engine": engine,
            "sentences_count": len(sentences) if engine == "volcengine" else 0,
        },
    )
