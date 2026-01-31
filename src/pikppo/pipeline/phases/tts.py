"""
TTS Phase: 语音合成（只编排与IO，调用 pipeline.processors.tts.assign_voices 和 pipeline.processors.tts.synthesize_tts）
"""
import json
import shutil
from pathlib import Path
from typing import Dict

from pikppo.pipeline.core.phase import Phase
from pikppo.pipeline.core.types import Artifact, ErrorInfo, PhaseResult, RunContext, ResolvedOutputs
from pikppo.pipeline.processors.tts import run as tts_run
from pikppo.models.voice_pool import DEFAULT_VOICE_POOL
from pikppo.utils.logger import info


class TTSPhase(Phase):
    """语音合成 Phase。"""
    
    name = "tts"
    version = "1.0.0"
    
    def requires(self) -> list[str]:
        """需要 subs.subtitle_align（对齐后的 SSOT，包含英文翻译）和 demux.audio（可选，用于声线分配）。"""
        return ["subs.subtitle_align", "demux.audio"]
    
    def provides(self) -> list[str]:
        """生成 tts.audio, tts.voice_assignment。"""
        return ["tts.audio", "tts.voice_assignment"]
    
    def run(
        self,
        ctx: RunContext,
        inputs: Dict[str, Artifact],
        outputs: ResolvedOutputs,
    ) -> PhaseResult:
        """
        执行 TTS Phase。
        
        流程：
        1. 从 Subtitle Model 读取 cues（包含 target 翻译）
        2. 分配声线
        3. TTS 合成
        """
        # 获取输入（对齐后的 Subtitle Model，包含英文翻译）
        subtitle_align_artifact = inputs.get("subs.subtitle_align")
        if not subtitle_align_artifact:
            return PhaseResult(
                status="failed",
                error=ErrorInfo(
                    type="ValueError",
                    message="subs.subtitle_align artifact not found. Make sure align phase completed successfully.",
                ),
            )
        
        subtitle_align_path = Path(ctx.workspace) / subtitle_align_artifact.relpath
        if not subtitle_align_path.exists():
            return PhaseResult(
                status="failed",
                error=ErrorInfo(
                    type="FileNotFoundError",
                    message=f"Subtitle align file not found: {subtitle_align_path}",
                ),
            )
        
        audio_artifact = inputs.get("demux.audio")
        audio_path = None
        if audio_artifact:
            audio_path = Path(ctx.workspace) / audio_artifact.relpath
        
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
            # 读取对齐后的 Subtitle Model（包含英文翻译）
            with open(subtitle_align_path, "r", encoding="utf-8") as f:
                subtitle_align_data = json.load(f)
            
            # 从 utterances 中提取所有 cues（包含英文翻译）
            utterances = subtitle_align_data.get("utterances", [])
            segments = []
            segment_index = 0  # 用于生成数字 ID（azure.py 需要整数 ID）
            
            for utt in utterances:
                utt_id = utt.get("utt_id", "")
                utt_speaker = utt.get("speaker", "")
                utt_emotion = utt.get("emotion")
                emotion_label = utt_emotion.get("label") if utt_emotion else None
                
                for cue_index, cue in enumerate(utt.get("cues", [])):
                    # 从 cue 的 source 获取英文翻译文本
                    source = cue.get("source", {})
                    en_text = source.get("text", "").strip()
                    
                    if not en_text:
                        continue  # 跳过空文本
                    
                    # 使用对齐后的时间
                    start_ms = cue.get("start_ms", 0)
                    end_ms = cue.get("end_ms", 0)
                    
                    segments.append({
                        "id": segment_index,  # 使用数字索引（azure.py 需要整数 ID 用于 :04d 格式化）
                        "start": start_ms / 1000.0,  # 毫秒转秒
                        "end": end_ms / 1000.0,
                        "text": en_text,  # 英文翻译文本
                        "speaker": utt_speaker,  # 使用 utterance 级别的 speaker
                        "emotion": emotion_label,  # 使用 utterance 级别的 emotion
                    })
                    segment_index += 1
            
            if not segments:
                return PhaseResult(
                    status="failed",
                    error=ErrorInfo(
                        type="ValueError",
                        message="No segments with translations found in subtitle.align.json.",
                    ),
                )
            
            # 准备 voice pool
            if not voice_pool_path:
                temp_voices_dir = workspace_path / ".temp_voices"
                temp_voices_dir.mkdir(exist_ok=True)
                pool_file = temp_voices_dir / "voice_pool.json"
                with open(pool_file, "w", encoding="utf-8") as f:
                    json.dump(DEFAULT_VOICE_POOL, f, indent=2, ensure_ascii=False)
                voice_pool_path = str(pool_file)
            
            # 调用 Processor 层（分配声线 + TTS 合成）
            temp_dir = str(workspace_path / ".temp_tts")
            Path(temp_dir).mkdir(exist_ok=True)
            
            result = tts_run(
                segments=segments,
                reference_audio_path=str(audio_path) if audio_path and audio_path.exists() else None,
                voice_pool_path=voice_pool_path,
                azure_key=azure_key,
                azure_region=azure_region,
                language=azure_language,
                max_workers=max_workers,
                temp_dir=temp_dir,
            )
            
            # 从 ProcessorResult 提取数据
            voice_assignment = result.data["voice_assignment"]
            audio_path_temp = result.data["audio_path"]
            
            # Phase 层负责文件 IO：移动到最终位置
            voice_assignment_path = workspace_path / "voice-assignment.json"
            with open(voice_assignment_path, "w", encoding="utf-8") as f:
                json.dump(voice_assignment, f, indent=2, ensure_ascii=False)
            
            audio_dir = workspace_path / "audio"
            audio_dir.mkdir(parents=True, exist_ok=True)
            tts_path = audio_dir / "tts.wav"
            
            if Path(audio_path_temp).exists():
                shutil.move(audio_path_temp, tts_path)
            
            # 清理临时目录
            if Path(temp_dir).exists():
                shutil.rmtree(temp_dir, ignore_errors=True)
            
            if not tts_path.exists():
                return PhaseResult(
                    status="failed",
                    error=ErrorInfo(
                        type="RuntimeError",
                        message=f"TTS synthesis failed: {tts_path} was not created",
                    ),
                )
            
            info(f"TTS synthesis completed: {tts_path.name}")
            
            # 返回 PhaseResult：只声明哪些 outputs 成功
            return PhaseResult(
                status="succeeded",
                outputs=[
                    "tts.audio",
                    "tts.voice_assignment",
                ],
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
