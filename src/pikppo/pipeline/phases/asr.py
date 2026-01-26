"""
ASR Phase: 语音识别（只编排与IO，调用 pipeline.processors.asr.transcribe 和 pipeline.processors.subtitle.generate_subtitles）
"""
import json
import os
from pathlib import Path
from typing import Dict

from pikppo.pipeline.core.phase import Phase
from pikppo.pipeline.core.types import Artifact, ErrorInfo, PhaseResult, RunContext
from pikppo.pipeline.processors.asr import transcribe
from pikppo.pipeline.processors.subtitle import generate_subtitles
from pikppo.infra.storage.tos import TosStorage
from pikppo.models.doubao import POSTPROFILES, speaker_aware_postprocess
from pikppo.utils.logger import info


class ASRPhase(Phase):
    """语音识别 Phase。"""
    
    name = "asr"
    version = "1.0.0"
    
    def requires(self) -> list[str]:
        """需要 demux.audio。"""
        return ["demux.audio"]
    
    def provides(self) -> list[str]:
        """生成 subs.zh_segments, subs.zh_srt, subs.asr_raw_response。"""
        return ["subs.zh_segments", "subs.zh_srt", "subs.asr_raw_response"]
    
    def run(self, ctx: RunContext, inputs: Dict[str, Artifact]) -> PhaseResult:
        """
        执行 ASR Phase。
        
        流程：
        1. 读取音频文件
        2. 上传到 TOS（如果需要）
        3. 调用 ASR
        4. 生成字幕
        """
        # 获取输入
        audio_artifact = inputs["demux.audio"]
        audio_path = Path(ctx.workspace) / audio_artifact.path
        
        if not audio_path.exists():
            return PhaseResult(
                status="failed",
                error=ErrorInfo(
                    type="FileNotFoundError",
                    message=f"Audio file not found: {audio_path}",
                ),
            )
        
        if audio_path.stat().st_size == 0:
            return PhaseResult(
                status="failed",
                error=ErrorInfo(
                    type="RuntimeError",
                    message=f"Audio file is empty: {audio_path}",
                ),
            )
        
        # 获取 episode stem
        workspace_path = Path(ctx.workspace)
        episode_stem = workspace_path.name
        
        # 获取配置
        phase_config = ctx.config.get("phases", {}).get("asr", {})
        preset = phase_config.get("preset", ctx.config.get("doubao_asr_preset", "asr_vad_spk"))
        postprofile = phase_config.get("postprofile", ctx.config.get("doubao_postprofile", "axis"))
        hotwords = phase_config.get("hotwords", ctx.config.get("doubao_hotwords"))
        
        info(f"ASR strategy: preset={preset}, postprofile={postprofile}")
        info(f"Audio file: {audio_path.name} (size: {audio_path.stat().st_size / 1024 / 1024:.2f} MB)")
        
        try:
            # 1. 获取音频 URL（上传到 TOS 如果需要）
            audio_url = ctx.config.get("doubao_audio_url")
            if not audio_url:
                # 如果是 URL 直接使用，否则上传到 TOS
                audio_path_str = str(audio_path)
                if audio_path_str.startswith(("http://", "https://")):
                    audio_url = audio_path_str
                else:
                    # 从 video_path 提取系列名
                    video_path = ctx.config.get("video_path", "")
                    series = None
                    if video_path:
                        video_path_obj = Path(video_path)
                        if len(video_path_obj.parts) >= 2:
                            parts = video_path_obj.parts
                            if "videos" in parts:
                                idx = parts.index("videos")
                                if idx + 1 < len(parts):
                                    series = parts[idx + 1]
                    
                    storage = TosStorage()
                    audio_url = storage.upload(audio_path, prefix=series)
            
            # 2. 调用 ASR
            raw_response, utterances = transcribe(
                audio_url=audio_url,
                preset=preset,
                hotwords=hotwords,
            )
            
            if not utterances:
                return PhaseResult(
                    status="failed",
                    error=ErrorInfo(
                        type="RuntimeError",
                        message="ASR produced no utterances",
                    ),
                )
            
            info(f"ASR succeeded ({len(utterances)} utterances)")
            
            # 3. 生成字幕
            result = generate_subtitles(
                utterances=utterances,
                postprocess_fn=speaker_aware_postprocess,
                postprofiles=POSTPROFILES,
                postprofile=postprofile,
                output_dir=workspace_path,
                video_stem=episode_stem,
                use_cache=False,  # Phase runner 会处理缓存
            )
            
            # 读取生成的 segments
            segments_path = Path(result["segments"])
            with open(segments_path, "r", encoding="utf-8") as f:
                segments = json.load(f)
            
            info(f"Generated subtitles ({len(segments)} segments)")
            
            # 4. 保存原始 ASR 响应
            subs_dir = workspace_path / "subs"
            subs_dir.mkdir(parents=True, exist_ok=True)
            raw_response_path = subs_dir / "asr-raw-response.json"
            
            with open(raw_response_path, "w", encoding="utf-8") as f:
                json.dump(raw_response, f, indent=2, ensure_ascii=False)
            
            info(f"Saved raw ASR response to: {raw_response_path}")
            
            # 返回 artifacts
            return PhaseResult(
                status="succeeded",
                artifacts={
                    "subs.zh_segments": Artifact(
                        key="subs.zh_segments",
                        path="subs/zh-segments.json",
                        kind="json",
                        fingerprint="",  # runner 会计算
                    ),
                    "subs.zh_srt": Artifact(
                        key="subs.zh_srt",
                        path="subs/zh.srt",
                        kind="srt",
                        fingerprint="",  # runner 会计算
                    ),
                    "subs.asr_raw_response": Artifact(
                        key="subs.asr_raw_response",
                        path="subs/asr-raw-response.json",
                        kind="json",
                        fingerprint="",  # runner 会计算
                    ),
                },
                metrics={
                    "utterances_count": len(utterances),
                    "segments_count": len(segments),
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
