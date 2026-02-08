"""
Mix Phase: 混音（只编排与IO，调用 pipeline.processors.tts.mix_audio）
"""
import subprocess
from pathlib import Path
from typing import Dict, Optional

from pikppo.pipeline.core.phase import Phase
from pikppo.pipeline.core.types import Artifact, ErrorInfo, PhaseResult, RunContext, ResolvedOutputs
from pikppo.pipeline.processors.mix import run as mix_run
from pikppo.utils.logger import info


class MixPhase(Phase):
    """混音 Phase。"""
    
    name = "mix"
    version = "1.0.0"
    
    def requires(self) -> list[str]:
        """需要 tts.audio（sep.accompaniment / sep.vocals 可选，在 run 中手动检查）。"""
        return ["tts.audio"]
    
    def provides(self) -> list[str]:
        """生成 mix.audio。"""
        return ["mix.audio"]
    
    def run(
        self,
        ctx: RunContext,
        inputs: Dict[str, Artifact],
        outputs: ResolvedOutputs,
    ) -> PhaseResult:
        """
        执行 Mix Phase。
        
        流程：
        1. 读取 TTS 音频
        2. 混音（TTS + accompaniment，如果有）
        3. 输出混音后的音频
        """
        # 获取输入
        tts_audio_artifact = inputs["tts.audio"]
        tts_path = Path(ctx.workspace) / tts_audio_artifact.relpath
        
        if not tts_path.exists():
            return PhaseResult(
                status="failed",
                error=ErrorInfo(
                    type="FileNotFoundError",
                    message=f"TTS audio not found: {tts_path}",
                ),
            )
        
        # 获取 accompaniment（可选，从 manifest 手动查找）
        accompaniment_path = None
        vocals_path = None
        workspace_path = Path(ctx.workspace)
        try:
            from pikppo.pipeline.core.manifest import Manifest
            manifest_path = workspace_path / "manifest.json"
            manifest = Manifest(manifest_path)
            accompaniment_artifact = manifest.get_artifact("sep.accompaniment", required_by=None)
            accompaniment_path = workspace_path / accompaniment_artifact.relpath
            if not accompaniment_path.exists():
                accompaniment_path = None

            # 优先使用 sep.vocals 作为“原声人声”轨道，用于 ducking
            vocals_artifact = manifest.get_artifact("sep.vocals", required_by=None)
            vocals_path = workspace_path / vocals_artifact.relpath
            if not vocals_path.exists():
                vocals_path = None
        except (ValueError, FileNotFoundError):
            # accompaniment 不存在，使用 None（只混 TTS）
            accompaniment_path = None
            vocals_path = None
        
        # 获取 video_path（从 config）
        video_path = ctx.config.get("video_path")
        if not video_path:
            return PhaseResult(
                status="failed",
                error=ErrorInfo(
                    type="ValueError",
                    message="video_path not found in config",
                ),
            )
        
        # 使用预分配的输出路径
        mix_path = outputs.get("mix.audio")
        mix_path.parent.mkdir(parents=True, exist_ok=True)
        
        # 获取配置（仅响度相关）；混音策略固定为：BGM + 英文 TTS，不要中文对白。
        phase_config = ctx.config.get("phases", {}).get("mix", {})
        target_lufs = phase_config.get("target_lufs", ctx.config.get("dub_target_lufs", -16.0))
        true_peak = phase_config.get("true_peak", ctx.config.get("dub_true_peak", -1.0))
        # 按你的要求：默认不要中文对话，只保留背景音乐 + 英文译音。
        # 允许通过 phases.mix.mute_original 显式关闭（例如调试时想听原声）。
        mute_original = bool(phase_config.get("mute_original", True))
        mix_mode = phase_config.get("mode", "ducking")
        tts_volume = float(phase_config.get("tts_volume", 1.0))
        accompaniment_volume = float(phase_config.get("accompaniment_volume", 0.8))
        vocals_volume = float(phase_config.get("vocals_volume", 0.15))
        duck_threshold = float(phase_config.get("duck_threshold", 0.05))
        duck_ratio = float(phase_config.get("duck_ratio", 10.0))
        duck_attack_ms = float(phase_config.get("duck_attack_ms", 20.0))
        duck_release_ms = float(phase_config.get("duck_release_ms", 400.0))
        
        try:
            # 调用 Processor 层进行混音
            if not mix_path.exists():
                temp_video = workspace_path / ".temp_mix.mp4"
                
                result = mix_run(
                    tts_path=str(tts_path),
                    video_path=video_path,
                    accompaniment_path=str(accompaniment_path) if accompaniment_path else None,
                    vocals_path=str(vocals_path) if vocals_path else None,
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
                    output_path=str(temp_video),
                )
                
                # 从视频提取音频
                cmd = [
                    "ffmpeg",
                    "-i", str(temp_video),
                    "-map", "0:a:0",
                    "-acodec", "pcm_s16le",
                    "-y",
                    str(mix_path),
                ]
                result = subprocess.run(
                    cmd,
                    check=True,
                    capture_output=True,
                    text=True,
                )
                
                # 清理临时视频
                if temp_video.exists():
                    temp_video.unlink()
            
            if not mix_path.exists():
                return PhaseResult(
                    status="failed",
                    error=ErrorInfo(
                        type="RuntimeError",
                        message=f"Mix failed: {mix_path} was not created",
                    ),
                )
            
            info(f"Mix completed: {mix_path.name} (size: {mix_path.stat().st_size / 1024 / 1024:.2f} MB)")
            
            # 返回 PhaseResult：只声明哪些 outputs 成功
            return PhaseResult(
                status="succeeded",
                outputs=["mix.audio"],
                metrics={
                    "mix_audio_size_mb": mix_path.stat().st_size / 1024 / 1024,
                },
            )
            
        except subprocess.CalledProcessError as e:
            return PhaseResult(
                status="failed",
                error=ErrorInfo(
                    type="RuntimeError",
                    message=f"FFmpeg failed: {e.stderr or e.stdout or 'Unknown error'}",
                ),
            )
        except Exception as e:
            return PhaseResult(
                status="failed",
                error=ErrorInfo(
                    type=type(e).__name__,
                    message=str(e),
                ),
            )
