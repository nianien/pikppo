"""
TTS Phase: 语音合成（只编排与IO，调用 pipeline.tts.assign_voices 和 pipeline.tts.synthesize_tts）
"""
import json
import shutil
from pathlib import Path
from typing import Dict

from video_remix.pipeline.core.phase import Phase
from video_remix.pipeline.core.types import Artifact, ErrorInfo, PhaseResult, RunContext
from video_remix.pipeline.tts import assign_voices, synthesize_tts
from video_remix.models.voice_pool import DEFAULT_VOICE_POOL
from video_remix.utils.logger import info


class TTSPhase(Phase):
    """语音合成 Phase。"""
    
    name = "tts"
    version = "1.0.0"
    
    def requires(self) -> list[str]:
        """需要 subs.en_segments 和 demux.audio（可选，用于声线分配）。"""
        return ["subs.en_segments", "demux.audio"]
    
    def provides(self) -> list[str]:
        """生成 tts.audio, tts.voice_assignment。"""
        return ["tts.audio", "tts.voice_assignment"]
    
    def run(self, ctx: RunContext, inputs: Dict[str, Artifact]) -> PhaseResult:
        """
        执行 TTS Phase。
        
        流程：
        1. 分配声线
        2. TTS 合成
        """
        # 获取输入
        en_segments_artifact = inputs["subs.en_segments"]
        en_segments_path = Path(ctx.workspace) / en_segments_artifact.path
        
        if not en_segments_path.exists():
            return PhaseResult(
                status="failed",
                error=ErrorInfo(
                    type="FileNotFoundError",
                    message=f"English segments not found: {en_segments_path}",
                ),
            )
        
        audio_artifact = inputs.get("demux.audio")
        audio_path = None
        if audio_artifact:
            audio_path = Path(ctx.workspace) / audio_artifact.path
        
        workspace_path = Path(ctx.workspace)
        episode_stem = workspace_path.name
        
        # 获取配置
        phase_config = ctx.config.get("phases", {}).get("tts", {})
        azure_key = phase_config.get("azure_key", ctx.config.get("azure_tts_key"))
        azure_region = phase_config.get("azure_region", ctx.config.get("azure_tts_region"))
        azure_language = phase_config.get("azure_language", ctx.config.get("azure_tts_language", "en-US"))
        max_workers = phase_config.get("max_workers", ctx.config.get("tts_max_workers", 4))
        voice_pool_path = phase_config.get("voice_pool_path", ctx.config.get("voice_pool_path"))
        
        if not azure_key or not azure_region:
            return PhaseResult(
                status="failed",
                error=ErrorInfo(
                    type="ValueError",
                    message="Azure TTS credentials not set (azure_key and azure_region required)",
                ),
            )
        
        try:
            # 1. 分配声线
            voice_assignment_path = workspace_path / "voice-assignment.json"
            
            if not voice_assignment_path.exists():
                temp_voices_dir = workspace_path / ".temp_voices"
                temp_voices_dir.mkdir(exist_ok=True)
                
                # 准备 voice pool
                if not voice_pool_path:
                    pool_file = temp_voices_dir / "voice_pool.json"
                    with open(pool_file, "w", encoding="utf-8") as f:
                        json.dump(DEFAULT_VOICE_POOL, f, indent=2, ensure_ascii=False)
                    voice_pool_path = str(pool_file)
                
                # 使用 zh_segments 进行声线分配（如果有）
                zh_segments_path = workspace_path / "subs" / "zh-segments.json"
                reference_audio = str(audio_path) if audio_path and audio_path.exists() else None
                
                assignment_path_temp = assign_voices(
                    str(zh_segments_path) if zh_segments_path.exists() else str(en_segments_path),
                    reference_audio,
                    voice_pool_path,
                    str(temp_voices_dir),
                )
                
                if Path(assignment_path_temp).exists():
                    shutil.move(assignment_path_temp, voice_assignment_path)
                
                if temp_voices_dir.exists():
                    shutil.rmtree(temp_voices_dir, ignore_errors=True)
            
            # 2. TTS 合成
            audio_dir = workspace_path / "audio"
            audio_dir.mkdir(parents=True, exist_ok=True)
            tts_path = audio_dir / "tts.wav"
            
            if not tts_path.exists():
                temp_tts_dir = workspace_path / ".temp_tts"
                temp_tts_dir.mkdir(exist_ok=True)
                
                tts_path_temp = synthesize_tts(
                    str(en_segments_path),
                    str(voice_assignment_path),
                    voice_pool_path,
                    str(temp_tts_dir),
                    azure_key=azure_key,
                    azure_region=azure_region,
                    language=azure_language,
                    max_workers=max_workers,
                )
                
                if Path(tts_path_temp).exists():
                    shutil.move(tts_path_temp, tts_path)
                
                if temp_tts_dir.exists():
                    shutil.rmtree(temp_tts_dir, ignore_errors=True)
            
            if not tts_path.exists():
                return PhaseResult(
                    status="failed",
                    error=ErrorInfo(
                        type="RuntimeError",
                        message=f"TTS synthesis failed: {tts_path} was not created",
                    ),
                )
            
            info(f"TTS synthesis completed: {tts_path.name}")
            
            # 返回 artifacts
            return PhaseResult(
                status="succeeded",
                artifacts={
                    "tts.audio": Artifact(
                        key="tts.audio",
                        path="audio/tts.wav",
                        kind="wav",
                        fingerprint="",  # runner 会计算
                    ),
                    "tts.voice_assignment": Artifact(
                        key="tts.voice_assignment",
                        path="voice-assignment.json",
                        kind="json",
                        fingerprint="",  # runner 会计算
                    ),
                },
                metrics={
                    "tts_audio_size_mb": tts_path.stat().st_size / 1024 / 1024,
                },
            )
            
        except Exception as e:
            return PhaseResult(
                status="failed",
                error=ErrorInfo(
                    type=type(e).__name__,
                    message=str(e),
                ),
            )
