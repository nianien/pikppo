"""
基于 SSOT utterance 粒度的 MT 实现

核心原则：
1. 按照 SSOT 中 utterance 粒度进行翻译，保证 utterance 的时间窗口不变
2. 翻译时，根据 utterance 的语速 * 系数 k，控制翻译长度
3. 如果英文长度超限，则可以扩展 utterance 的 end_time（120-250ms，不重叠）
4. 如果不满足长度限制，则重新翻译
5. 翻译完成后，在 utterance 时间窗口内允许语义重断句

工程指标：
- 语速分档：fast (≥5.5 tps, k=1.0), normal (4.0-5.5, k=1.15), slow (<4.0, k=1.2)
- 英文时长估计：en_cps = 14（字符/秒）
- end_time 扩展上限：120-250ms（默认 200ms）
- 安全间隔：60ms（防止与下一句重叠）
"""
import re
from typing import Any, Callable, Dict, List, Optional, Tuple

from pikppo.utils.logger import info, warning


# 语速分档阈值（可配置）
SPEECH_RATE_FAST_THRESHOLD = 5.5  # ≥5.5 tps 为 fast
SPEECH_RATE_NORMAL_THRESHOLD = 4.0  # 4.0-5.5 为 normal，<4.0 为 slow

# k 值（语速系数）
K_FAST = 1.0
K_NORMAL = 1.15
K_SLOW = 1.2

# 英文时长估计参数
EN_CPS = 14.0  # 英文字符/秒（不含空格）

# end_time 扩展参数
EXTEND_CAP_MS = 200  # 扩展上限（120-250ms 中间值）
SAFETY_GAP_MS = 60  # 安全间隔（防止重叠）

# 重翻译最大次数
MAX_RETRIES = 3


def pick_k(zh_tps: float) -> float:
    """
    根据语速选择 k 值。
    
    Args:
        zh_tps: 中文 tokens per second
    
    Returns:
        k 值（1.0 / 1.15 / 1.2）
    """
    if zh_tps >= SPEECH_RATE_FAST_THRESHOLD:
        return K_FAST  # 语速过快
    elif zh_tps >= SPEECH_RATE_NORMAL_THRESHOLD:
        return K_NORMAL  # 正常
    else:
        return K_SLOW  # 偏慢


def estimate_en_duration_ms(en_text: str) -> float:
    """
    估计英文文本的时长（毫秒）。
    
    使用字符速（CPS）估计，不含空格。
    
    Args:
        en_text: 英文文本
    
    Returns:
        预计时长（毫秒）
    """
    # 只计算字母和数字（不含空格和标点）
    en_chars = len(re.sub(r'[^a-zA-Z0-9]', '', en_text))
    if en_chars == 0:
        return 0.0
    
    # 使用 CPS 估计
    en_est_sec = en_chars / EN_CPS
    en_est_ms = en_est_sec * 1000.0
    
    return en_est_ms


def calculate_extend_ms(
    need_ms: float,
    end_ms: int,
    next_utt_start_ms: Optional[int],
) -> float:
    """
    计算可扩展的时间（不重叠）。
    
    Args:
        need_ms: 需要额外的时间（毫秒）
        end_ms: 当前 utterance 的结束时间（毫秒）
        next_utt_start_ms: 下一个 utterance 的开始时间（毫秒，None 表示没有下一句）
    
    Returns:
        可扩展的时间（毫秒，0 表示无法扩展）
    """
    # 扩展上限
    extend_cap_ms = EXTEND_CAP_MS
    
    # 计算不与下一句重叠的最大扩展时间
    if next_utt_start_ms is not None:
        no_overlap_cap_ms = next_utt_start_ms - end_ms - SAFETY_GAP_MS
        if no_overlap_cap_ms < 0:
            return 0.0  # 无法扩展（会重叠）
        extend_cap_ms = min(extend_cap_ms, no_overlap_cap_ms)
    
    # 最终可扩展时间
    extend_ms = min(need_ms, extend_cap_ms)
    return max(0.0, extend_ms)


def build_utterance_translation_prompt(
    zh_text: str,
    budget_ms: float,
    retry_level: int = 0,
    *,
    episode_context: str = "",
    plot_overview: str = "",
    slang_glossary_text: str = "",
    is_gemini: bool = False,
) -> str:
    """
    构建 utterance 翻译 Prompt。
    
    Args:
        zh_text: 中文文本（utterance 内所有 cues 合并）
        budget_ms: 时间预算（毫秒）
        retry_level: 重试级别（0=首次，1=压缩，2=更强压缩）
        episode_context: 整集对话上下文（从 asr.result.text 获取）
        plot_overview: 剧情简介（可选）
        slang_glossary_text: 行话词表文本（从 DictLoader 获取）
    
    Returns:
        Prompt 字符串
    """
    budget_sec = budget_ms / 1000.0
    max_chars = int((budget_ms / 1000.0) * EN_CPS)
    
    # Slang glossary（从 DictLoader 传入）
    slang_glossary = slang_glossary_text
    
    if retry_level == 0:
        # 首次翻译
        # System prompt（硬规则）
        system_parts = [
            "You are a professional subtitle translator for a crime drama.",
            "",
            "Rules:",
            "1) The input may contain <<NAME_i:...>> which is a Chinese personal name.",
            "   Translate the name into English (pinyin or surname-based). Do NOT invent Western names.",
            "   Do NOT translate name meanings.",
            "2) Translate naturally. Do NOT translate word by word.",
            "3) This dialogue includes gambling / card-game slang. Use natural English equivalents.",
            "4) Output must be clean English for subtitles:",
            "   - Remove all <<NAME_i:...>> placeholders (render the translated name).",
            "   - Remove <sep> separators (use punctuation/pauses naturally).",
            "Return ONLY the final English text.",
        ]
        
        # Glossary（必须遵守的术语表）
        if slang_glossary_text:
            system_parts.append("")
            system_parts.append("Glossary (MUST follow EXACTLY if these phrases appear):")
            system_parts.append(slang_glossary_text)
        
        # User prompt（上下文 + 当前句）
        user_parts = []
        
        # 1. 剧情简介（可选）
        if plot_overview:
            user_parts.append(f"Plot overview:\n{plot_overview}\n")
        
        # 2. Episode Context
        if episode_context:
            # 截断到合理长度（避免 token 超限）
            max_context_chars = 5000  # 约 1000-1500 tokens
            if len(episode_context) > max_context_chars:
                episode_context = episode_context[:max_context_chars] + "..."
            user_parts.append(f"Episode dialogue context:\n{episode_context}\n")
        
        # 3. Domain Hint
        user_parts.append("Context: This dialogue includes gambling and card-game slang. Use natural English equivalents.")
        
        # 4. Focus：当前 utterance
        user_parts.append(f"\nConstraints:")
        user_parts.append(f"- This subtitle will be displayed for {budget_sec:.2f} seconds.")
        user_parts.append(f"- Maximum allowed length: approximately {max_chars} English characters (including spaces).")
        user_parts.append(f"- The translation must be natural, concise, and readable.")
        user_parts.append(f"- Do NOT add explanations or notes.")
        user_parts.append(f"- Do NOT exceed the maximum length.")
        user_parts.append("")
        user_parts.append(f"Translate ONLY this utterance into natural English for subtitles:")
        user_parts.append(f'"{zh_text}"')
        
        # 组合 prompt
        prompt = "\n".join(system_parts) + "\n\n" + "\n".join(user_parts)
    elif retry_level == 1:
        # 第一次压缩
        prompt = f"""Shorten the following English subtitle to fit within {budget_sec:.2f} seconds (approximately {max_chars} characters),
while keeping the core meaning.

Important: If the text contains <<NAME_x:...>> placeholders, translate them to English names.
Do NOT keep any <<NAME_x>> or <<NAME_x:...>> in the output.

About <sep> markers (if present):
- <sep> indicates a light pause between phrases.
- Translate naturally and keep the meaning.

Subtitle:
"{zh_text}"

Output ONLY the shortened English subtitle text (with all names translated, no placeholders)."""
    else:
        # 更强压缩（允许省略语气词/重复信息）
        prompt = f"""Make the following English subtitle much shorter to fit within {budget_sec:.2f} seconds (approximately {max_chars} characters).
You may omit filler words, repetitions, or minor details, but keep the core meaning.

Important: If the text contains <<NAME_x:...>> placeholders, translate them to English names.
Do NOT keep any <<NAME_x>> or <<NAME_x:...>> in the output.

About <sep> markers (if present):
- <sep> indicates a light pause between phrases.
- Translate naturally and keep the meaning.

Subtitle:
"{zh_text}"

Output ONLY the shortened English subtitle text (with all names translated, no placeholders)."""
    
    return prompt


def translate_utterance_with_retry(
    zh_text: str,
    budget_ms: float,
    translate_fn: Callable[[str], str],
    max_retries: int = MAX_RETRIES,
    *,
    episode_context: str = "",
    plot_overview: str = "",
    slang_glossary_text: str = "",
    dict_loader: Optional['DictLoader'] = None,  # 用于校验
    is_retry: bool = False,  # 是否为重试
    violations: Optional[List[str]] = None,  # 违反的术语列表
    is_gemini: bool = False,  # 是否为 Gemini 模型
) -> Tuple[str, int]:
    """
    翻译 utterance（带重试）。
    
    Args:
        zh_text: 中文文本
        budget_ms: 时间预算（毫秒）
        translate_fn: 翻译函数
        max_retries: 最大重试次数
        episode_context: 整集对话上下文
        plot_overview: 剧情简介
        slang_glossary_text: 行话词表文本
    
    Returns:
        (翻译结果, 重试次数)
    """
    for retry in range(max_retries):
        # 如果是重试（glossary 违反），使用更严格的 prompt
        if is_retry and violations:
            # 构建重试 prompt（追加违反提示）
            prompt = build_utterance_translation_prompt(
                zh_text, budget_ms, retry_level=0,  # 使用首次 prompt
                episode_context=episode_context,
                plot_overview=plot_overview,
                slang_glossary_text=slang_glossary_text,
                is_gemini=is_gemini,
            )
            # 追加违反提示
            prompt += "\n\nIMPORTANT: You violated the glossary. The following mappings were not followed:\n"
            for violation in violations:
                prompt += f"- {violation}\n"
            prompt += "\nRe-translate and strictly follow the glossary mappings above."
        else:
            prompt = build_utterance_translation_prompt(
                zh_text, budget_ms, retry_level=retry,
                episode_context=episode_context,
                plot_overview=plot_overview,
                slang_glossary_text=slang_glossary_text,
                is_gemini=is_gemini,
            )
        en_text = translate_fn(prompt)
        
        if not en_text:
            continue
        
        en_est_ms = estimate_en_duration_ms(en_text)
        if en_est_ms <= budget_ms:
            return en_text, retry
        
        # 超限，继续重试
        if retry < max_retries - 1:
            warning(
                f"Translation too long: {en_est_ms:.0f}ms > {budget_ms:.0f}ms, "
                f"retrying (attempt {retry + 2}/{max_retries})"
            )
    
    # 所有重试都失败，返回最后一次结果（即使超限）
    return en_text, max_retries - 1


def resegment_utterance(
    en_text: str,
    cues: List[Dict[str, Any]],
    end_ms_final: int,
) -> List[Dict[str, Any]]:
    """
    在 utterance 时间窗口内重断句（不跨 utterance 边界）。
    
    重要：
    - 确保单词完整性，不会将单词切分到不同 segment 中
    - 优先在英文标点处切分（由 <sep> 诱导产生的自然停顿结构）
    - <sep> 的作用：在翻译阶段诱导模型产生可切分结构（, . ? ! — 等）
    
    Args:
        en_text: 英文整句/整段（可能包含由 <sep> 诱导产生的标点）
        cues: 原始 cues（提供窗口骨架）
        end_ms_final: utterance 的最终结束时间（可能已扩展）
    
    Returns:
        segments[]（英文字幕段），每个包含：
        {
            "start_ms": int,
            "end_ms": int,
            "text": str,
            "cue_index": int,  # 对应原始 cue 在 utterance 内的索引（从 0 开始）
        }
    """
    if not cues:
        return []
    
    utt_start_ms = cues[0].get("start_ms", 0)
    utt_end_ms = end_ms_final
    total_ms = utt_end_ms - utt_start_ms
    
    if total_ms <= 0:
        return []
    
    # 如果只有一个 cue，直接返回
    if len(cues) == 1:
        return [{
            "start_ms": utt_start_ms,
            "end_ms": end_ms_final,
            "text": en_text,
            "cue_index": 0,  # 第一个（也是唯一一个）cue 的索引
        }]
    
    # 计算每个 cue 的窗口占比
    cue_windows = []
    total_cue_ms = 0
    for cue in cues:
        cue_start = cue.get("start_ms", 0)
        cue_end = cue.get("end_ms", 0)
        cue_ms = max(1, cue_end - cue_start)  # 至少 1ms，避免除零
        cue_windows.append((cue_start, cue_end, cue_ms))
        total_cue_ms += cue_ms
    
    # 策略：优先在英文标点处切分（由 <sep> 诱导产生的自然停顿）
    # 优先级：标点（, . ? ! — ; :） > 空格 > 单词边界
    
    # 1. 找到所有标点位置（优先切分点）
    # 标点符号：, . ? ! — ; :
    punctuation_pattern = r'[,\.\?!—;:]\s*'
    punctuation_positions = []
    for match in re.finditer(punctuation_pattern, en_text):
        pos = match.end()  # 标点后的位置（包含后续空格）
        punctuation_positions.append(pos)
    
    # 2. 计算每个 cue 应分配的字符数（目标）
    en_text_chars = len(en_text)
    char_offsets = [0]  # 每个 cue 的目标字符偏移
    for i, (_, _, cue_ms) in enumerate(cue_windows):
        if i == len(cue_windows) - 1:
            char_offsets.append(en_text_chars)  # 最后一个到结尾
        else:
            quota = int(en_text_chars * (cue_ms / total_cue_ms))
            char_offsets.append(char_offsets[-1] + quota)
    
    # 3. 按目标字符偏移分配文本，优先在标点处切分
    segments = []
    current_pos = 0
    
    for i, (cue_start, cue_end, _) in enumerate(cue_windows):
        target_end = char_offsets[i + 1]
        
        # 最后一个 cue，包含剩余所有文本
        if i == len(cue_windows) - 1:
            segment_text = en_text[current_pos:].strip()
            if segment_text:
                segments.append({
                    "start_ms": cue_start,
                    "end_ms": end_ms_final,
                    "text": segment_text,
                    "cue_index": i,  # cue 在 utterance 内的索引
                })
            break
        
        # 找到目标位置附近的最佳切分点
        # 优先选择：标点位置 > 目标位置附近的空格 > 目标位置（单词边界）
        best_cut_pos = target_end
        
        # 查找目标位置附近的标点
        for punc_pos in punctuation_positions:
            if current_pos < punc_pos <= target_end:
                # 标点在目标范围内，使用标点位置
                best_cut_pos = punc_pos
                break
            elif target_end < punc_pos <= target_end + 50:  # 允许稍微超过目标位置
                # 标点稍微超过目标位置，但很近，也可以使用
                best_cut_pos = punc_pos
                break
        
        # 如果没找到标点，尝试在目标位置附近找空格
        if best_cut_pos == target_end:
            # 在目标位置前后 20 个字符内找空格
            search_start = max(current_pos, target_end - 20)
            search_end = min(len(en_text), target_end + 20)
            search_text = en_text[search_start:search_end]
            
            # 找最接近目标位置的空格
            space_pos = search_text.rfind(' ', 0, target_end - search_start)
            if space_pos >= 0:
                best_cut_pos = search_start + space_pos + 1  # +1 包含空格
        
        # 确保切分位置在单词边界（不切分单词）
        # 如果 best_cut_pos 在单词中间，找到单词结束位置
        if best_cut_pos < len(en_text):
            # 检查 best_cut_pos 是否在单词中间
            if best_cut_pos > 0 and best_cut_pos < len(en_text):
                char_before = en_text[best_cut_pos - 1]
                char_at = en_text[best_cut_pos] if best_cut_pos < len(en_text) else ' '
                
                # 如果前一个字符是字母/数字，当前位置也是字母/数字，说明在单词中间
                if char_before.isalnum() and char_at.isalnum():
                    # 找到单词结束位置
                    word_end_match = re.search(r'\W', en_text[best_cut_pos:])
                    if word_end_match:
                        best_cut_pos = best_cut_pos + word_end_match.start()
                    else:
                        # 没找到，说明到文本末尾
                        best_cut_pos = len(en_text)
        
        # 提取 segment 文本
        segment_text = en_text[current_pos:best_cut_pos].strip()
        
        # 最后一个 cue 的 end_ms 使用 end_ms_final
        segment_end_ms = end_ms_final if i == len(cue_windows) - 1 else cue_end
        
        if segment_text:  # 只添加非空文本
            segments.append({
                "start_ms": cue_start,
                "end_ms": segment_end_ms,
                "text": segment_text,
                "cue_index": i,  # cue 在 utterance 内的索引
            })
        
        current_pos = best_cut_pos
    
    return segments


def translate_utterance(
    utterance: Dict[str, Any],
    next_utterance: Optional[Dict[str, Any]],
    translate_fn: Callable[[str], str],
) -> Dict[str, Any]:
    """
    翻译单个 utterance（完整流程）。
    
    Args:
        utterance: Utterance 数据（来自 SSOT），包含：
            - utt_id: Utterance ID
            - start_ms: 开始时间（毫秒）
            - end_ms: 结束时间（毫秒）
            - speech_rate: {"zh_tps": float}
            - cues: [{"start_ms": int, "end_ms": int, "source": {"text": str}, ...}]
            - 注意：v1.3 已移除 cue_id，使用索引即可
        next_utterance: 下一个 utterance（用于计算不重叠扩展），None 表示没有下一句
        translate_fn: 翻译函数
    
    Returns:
        TranslationSet 条目：
        {
            "utt_id": str,
            "end_ms_final": int,  # 原始 end_ms 或延长后
            "segments": [  # 英文字幕段
                {
                    "start_ms": int,
                    "end_ms": int,
                    "text": str,
                    "cue_index": int,  # v1.3: 使用索引而不是 cue_id
                },
                ...
            ],
            "metrics": {
                "zh_tps": float,
                "k": float,
                "budget_ms": float,
                "en_est_ms": float,
                "extend_ms": float,
                "retries": int,
            },
        }
    """
    utt_id = utterance.get("utt_id", "")
    start_ms = utterance.get("start_ms", 0)
    end_ms = utterance.get("end_ms", 0)
    speech_rate = utterance.get("speech_rate", {})
    zh_tps = speech_rate.get("zh_tps", 0.0)
    cues = utterance.get("cues", [])
    
    # 1. 合并中文文本
    zh_merged = "".join(cue.get("source", {}).get("text", "") for cue in cues)
    if not zh_merged:
        return {
            "utt_id": utt_id,
            "end_ms_final": end_ms,
            "segments": [],
            "metrics": {
                "zh_tps": zh_tps,
                "k": 0.0,
                "budget_ms": 0.0,
                "en_est_ms": 0.0,
                "extend_ms": 0.0,
                "retries": 0,
            },
        }
    
    # 2. 计算 k 值和时间预算
    window_ms = end_ms - start_ms
    k = pick_k(zh_tps)
    budget_ms = window_ms * k
    
    # 3. 首次翻译
    en_text, retries = translate_utterance_with_retry(
        zh_text=zh_merged,
        budget_ms=budget_ms,
        translate_fn=translate_fn,
    )
    
    # 4. 估计英文时长
    en_est_ms = estimate_en_duration_ms(en_text)
    
    # 5. 如果超限，尝试扩展 end_time
    extend_ms = 0.0
    end_ms_final = end_ms
    budget_ms2 = budget_ms
    
    if en_est_ms > budget_ms:
        need_ms = en_est_ms - budget_ms
        next_utt_start_ms = next_utterance.get("start_ms") if next_utterance else None
        extend_ms = calculate_extend_ms(need_ms, end_ms, next_utt_start_ms)
        
        if extend_ms > 0:
            end_ms_final = int(end_ms + extend_ms)
            budget_ms2 = budget_ms + extend_ms
            
            # 如果扩展后仍超限，重翻译
            if en_est_ms > budget_ms2:
                en_text, retries = translate_utterance_with_retry(
                    zh_text=zh_merged,
                    budget_ms=budget_ms2,
                    translate_fn=translate_fn,
                )
                en_est_ms = estimate_en_duration_ms(en_text)
    
    # 6. 重断句（不跨 utterance 边界）
    segments = resegment_utterance(en_text, cues, end_ms_final)
    
    return {
        "utt_id": utt_id,
        "end_ms_final": end_ms_final,
        "segments": segments,
        "metrics": {
            "zh_tps": zh_tps,
            "k": k,
            "budget_ms": budget_ms,
            "en_est_ms": en_est_ms,
            "extend_ms": extend_ms,
            "retries": retries,
        },
    }


def translate_utterances(
    utterances: List[Dict[str, Any]],
    translate_fn: Callable[[str], str],
) -> Dict[str, Any]:
    """
    翻译所有 utterances（utterance 粒度）。
    
    Args:
        utterances: Utterance 列表（来自 SSOT）
        translate_fn: 翻译函数
    
    Returns:
        TranslationSet：
        {
            "by_utt": {
                "utt_001": {
                    "end_ms_final": int,
                    "segments": [...],
                    "metrics": {...},
                },
                ...
            },
        }
    """
    results = {}
    
    info(f"Translating {len(utterances)} utterances (utterance-level)...")
    
    for i, utterance in enumerate(utterances):
        next_utterance = utterances[i + 1] if i + 1 < len(utterances) else None
        result = translate_utterance(utterance, next_utterance, translate_fn)
        results[result["utt_id"]] = result
    
    # 统计信息
    total_extend_ms = sum(r["metrics"]["extend_ms"] for r in results.values())
    total_retries = sum(r["metrics"]["retries"] for r in results.values())
    info(
        f"Translation completed: {len(results)} utterances, "
        f"total extend: {total_extend_ms:.0f}ms, total retries: {total_retries}"
    )
    
    return {
        "by_utt": results,
    }
