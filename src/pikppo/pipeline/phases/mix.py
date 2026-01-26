"""
Mix Phase: 混音（只编排与IO，调用 pipeline.processors.tts.mix_audio）
"""
import subprocess
from pathlib import Path
from typing import Dict, Optional

from pikppo.pipeline.core.phase import Phase
from pikppo.pipeline.core.types import Artifact, ErrorInfo, PhaseResult, RunContext
from pikppo.pipeline.processors.tts import mix_audio
from pikppo.utils.logger import info


class MixPhase(Phase):
    """混音 Phase。"""
    
    name = "mix"
    version = "1.0.0"
    
    def requires(self) -> list[str]:
        """需要 tts.audio 和 video（从 config 获取）。"""
        return ["tts.audio"]
    
    def provides(self) -> list[str]:
        """生成 mix.audio。"""
        return ["mix.audio"]
    
    def run(self, ctx: RunContext, inputs: Dict[str, Artifact]) -> PhaseResult:
        """
        执行 Mix Phase。
        
        流程：
        1. 读取 TTS 音频
        2. 混音（TTS + accompaniment，如果有）
        3. 输出混音后的音频
        """
        # 获取输入
        tts_audio_artifact = inputs["tts.audio"]
        tts_path = Path(ctx.workspace) / tts_audio_artifact.path
        
        if not tts_path.exists():
            return PhaseResult(
                status="failed",
                error=ErrorInfo(
                    type="FileNotFoundError",
                    message=f"TTS audio not found: {tts_path}",
                ),
            )
        
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
        
        workspace_path = Path(ctx.workspace)
        audio_dir = workspace_path / "audio"
        audio_dir.mkdir(parents=True, exist_ok=True)
        mix_path = audio_dir / "mix.wav"
        
        # 获取配置
        phase_config = ctx.config.get("phases", {}).get("mix", {})
        target_lufs = phase_config.get("target_lufs", ctx.config.get("dub_target_lufs", -16.0))
        true_peak = phase_config.get("true_peak", ctx.config.get("dub_true_peak", -1.0))
        
        # 检查是否有 accompaniment（可选）
        accompaniment_path = workspace_path / "audio" / "accompaniment.wav"
        if not accompaniment_path.exists():
            accompaniment_path = None
        
        try:
            # mix_audio 输出视频，我们需要先混音再提取音频
            if not mix_path.exists():
                temp_video = workspace_path / ".temp_mix.mp4"
                
                mix_audio(
                    str(tts_path),
                    str(accompaniment_path) if accompaniment_path else None,
                    video_path,
                    str(temp_video),
                    target_lufs=target_lufs,
                    true_peak=true_peak,
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
            
            # 返回 artifact
            return PhaseResult(
                status="succeeded",
                artifacts={
                    "mix.audio": Artifact(
                        key="mix.audio",
                        path="audio/mix.wav",
                        kind="wav",
                        fingerprint="",  # runner 会计算
                    ),
                },
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
