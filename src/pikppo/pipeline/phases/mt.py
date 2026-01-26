"""
MT Phase: 机器翻译（只编排与IO，调用 models.openai.translate）
"""
import json
from pathlib import Path
from typing import Dict

from pikppo.pipeline.core.phase import Phase
from pikppo.pipeline.core.types import Artifact, PhaseResult, RunContext
from pikppo.models.openai import build_translation_context, translate_segments
from pikppo.config.settings import get_openai_api_key
from pikppo.utils.timecode import write_srt_from_segments
from pikppo.utils.logger import info


class MTPhase(Phase):
    """机器翻译 Phase。"""
    
    name = "mt"
    version = "1.0.0"
    
    def requires(self) -> list[str]:
        """需要 subs.zh_segments。"""
        return ["subs.zh_segments"]
    
    def provides(self) -> list[str]:
        """生成 translate.context, subs.en_segments, subs.en_srt。"""
        return ["translate.context", "subs.en_segments", "subs.en_srt"]
    
    def run(self, ctx: RunContext, inputs: Dict[str, Artifact]) -> PhaseResult:
        """
        执行 MT Phase。
        
        流程：
        1. 读取 zh_segments.json
        2. Stage 1: 生成翻译上下文
        3. Stage 2: 翻译 segments
        4. 生成 en_segments.json 和 en.srt
        """
        # 获取输入
        zh_segments_artifact = inputs["subs.zh_segments"]
        zh_segments_path = Path(ctx.workspace) / zh_segments_artifact.path
        
        if not zh_segments_path.exists():
            return PhaseResult(
                status="failed",
                error=ErrorInfo(
                    type="FileNotFoundError",
                    message=f"zh_segments file not found: {zh_segments_path}",
                ),
            )
        
        # 读取 segments
        with open(zh_segments_path, "r", encoding="utf-8") as f:
            segments = json.load(f)
        
        if not segments:
            return PhaseResult(
                status="failed",
                error=ErrorInfo(
                    type="ValueError",
                    message="No segments found in zh_segments.json",
                ),
            )
        
        # 获取 API key
        api_key = get_openai_api_key()
        if not api_key:
            return PhaseResult(
                status="failed",
                error=ErrorInfo(
                    type="RuntimeError",
                    message="OpenAI API key not found. Please set OPENAI_API_KEY environment variable.",
                ),
            )
        
        # 获取配置
        phase_config = ctx.config.get("phases", {}).get("mt", {})
        model = phase_config.get("model", ctx.config.get("openai_model", "gpt-4o-mini"))
        temperature = phase_config.get("temperature", ctx.config.get("openai_temperature", 0.3))
        
        # Stage 1: 生成翻译上下文
        info("Stage 1: Building translation context...")
        zh_episode_text = "\n".join([
            seg.get("text", "").strip()
            for seg in segments
            if seg.get("text", "").strip()
        ])
        
        if not zh_episode_text:
            return PhaseResult(
                status="failed",
                error=ErrorInfo(
                    type="ValueError",
                    message="No text found in segments",
                ),
            )
        
        try:
            context = build_translation_context(
                zh_episode_text=zh_episode_text,
                api_key=api_key,
                model=model,
                temperature=temperature,
            )
        except Exception as e:
            return PhaseResult(
                status="failed",
                error=ErrorInfo(
                    type=type(e).__name__,
                    message=str(e),
                ),
            )
        
        # Stage 2: 翻译 segments
        info("Stage 2: Translating segments...")
        try:
            en_texts = translate_segments(
                segments=segments,
                context=context,
                api_key=api_key,
                model=model,
                temperature=temperature,
                use_tag_alignment=True,
            )
        except Exception as e:
            return PhaseResult(
                status="failed",
                error=ErrorInfo(
                    type=type(e).__name__,
                    message=str(e),
                ),
            )
        
        # 生成英文 segments
        en_segments = []
        for i, seg in enumerate(segments):
            en_seg = {
                "id": seg.get("id", i),
                "start": seg.get("start", 0.0),
                "end": seg.get("end", 0.0),
                "text": seg.get("text", ""),  # 保留中文原文
                "en_text": en_texts[i] if i < len(en_texts) else "",
                "speaker": seg.get("speaker", "speaker_0"),
            }
            en_segments.append(en_seg)
        
        # 写入临时文件（runner 会统一 publish）
        workspace_path = Path(ctx.workspace)
        workspace_path.mkdir(parents=True, exist_ok=True)
        
        # translate.context.json
        context_path = workspace_path / "subs" / "translation-context.json"
        context_path.parent.mkdir(parents=True, exist_ok=True)
        with open(context_path, "w", encoding="utf-8") as f:
            json.dump(context, f, indent=2, ensure_ascii=False)
        
        # subs.en_segments.json
        en_segments_path = workspace_path / "subs" / "en-segments.json"
        with open(en_segments_path, "w", encoding="utf-8") as f:
            json.dump(en_segments, f, indent=2, ensure_ascii=False)
        
        # subs.en.srt
        en_srt_path = workspace_path / "subs" / "en.srt"
        write_srt_from_segments(en_segments, str(en_srt_path), text_key="en_text")
        
        # 返回 artifacts（相对路径）
        return PhaseResult(
            status="succeeded",
            artifacts={
                "translate.context": Artifact(
                    key="translate.context",
                    path="subs/translation-context.json",
                    kind="json",
                    fingerprint="",  # runner 会计算
                ),
                "subs.en_segments": Artifact(
                    key="subs.en_segments",
                    path="subs/en-segments.json",
                    kind="json",
                    fingerprint="",  # runner 会计算
                ),
                "subs.en_srt": Artifact(
                    key="subs.en_srt",
                    path="subs/en.srt",
                    kind="srt",
                    fingerprint="",  # runner 会计算
                ),
            },
            metrics={
                "segments_count": len(segments),
                "translated_count": len([t for t in en_texts if t]),
            },
        )
