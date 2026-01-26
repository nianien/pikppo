"""
SRT Phase: 字幕后处理（从 ASR IR 生成字幕）

职责：
- 读取 ASR IR（asr.result，Utterance[]）
- 应用后处理策略（切句、speaker 处理等）
- 生成字幕文件（subs.zh_segments, subs.zh_srt）

不负责：
- ASR 识别（由 ASR Phase 负责）
- 翻译（由 MT Phase 负责）

架构原则：
- 依赖 IR（asr.result），不依赖 raw
- raw 是日志/证据，不是接口契约
"""
import json
from pathlib import Path
from typing import Dict

from pikppo.pipeline.core.phase import Phase
from pikppo.pipeline.core.types import Artifact, ErrorInfo, PhaseResult, RunContext
from pikppo.pipeline.processors.subtitle import generate_subtitles, speaker_aware_postprocess, POSTPROFILES
from pikppo.utils.logger import info


class SubtitlePhase(Phase):
    """字幕后处理 Phase。"""
    
    name = "srt"
    version = "1.0.0"
    
    def requires(self) -> list[str]:
        """需要 asr.result（IR：Utterance[]）。"""
        return ["asr.result"]
    
    def provides(self) -> list[str]:
        """生成 subs.zh_segments, subs.zh_srt。"""
        return ["subs.zh_segments", "subs.zh_srt"]
    
    def run(self, ctx: RunContext, inputs: Dict[str, Artifact]) -> PhaseResult:
        """
        执行 Subtitle Phase。
        
        流程：
        1. 读取 ASR IR（asr.result）
        2. 反序列化为 Utterance[]
        3. 应用后处理策略生成字幕
        4. 生成 zh_segments.json 和 zh.srt
        """
        # 获取输入（IR）
        asr_result_artifact = inputs["asr.result"]
        asr_result_path = Path(ctx.workspace) / asr_result_artifact.path
        
        if not asr_result_path.exists():
            return PhaseResult(
                status="failed",
                error=ErrorInfo(
                    type="FileNotFoundError",
                    message=f"ASR result file not found: {asr_result_path}",
                ),
            )
        
        # 读取 ASR IR
        with open(asr_result_path, "r", encoding="utf-8") as f:
            result_data = json.load(f)
        
        # 反序列化为 Utterance[]
        try:
            from pikppo.schema import Utterance, Word
            
            utterances = []
            for utt_data in result_data.get("utterances", []):
                words = None
                if utt_data.get("words"):
                    words = [
                        Word(
                            start_ms=w["start_ms"],
                            end_ms=w["end_ms"],
                            text=w["text"],
                            speaker=w.get("speaker", ""),
                        )
                        for w in utt_data["words"]
                    ]
                
                utterances.append(Utterance(
                    speaker=utt_data["speaker"],
                    start_ms=utt_data["start_ms"],
                    end_ms=utt_data["end_ms"],
                    text=utt_data["text"],
                    words=words,
                ))
        except Exception as e:
            return PhaseResult(
                status="failed",
                error=ErrorInfo(
                    type="ParseError",
                    message=f"Failed to deserialize ASR result: {e}",
                ),
            )
        
        if not utterances:
            return PhaseResult(
                status="failed",
                error=ErrorInfo(
                    type="ValueError",
                    message="ASR result contains no utterances",
                ),
            )
        
        info(f"Loaded {len(utterances)} utterances from ASR IR")
        
        # 获取配置
        workspace_path = Path(ctx.workspace)
        episode_stem = workspace_path.name
        
        phase_config = ctx.config.get("phases", {}).get("srt", {})
        postprofile = phase_config.get("postprofile", ctx.config.get("doubao_postprofile", "axis"))
        
        info(f"Subtitle strategy: postprofile={postprofile}")
        
        try:
            # 生成字幕
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
