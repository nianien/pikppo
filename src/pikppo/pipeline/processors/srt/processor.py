"""
Subtitle Processor: 字幕后处理（唯一对外入口）

职责：
- 接收 Phase 层的输入（raw_response，SSOT）
- 直接从 raw_response 的 utterances 生成 Subtitle Model (SubtitleModel)
- 返回 ProcessorResult（不负责文件 IO、不生成格式文件）

架构原则：
- processor.py 是唯一对外接口
- 内部实现放在 build_subtitle_model.py
- Phase 层只调用 processor.run()
- processor 只生成 Subtitle Model，不生成任何格式文件（SRT/VTT）

Subtitle Model 是 SSOT（唯一事实源）：
- 直接从 raw_response 的 utterances 生成（保留完整语义信息）
- 按照语义切分 cues（基于标点、字数等）
- 根据 words 的时间轴生成 cue 的时间轴
- 任何字幕文件（SRT/VTT）均为 Subtitle Model 的派生视图
- 下游模块（render_srt.py）负责格式渲染
"""
from typing import Any, Dict, Optional

from .._types import ProcessorResult
from .build_subtitle_model import build_subtitle_model
from .profiles import POSTPROFILES
from pikppo.schema.subtitle_model import SubtitleModel


def run(
    raw_response: Dict[str, Any],
    *,
    postprofile: str = "axis",
    audio_duration_ms: Optional[int] = None,
) -> ProcessorResult:
    """
    从 raw_response 生成 Subtitle Model (SubtitleModel)。
    
    Args:
        raw_response: ASR 原始响应（SSOT，包含完整语义信息）
        postprofile: 字幕策略名称（axis, axis_default, axis_soft，用于获取配置参数）
        audio_duration_ms: 音频时长（毫秒，可选）
    
    Returns:
        ProcessorResult:
        - data.subtitle_model: Subtitle Model (SubtitleModel，SSOT)
        - metrics: 元数据（utterances_count, cues_count, speakers_count 等）
    
    注意：
    - 直接从 raw_response 的 utterances 生成（SSOT，保留完整语义信息）
    - 按照语义切分 cues（基于标点、字数等）
    - 根据 words 的时间轴生成 cue 的时间轴
    - SRT/VTT 文件由 Phase 层调用 render_srt.py / render_vtt.py 生成
    """
    # 从 postprofile 获取配置参数
    profile = POSTPROFILES.get(postprofile, POSTPROFILES.get("axis", {}))
    max_chars = int(profile.get("max_chars", 18))
    max_dur_ms = int(profile.get("max_dur_ms", 2800))
    hard_punc = profile.get("hard_punc", "。！？；")
    soft_punc = profile.get("soft_punc", "，")
    
    # 直接从 raw_response 构建 Subtitle Model v1.2 (SSOT)
    subtitle_model = build_subtitle_model(
        raw_response=raw_response,
        source_lang="zh",  # 默认源语言为中文
        audio_duration_ms=audio_duration_ms,
        max_chars=max_chars,
        max_dur_ms=max_dur_ms,
        hard_punc=hard_punc,
        soft_punc=soft_punc,
    )
    
    # 计算总 cues 数（v1.2: 从 utterances 中统计）
    total_cues = sum(len(utt.cues) for utt in subtitle_model.utterances)
    
    return ProcessorResult(
        outputs=[],  # 由 Phase 声明 outputs，processor 只负责业务处理
        data={
            "subtitle_model": subtitle_model,  # Subtitle Model v1.2 (SSOT)
        },
        metrics={
            "utterances_count": len(subtitle_model.utterances),
            "cues_count": total_cues,
            "postprofile": postprofile,
        },
    )
