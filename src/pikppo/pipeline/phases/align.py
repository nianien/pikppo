"""
Align Phase: 时间对齐与重断句（不调模型）

职责：
- 将 mt 输出的英文整段文本映射到 SSOT 的时间骨架
- 允许 utterance end 微延长
- 在 utterance 内重断句生成 segments[]
- 导出 en.srt
"""
import json
import re
from pathlib import Path
from typing import Dict, List, Optional

from pikppo.pipeline.core.phase import Phase
from pikppo.pipeline.core.types import Artifact, ErrorInfo, PhaseResult, RunContext, ResolvedOutputs
from pikppo.pipeline.processors.mt.utterance_translate import (
    estimate_en_duration_ms,
    calculate_extend_ms,
    resegment_utterance,
)
# NameMap 和 final_render_names 不再需要
# MT phase 已经输出纯英文（无占位符），模型负责翻译人名
from pikppo.utils.timecode import write_srt_from_segments
from pikppo.utils.logger import info, warning


# final_render_names 函数已移除
# MT phase 已经输出纯英文（无占位符），模型负责翻译人名
# 不再需要最终渲染阶段


class AlignPhase(Phase):
    """时间对齐与重断句 Phase（不调模型）。"""
    
    name = "align"
    version = "1.0.0"
    
    def requires(self) -> list[str]:
        """需要 subs.subtitle_model（SSOT）和 mt.mt_output。"""
        return ["subs.subtitle_model", "mt.mt_output"]
    
    def provides(self) -> list[str]:
        """生成 subs.subtitle_align, subs.en_srt。"""
        return ["subs.subtitle_align", "subs.en_srt"]
    
    def run(
        self,
        ctx: RunContext,
        inputs: Dict[str, Artifact],
        outputs: ResolvedOutputs,
    ) -> PhaseResult:
        """
        执行 Align Phase。
        
        流程：
        1. 读取 subtitle.model.json（SSOT）
        2. 读取 mt_output.jsonl（翻译结果）
        3. 对每个 utterance：
           - 计算 end 延长（如果需要）
           - 重断句（不跨 utterance 边界）
           - 生成对齐后的 cues（包含英文翻译）
        4. 生成 subtitle.align.json（格式与 SSOT 一致，包含英文翻译）和 en.srt
        """
        # 获取输入
        subtitle_model_artifact = inputs["subs.subtitle_model"]
        subtitle_model_path = Path(ctx.workspace) / subtitle_model_artifact.relpath
        
        mt_output_artifact = inputs["mt.mt_output"]
        mt_output_path = Path(ctx.workspace) / mt_output_artifact.relpath
        
        if not subtitle_model_path.exists():
            return PhaseResult(
                status="failed",
                error=ErrorInfo(
                    type="FileNotFoundError",
                    message=f"Subtitle Model file not found: {subtitle_model_path}",
                ),
            )
        
        if not mt_output_path.exists():
            return PhaseResult(
                status="failed",
                error=ErrorInfo(
                    type="FileNotFoundError",
                    message=f"MT output file not found: {mt_output_path}",
                ),
            )
        
        # 读取 Subtitle Model v1.2
        with open(subtitle_model_path, "r", encoding="utf-8") as f:
            model_data = json.load(f)
        
        utterances = model_data.get("utterances", [])
        
        if not utterances:
            return PhaseResult(
                status="failed",
                error=ErrorInfo(
                    type="ValueError",
                    message="No utterances found in Subtitle Model",
                ),
            )
        
        # 读取 mt_output.jsonl
        mt_output_map = {}
        with open(mt_output_path, "r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                mt_output = json.loads(line)
                utt_id = mt_output.get("utt_id", "")
                mt_output_map[utt_id] = mt_output
        
        if not mt_output_map:
            return PhaseResult(
                status="failed",
                error=ErrorInfo(
                    type="ValueError",
                    message="No translations found in mt_output.jsonl",
                ),
            )
        
        # 获取配置
        phase_config = ctx.config.get("phases", {}).get("align", {})
        max_extend_ms = int(phase_config.get("max_extend_ms", 200))  # 120-250ms 中间值
        safety_gap_ms = int(phase_config.get("safety_gap_ms", 60))
        
        # NameMap 和 Name Guard 不再需要（已移除 final_render_names 逻辑）
        # MT phase 已经输出纯英文（无占位符），模型负责翻译人名
        # name_map.json 现在放在视频目录的 dub 子目录下
        # 例如：videos/dbqsfy/1.mp4 → videos/dbqsfy/dub/name_map.json
        
        # 处理每个 utterance，生成对齐后的 Subtitle Model（包含英文翻译）
        aligned_utterances = []
        all_segments_for_srt = []  # 用于生成 en.srt
        total_extend_ms = 0
        need_retry_utts = []
        
        for i, utterance in enumerate(utterances):
            utt_id = utterance.get("utt_id", "")
            start_ms = utterance.get("start_ms", 0)
            end_ms_src = utterance.get("end_ms", 0)
            cues = utterance.get("cues", [])
            speaker = utterance.get("speaker", "")
            speech_rate = utterance.get("speech_rate", {})
            emotion = utterance.get("emotion")
            
            # 获取翻译结果
            mt_output = mt_output_map.get(utt_id)
            if not mt_output:
                warning(f"Translation not found for utterance {utt_id}, skipping")
                continue
            
            en_text = mt_output.get("target", {}).get("text", "")
            if not en_text:
                # 空翻译，跳过
                continue
            
            # 反作弊校验：确保输入没有占位符（防御性检查）
            if re.search(r"<<NAME_\d+", en_text):
                warning(
                    f"Align Phase: mt_output still contains NAME placeholder for utterance {utt_id}. "
                    f"This should not happen - MT phase should have produced clean English. "
                    f"Text: {en_text[:200]}"
                )
            
            # 获取预算和估算时长
            stats = mt_output.get("stats", {})
            budget_ms = stats.get("budget_ms", 0)
            en_est_ms = stats.get("en_est_ms", 0)
            
            # 计算 end 延长
            next_utterance = utterances[i + 1] if i + 1 < len(utterances) else None
            next_start_ms = next_utterance.get("start_ms") if next_utterance else None
            
            extend_ms = 0.0
            end_ms_final = end_ms_src
            
            if en_est_ms > budget_ms:
                # 需要额外时间
                need_ms = en_est_ms - budget_ms
                # 先计算不重叠的最大扩展
                no_overlap_cap_ms = None
                if next_start_ms is not None:
                    no_overlap_cap_ms = next_start_ms - end_ms_src - safety_gap_ms
                    if no_overlap_cap_ms < 0:
                        no_overlap_cap_ms = 0
                
                # 计算最终可扩展时间
                extend_ms = min(need_ms, max_extend_ms)
                if no_overlap_cap_ms is not None:
                    extend_ms = min(extend_ms, no_overlap_cap_ms)
                extend_ms = max(0.0, extend_ms)
                
                if extend_ms > 0:
                    end_ms_final = int(end_ms_src + extend_ms)
                    total_extend_ms += extend_ms
                else:
                    # 无法延长，标记需要重试
                    need_retry_utts.append({
                        "utt_id": utt_id,
                        "reason": "cannot_extend",
                        "need_ms": need_ms,
                        "en_est_ms": en_est_ms,
                        "budget_ms": budget_ms,
                    })
            
            # 检查延长后是否仍超限
            if en_est_ms > (budget_ms + extend_ms):
                # 延长后仍超限，标记需要重试
                need_retry_utts.append({
                    "utt_id": utt_id,
                    "reason": "still_too_long_after_extend",
                    "en_est_ms": en_est_ms,
                    "budget_ms": budget_ms,
                    "extend_ms": extend_ms,
                })
            
            # 重断句（不跨 utterance 边界）- 与 en.srt 生成逻辑一致
            segments = resegment_utterance(en_text, cues, end_ms_final)
            
            # 构建对齐后的 cues（包含英文翻译，格式与 SSOT 一致）
            aligned_cues = []
            for seg in segments:
                aligned_cues.append({
                    "start_ms": seg.get("start_ms", 0),
                    "end_ms": seg.get("end_ms", 0),
                    "source": {
                        "lang": "en",  # 英文翻译
                        "text": seg.get("text", ""),
                    },
                })
            
            # 构建对齐后的 utterance（格式与 SSOT 一致）
            aligned_utterance = {
                "utt_id": utt_id,
                "speaker": speaker,
                "start_ms": start_ms,
                "end_ms": end_ms_final,  # 使用延长后的时间
                "speech_rate": speech_rate,
                "emotion": emotion,
                "cues": aligned_cues,
            }
            aligned_utterances.append(aligned_utterance)
            
            # 收集所有 segments（用于生成 en.srt）
            for seg in segments:
                all_segments_for_srt.append({
                    "start": seg.get("start_ms", 0) / 1000.0,  # 毫秒转秒
                    "end": seg.get("end_ms", 0) / 1000.0,
                    "en_text": seg.get("text", ""),
                })
        
        # 如果有需要重试的 utterance，记录警告
        if need_retry_utts:
            warning(f"{len(need_retry_utts)} utterances need retry (run mt phase again with stronger compression)")
            for utt in need_retry_utts:
                warning(f"  {utt['utt_id']}: {utt['reason']}")
        
        # 生成 subtitle.align.json（格式与 SSOT 一致，包含英文翻译）
        subtitle_align_path = outputs.get("subs.subtitle_align")
        subtitle_align_path.parent.mkdir(parents=True, exist_ok=True)
        subtitle_align_dict = {
            "schema": {
                "name": "subtitle.align",
                "version": "1.3",
            },
            "audio": model_data.get("audio"),  # 继承原始 audio 元数据
            "utterances": aligned_utterances,
        }
        with open(subtitle_align_path, "w", encoding="utf-8") as f:
            json.dump(subtitle_align_dict, f, indent=2, ensure_ascii=False)
        info(f"Saved subtitle.align.json: {len(aligned_utterances)} utterances")
        
        # 从 subtitle.align.json 生成 en.srt（按 start_ms 排序）
        all_segments_for_srt.sort(key=lambda x: x["start"])
        
        # 清洗：丢弃空文本
        all_segments_for_srt = [seg for seg in all_segments_for_srt if seg.get("en_text", "").strip()]
        
        # 硬校验：确保最终输出没有占位符
        for seg in all_segments_for_srt:
            en_text = seg.get("en_text", "")
            remaining_placeholders = re.findall(r"<<NAME_\d+>>", en_text)
            if remaining_placeholders:
                raise AssertionError(
                    f"最终输出（en.srt）中仍存在占位符（这是不允许的）: {remaining_placeholders}. "
                    f"文本: {en_text[:200]}"
                )
        
        en_srt_path = outputs.get("subs.en_srt")
        write_srt_from_segments(all_segments_for_srt, str(en_srt_path), text_key="en_text")
        info(f"Saved en.srt: {len(all_segments_for_srt)} segments (所有占位符已替换)")
        
        # 返回 PhaseResult
        return PhaseResult(
            status="succeeded",
            outputs=[
                "subs.subtitle_align",
                "subs.en_srt",
            ],
            metrics={
                "utterances_count": len(utterances),
                "segments_count": len(all_segments_for_srt),
                "total_extend_ms": total_extend_ms,
                "need_retry_count": len(need_retry_utts),
            },
        )
