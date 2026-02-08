"""
Mix Processor: 音频混音（唯一对外入口）

职责：
- 接收 Phase 层的输入（tts_audio, accompaniment, video）
- 调用内部实现进行混音
- 返回 ProcessorResult（不负责文件 IO）

架构原则：
- processor.py 是唯一对外接口
- 内部实现放在 impl.py
- Phase 层只调用 processor.run()
"""
from typing import Optional

from .._types import ProcessorResult
from .impl import mix_audio


def run(
    tts_path: str,
    video_path: str,
    *,
    accompaniment_path: Optional[str] = None,
    vocals_path: Optional[str] = None,
    mute_original: bool = False,
    mix_mode: str = "ducking",
    tts_volume: float = 1.0,
    accompaniment_volume: float = 0.8,
    vocals_volume: float = 0.15,
    duck_threshold: float = 0.05,
    duck_ratio: float = 10.0,
    duck_attack_ms: float = 20.0,
    duck_release_ms: float = 400.0,
    target_lufs: float = -16.0,
    true_peak: float = -1.0,
    output_path: str,
) -> ProcessorResult:
    """
    混音：将 TTS 音频和伴奏混合，输出到视频。
    
    Args:
        tts_path: TTS 音频文件路径
        video_path: 原始视频文件路径
        accompaniment_path: 伴奏音频文件路径（可选）
        target_lufs: 目标响度（LUFS）
        true_peak: 真峰值限制（dB）
        output_path: 输出视频文件路径
    
    Returns:
        ProcessorResult:
        - data.output_path: 输出视频文件路径
        - meta: 元数据
    """
    mix_audio(
        tts_path=tts_path,
        accompaniment_path=accompaniment_path,
        vocals_path=vocals_path,
        video_path=video_path,
        output_path=output_path,
        mute_original=mute_original,
        mix_mode=mix_mode,
        tts_volume=tts_volume,
        accompaniment_volume=accompaniment_volume,
        vocals_volume=vocals_volume,
        duck_threshold=duck_threshold,
        duck_ratio=duck_ratio,
        duck_attack_ms=duck_attack_ms,
        duck_release_ms=duck_release_ms,
        target_lufs=target_lufs,
        true_peak=true_peak,
    )
    
    return ProcessorResult(
        outputs=[],  # 由 Phase 声明 outputs，processor 只负责业务处理
        data={
            "output_path": output_path,
        },
        metrics={
            "target_lufs": target_lufs,
            "true_peak": true_peak,
        },
    )
