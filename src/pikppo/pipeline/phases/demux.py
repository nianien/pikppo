"""
Demux Phase: 从视频提取音频（只编排与IO，调用 pipeline.processors.media.extract_raw_audio）
"""
from pathlib import Path
from typing import Dict

from pikppo.pipeline.core.phase import Phase
from pikppo.pipeline.core.types import Artifact, ErrorInfo, PhaseResult, RunContext
from pikppo.pipeline.processors.media import extract_raw_audio
from pikppo.utils.logger import info


class DemuxPhase(Phase):
    """音频提取 Phase。"""
    
    name = "demux"
    version = "1.0.0"
    
    def requires(self) -> list[str]:
        """需要 video 输入（从 RunContext 获取，不通过 manifest）。"""
        return []  # demux 是第一个 phase，不需要上游 artifact
    
    def provides(self) -> list[str]:
        """生成 demux.audio。"""
        return ["demux.audio"]
    
    def run(self, ctx: RunContext, inputs: Dict[str, Artifact]) -> PhaseResult:
        """
        执行 Demux Phase。
        
        从 RunContext 获取 video_path，提取音频。
        """
        # 从 config 获取 video_path
        video_path = ctx.config.get("video_path")
        if not video_path:
            return PhaseResult(
                status="failed",
                error=ErrorInfo(
                    type="ValueError",
                    message="video_path not found in config",
                ),
            )
        
        video_file = Path(video_path)
        if not video_file.exists():
            return PhaseResult(
                status="failed",
                error=ErrorInfo(
                    type="FileNotFoundError",
                    message=f"Video file not found: {video_path}",
                ),
            )
        
        if video_file.stat().st_size == 0:
            return PhaseResult(
                status="failed",
                error=ErrorInfo(
                    type="RuntimeError",
                    message=f"Video file is empty: {video_path}",
                ),
            )
        
        # 从 workspace 提取 episode stem（workspace 名称就是 episode stem）
        # 例如: videos/dbqsfy/dub/1/ -> episode_stem = "1"
        workspace_path = Path(ctx.workspace)
        episode_stem = workspace_path.name
        
        # 输出路径
        audio_dir = workspace_path / "audio"
        audio_dir.mkdir(parents=True, exist_ok=True)
        audio_path = audio_dir / f"{episode_stem}.wav"
        
        # 调用实现函数
        try:
            extract_raw_audio(str(video_path), str(audio_path))
        except Exception as e:
            return PhaseResult(
                status="failed",
                error=ErrorInfo(
                    type=type(e).__name__,
                    message=str(e),
                ),
            )
        
        # 验证输出文件
        if not audio_path.exists():
            return PhaseResult(
                status="failed",
                error=ErrorInfo(
                    type="RuntimeError",
                    message=f"Audio extraction failed: {audio_path} was not created",
                ),
            )
        
        if audio_path.stat().st_size == 0:
            return PhaseResult(
                status="failed",
                error=ErrorInfo(
                    type="RuntimeError",
                    message=f"Audio extraction failed: {audio_path} is empty",
                ),
            )
        
        info(f"Audio extracted: {audio_path.name} (size: {audio_path.stat().st_size / 1024 / 1024:.2f} MB)")
        
        # 返回 artifact
        return PhaseResult(
            status="succeeded",
            artifacts={
                "demux.audio": Artifact(
                    key="demux.audio",
                    path=f"audio/{episode_stem}.wav",
                    kind="wav",
                    fingerprint="",  # runner 会计算
                ),
            },
            metrics={
                "audio_size_mb": audio_path.stat().st_size / 1024 / 1024,
            },
        )
