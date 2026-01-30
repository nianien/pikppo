"""
MT Phase: 机器翻译（只编排与IO，调用 models.openai.translate）
"""
import json
from pathlib import Path
from typing import Dict

from pikppo.pipeline.core.phase import Phase
from pikppo.pipeline.core.types import Artifact, ErrorInfo, PhaseResult, RunContext, ResolvedOutputs
from pikppo.pipeline.processors.mt import run as mt_run
from pikppo.config.settings import get_openai_api_key
from pikppo.utils.timecode import write_srt_from_segments
from pikppo.utils.logger import info


class MTPhase(Phase):
    """机器翻译 Phase。"""
    
    name = "mt"
    version = "1.0.0"
    
    def requires(self) -> list[str]:
        """需要 subs.subtitle_model（SSOT）。"""
        return ["subs.subtitle_model"]
    
    def provides(self) -> list[str]:
        """生成 translate.context, subs.en_srt。"""
        return ["translate.context", "subs.en_srt"]
    
    def run(
        self,
        ctx: RunContext,
        inputs: Dict[str, Artifact],
        outputs: ResolvedOutputs,
    ) -> PhaseResult:
        """
        执行 MT Phase。
        
        流程：
        1. 读取 subtitle.model.json（SSOT）
        2. Stage 1: 生成翻译上下文
        3. Stage 2: 翻译 cues
        4. 更新 Subtitle Model 的 target 字段
        5. 生成 en.srt
        """
        # 获取输入（Subtitle Model SSOT）
        subtitle_model_artifact = inputs["subs.subtitle_model"]
        subtitle_model_path = Path(ctx.workspace) / subtitle_model_artifact.relpath
        
        if not subtitle_model_path.exists():
            return PhaseResult(
                status="failed",
                error=ErrorInfo(
                    type="FileNotFoundError",
                    message=f"Subtitle Model file not found: {subtitle_model_path}",
                ),
            )
        
        # 读取 Subtitle Model
        with open(subtitle_model_path, "r", encoding="utf-8") as f:
            model_data = json.load(f)
        
        cues = model_data.get("cues", [])
        if not cues:
            return PhaseResult(
                status="failed",
                error=ErrorInfo(
                    type="ValueError",
                    message="No cues found in Subtitle Model",
                ),
            )
        
        # 从 cues 提取 segments（用于翻译）
        segments = []
        for cue in cues:
            segments.append({
                "id": cue.get("cue_id", ""),
                "start": cue.get("start_ms", 0) / 1000.0,  # 毫秒转秒
                "end": cue.get("end_ms", 0) / 1000.0,
                "text": cue.get("source", {}).get("text", ""),
                "speaker": cue.get("speaker", ""),
            })
        
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
        max_chars_per_line = phase_config.get("max_chars_per_line", 42)
        max_lines = phase_config.get("max_lines", 2)
        target_cps = phase_config.get("target_cps", "12-17")
        avoid_formal = phase_config.get("avoid_formal", True)
        profanity_policy = phase_config.get("profanity_policy", "soften")
        
        # 调用 Processor 层进行翻译（Stage 1 + Stage 2）
        try:
            result = mt_run(
                segments=segments,
                api_key=api_key,
                model=model,
                temperature=temperature,
                max_chars_per_line=max_chars_per_line,
                max_lines=max_lines,
                target_cps=target_cps,
                avoid_formal=avoid_formal,
                profanity_policy=profanity_policy,
            )
        except Exception as e:
            return PhaseResult(
                status="failed",
                error=ErrorInfo(
                    type=type(e).__name__,
                    message=str(e),
                ),
            )
        
        # 从 ProcessorResult 提取数据
        context = result.data["context"]
        en_texts = result.data["en_texts"]
        
        # 更新 Subtitle Model 的 target 字段
        for i, cue in enumerate(cues):
            if i < len(en_texts) and en_texts[i]:
                if "target" not in cue:
                    cue["target"] = {}
                cue["target"]["lang"] = "en"
                cue["target"]["text"] = en_texts[i]
        
        # 保存更新后的 Subtitle Model（回写 target）
        with open(subtitle_model_path, "w", encoding="utf-8") as f:
            json.dump(model_data, f, indent=2, ensure_ascii=False)
        info(f"Updated Subtitle Model with translations: {subtitle_model_path}")
        
        # 生成英文 segments（用于 SRT）
        en_segments = []
        for i, cue in enumerate(cues):
            en_seg = {
                "id": cue.get("cue_id", f"cue_{i+1:04d}"),
                "start": cue.get("start_ms", 0) / 1000.0,  # 毫秒转秒
                "end": cue.get("end_ms", 0) / 1000.0,
                "text": cue.get("source", {}).get("text", ""),  # 保留中文原文
                "en_text": en_texts[i] if i < len(en_texts) else "",
                "speaker": cue.get("speaker", ""),
            }
            en_segments.append(en_seg)
        
        # Phase 层负责文件 IO：写入到 runner 预分配的 outputs.paths
        # translate.context.json
        context_path = outputs.get("translate.context")
        context_path.parent.mkdir(parents=True, exist_ok=True)
        with open(context_path, "w", encoding="utf-8") as f:
            json.dump(context, f, indent=2, ensure_ascii=False)
        
        # subs.en.srt
        en_srt_path = outputs.get("subs.en_srt")
        write_srt_from_segments(en_segments, str(en_srt_path), text_key="en_text")
        
        # 返回 PhaseResult：只声明哪些 outputs 成功
        return PhaseResult(
            status="succeeded",
            outputs=[
                "translate.context",
                "subs.en_srt",
            ],
            metrics={
                "segments_count": len(segments),
                "translated_count": len([t for t in en_texts if t]),
            },
        )
