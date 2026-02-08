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
        """生成 tts.audio, tts.voice_assignment, tts.sentence（可选，仅 VolcEngine）。"""
        return ["tts.audio", "tts.voice_assignment", "tts.sentence"]
    
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
        
        # TTS 引擎选择（默认 volcengine）
        engine = phase_config.get("engine", ctx.config.get("tts_engine", "volcengine"))
        info(f"TTS engine: {engine}")
        
        # Azure 配置
        azure_key = phase_config.get("azure_key", ctx.config.get("azure_tts_key"))
        azure_region = phase_config.get("azure_region", ctx.config.get("azure_tts_region"))
        azure_language = phase_config.get("azure_language", ctx.config.get("azure_tts_language", "en-US"))
        
        # VolcEngine 配置（支持从环境变量读取）
        import os
        volcengine_app_id = (
            phase_config.get("volcengine_app_id") or
            ctx.config.get("volcengine_app_id") or
            os.environ.get("DOUBAO_APPID") or
            os.environ.get("VOLC_APP_ID")
        )
        volcengine_access_key = (
            phase_config.get("volcengine_access_key") or
            ctx.config.get("volcengine_access_key") or
            os.environ.get("DOUBAO_ACCESS_TOKEN") or
            os.environ.get("VOLC_ACCESS_KEY")
        )
        volcengine_resource_id = phase_config.get("volcengine_resource_id", ctx.config.get("volcengine_resource_id", "seed-tts-1.0"))
        volcengine_format = phase_config.get("volcengine_format", ctx.config.get("volcengine_format", "pcm"))
        volcengine_sample_rate = phase_config.get("volcengine_sample_rate", ctx.config.get("volcengine_sample_rate", 24000))
        # 根据 resource_id 自动判断使用 timestamp 还是 subtitle
        # TTS1.0/ICL1.0 使用 enable_timestamp，TTS2.0/ICL2.0 使用 enable_subtitle
        volcengine_enable_timestamp = phase_config.get("volcengine_enable_timestamp", ctx.config.get("volcengine_enable_timestamp", False))
        volcengine_enable_subtitle = phase_config.get("volcengine_enable_subtitle", ctx.config.get("volcengine_enable_subtitle", False))
        
        # 如果都没有设置，根据 resource_id 自动判断
        if not volcengine_enable_timestamp and not volcengine_enable_subtitle:
            if "2.0" in volcengine_resource_id:
                volcengine_enable_subtitle = True
            elif "1.0" in volcengine_resource_id or volcengine_resource_id == "seed-tts-1.0":
                volcengine_enable_timestamp = True
        
        # 通用配置
        max_workers = phase_config.get("max_workers", ctx.config.get("tts_max_workers", 4))
        voice_pool_path = phase_config.get("voice_pool_path", ctx.config.get("voice_pool_path"))
        
        # 验证引擎配置
        if engine == "azure":
            if not azure_key or not azure_region:
                return PhaseResult(
                    status="failed",
                    error=ErrorInfo(
                        type="ValueError",
                        message="Azure TTS credentials not set (azure_key and azure_region required)",
                    ),
                )
        elif engine == "volcengine":
            if not volcengine_app_id or not volcengine_access_key:
                return PhaseResult(
                    status="failed",
                    error=ErrorInfo(
                        type="ValueError",
                        message="VolcEngine TTS credentials not set (volcengine_app_id and volcengine_access_key required). "
                                "You can set them via environment variables: DOUBAO_APPID and DOUBAO_ACCESS_TOKEN, "
                                "or in config: phases.tts.volcengine_app_id and phases.tts.volcengine_access_key",
                    ),
                )
        else:
            return PhaseResult(
                status="failed",
                error=ErrorInfo(
                    type="ValueError",
                    message=f"Unknown TTS engine: {engine}. Supported engines: 'azure', 'volcengine'",
                ),
            )
        
        try:
            # 读取对齐后的 Subtitle Model（包含英文翻译）
            with open(subtitle_align_path, "r", encoding="utf-8") as f:
                subtitle_align_data = json.load(f)
            
            # 从 utterances 中提取数据（按 utterance 维度合成，保持 cues 逻辑不变）
            utterances = subtitle_align_data.get("utterances", [])
            segments = []
            segment_index = 0  # 用于生成数字 ID（azure.py 需要整数 ID）
            
            for utt in utterances:
                utt_id = utt.get("utt_id", "")
                utt_speaker = utt.get("speaker", "")
                utt_emotion = utt.get("emotion")
                emotion_label = utt_emotion.get("label") if utt_emotion else None
                
                # 直接从 utterance 的 text 字段获取完整英文文本（用于 TTS 合成）
                en_text = utt.get("text", "").strip()
                
                if not en_text:
                    continue  # 跳过空文本的 utterance
                
                # 使用 utterance 的时间（而不是 cue 的时间）
                start_ms = utt.get("start_ms", 0)
                end_ms = utt.get("end_ms", 0)
                
                segments.append({
                    "id": segment_index,  # 使用数字索引（azure.py 需要整数 ID 用于 :04d 格式化）
                    "start": start_ms / 1000.0,  # 毫秒转秒
                    "end": end_ms / 1000.0,
                    "text": en_text,  # utterance 维度的完整英文文本
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
            temp_dir = str(workspace_path / ".temp" / "tts")
            Path(temp_dir).mkdir(parents=True, exist_ok=True)
            
            # 根据引擎选择参数
            if engine == "azure":
                result = tts_run(
                    segments=segments,
                    reference_audio_path=str(audio_path) if audio_path and audio_path.exists() else None,
                    voice_pool_path=voice_pool_path,
                    engine=engine,
                    azure_key=azure_key,
                    azure_region=azure_region,
                    language=azure_language,
                    max_workers=max_workers,
                    temp_dir=temp_dir,
                )
            elif engine == "volcengine":
                result = tts_run(
                    segments=segments,
                    reference_audio_path=str(audio_path) if audio_path and audio_path.exists() else None,
                    voice_pool_path=voice_pool_path,
                    engine=engine,
                    volcengine_app_id=volcengine_app_id,
                    volcengine_access_key=volcengine_access_key,
                    volcengine_resource_id=volcengine_resource_id,
                    volcengine_format=volcengine_format,
                    volcengine_sample_rate=volcengine_sample_rate,
                    volcengine_enable_timestamp=volcengine_enable_timestamp,
                    volcengine_enable_subtitle=volcengine_enable_subtitle,
                    language=azure_language,  # 使用相同的 language 参数
                    max_workers=max_workers,
                    temp_dir=temp_dir,
                )
            else:
                raise ValueError(f"Unknown TTS engine: {engine}")
            
            # 从 ProcessorResult 提取数据
            voice_assignment = result.data["voice_assignment"]
            audio_path_temp = result.data["audio_path"]
            sentences = result.data.get("sentences", [])  # sentence 数据（仅 VolcEngine）
            
            # Phase 层负责文件 IO：移动到最终位置
            voice_assignment_path = workspace_path / "voice-assignment.json"
            with open(voice_assignment_path, "w", encoding="utf-8") as f:
                json.dump(voice_assignment, f, indent=2, ensure_ascii=False)
            
            # 使用预分配的输出路径
            tts_path = outputs.get("tts.audio")
            tts_path.parent.mkdir(parents=True, exist_ok=True)
            
            if Path(audio_path_temp).exists():
                shutil.move(audio_path_temp, tts_path)
            
            # 保存 sentence 数据（如果存在）
            outputs_list = ["tts.audio", "tts.voice_assignment"]
            if sentences:
                sentence_path = outputs.get("tts.sentence")
                if sentence_path:
                    sentence_path.parent.mkdir(parents=True, exist_ok=True)
                    with open(sentence_path, "w", encoding="utf-8") as f:
                        json.dump(sentences, f, indent=2, ensure_ascii=False)
                    outputs_list.append("tts.sentence")
                    info(f"Saved TTS sentence data: {len(sentences)} segments")
            
            # 清理临时目录（.temp/tts 下的临时文件，但保留引擎子目录）
            temp_path = Path(temp_dir)
            if temp_path.exists():
                # 只删除临时文件（如 concat_list.txt, gap_*.wav 等）
                # 但保留 tts_en.wav 和引擎子目录（azure/volcengine，包含 segments）
                for item in temp_path.iterdir():
                    if item.is_file() and item.name not in ["tts_en.wav"]:
                        item.unlink(missing_ok=True)
                    elif item.is_dir() and item.name not in ["azure", "volcengine"]:
                        shutil.rmtree(item, ignore_errors=True)
            
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
                outputs=outputs_list,
                metrics={
                    "tts_audio_size_mb": tts_path.stat().st_size / 1024 / 1024,
                    "sentences_count": len(sentences) if sentences else 0,
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
