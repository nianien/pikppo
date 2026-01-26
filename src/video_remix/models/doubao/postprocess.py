"""
轴优先（口型优先）切分策略：宁碎不拖、宁切不断

Subtitle Axis Mode:
- NO MERGE (never merge segments)
- Time-axis first: cut on any perceptible pause
- Split only: by speaker, by utterance (VAD), by word-gap, and by semantic/length constraints

职责：
- 硬切：speaker 变化、utterance 边界、word-gap ≥ hard_gap_ms、max_dur 必须切
- 软切：word-gap ≥ soft_gap_ms（轴切，400ms）
- 语义切：长句兜底（只拆不合）
- 输出 Segment[]（仍带 speaker，但已完成切分，绝不合并）

"""
from typing import Any, Dict, List, Tuple

from .postprofiles import POSTPROFILES
from .types import Utterance, Segment, Word
from .parser import normalize_text


def words_to_segment(words: List[Word], speaker: str) -> Segment:
    """将 words 列表转换为 Segment"""
    if not words:
        raise ValueError("words 列表不能为空")
    
    start_ms = words[0].start_ms
    end_ms = words[-1].end_ms
    text = "".join(w.text for w in words)
    
    return Segment(
        speaker=speaker,
        start_ms=start_ms,
        end_ms=end_ms,
        text=normalize_text(text),
    )


def split_utterance_axis_first(
    utt: Utterance,
    soft_gap_ms: int = 400,
) -> List[Segment]:
    """
    Step 2：对每个 utterance 内部按 speaker + word-gap 再切（轴优先）
    
    轴优先：gap ≥ soft_gap_ms 就切（宁碎不拖）
    """
    words = utt.words or []
    
    # 如果没有 words，直接返回 utterance 级别的 segment
    if not words:
        return [Segment(
            speaker=utt.speaker,
            start_ms=utt.start_ms,
            end_ms=utt.end_ms,
            text=normalize_text(utt.text),
        )]
    
    segments: List[Segment] = []
    cur_words: List[Word] = [words[0]]
    cur_spk = getattr(words[0], "speaker", "") or utt.speaker
    
    for w in words[1:]:
        w_spk = getattr(w, "speaker", "") or utt.speaker
        gap = w.start_ms - cur_words[-1].end_ms
        
        # 1) speaker 变化：必切（硬边界）
        if w_spk != cur_spk:
            segments.append(words_to_segment(cur_words, cur_spk))
            cur_words = [w]
            cur_spk = w_spk
            continue
        
        # 2) 停顿切：轴优先（soft_gap_ms 也切）
        if gap >= soft_gap_ms:
            segments.append(words_to_segment(cur_words, cur_spk))
            cur_words = [w]
            continue
        
        # 否则累积到当前 segment
        cur_words.append(w)
    
    # 添加最后一个 segment
    if cur_words:
        segments.append(words_to_segment(cur_words, cur_spk))
    
    return segments


def semantic_split_long_segment(
    seg: Segment,
    words: List[Word],
    max_chars: int = 18,
    max_dur_ms: int = 2800,
    hard_punc: str = "。！？；",
    soft_punc: str = "，",
) -> List[Segment]:
    """
    Step 3：段内"长句兜底语义切"（只在超长触发）
    
    如果 duration > max_dur_ms 或 len(text) > max_chars，按标点拆
    """
    # 检查是否需要切分
    need_split = False
    if seg.end_ms - seg.start_ms > max_dur_ms:
        need_split = True
    elif len(seg.text) > max_chars:
        need_split = True
    
    if not need_split:
        return [seg]
    
    # 需要切分：按标点优先拆
    text = seg.text
    segments: List[Segment] = []
    text_pos = 0
    word_idx = 0
    
    # 找到 words 中对应此 segment 的范围
    seg_words: List[Word] = []
    for w in words:
        if w.start_ms >= seg.start_ms and w.end_ms <= seg.end_ms:
            seg_words.append(w)
    
    if not seg_words:
        # 如果没有 words，按字符比例分配时间
        return _split_by_chars_proportional(seg, max_chars, hard_punc, soft_punc)
    
    while text_pos < len(text) and word_idx < len(seg_words):
        remaining = text[text_pos:]
        
        # 优先在硬标点处切
        hard_cut = -1
        for p in hard_punc:
            idx = remaining.find(p, 0, max_chars + 1)
            if idx > 0 and (hard_cut < 0 or idx < hard_cut):
                hard_cut = idx
        
        if hard_cut > 0:
            seg_text = remaining[:hard_cut + 1]
            seg_start, seg_end = _allocate_timestamps_from_words(
                seg_text, seg_words, word_idx, seg.start_ms, seg.end_ms
            )
            segments.append(Segment(
                speaker=seg.speaker,
                start_ms=seg_start,
                end_ms=seg_end,
                text=seg_text,
            ))
            text_pos += hard_cut + 1
            word_idx = _advance_word_idx(seg_text, seg_words, word_idx)
            continue
        
        # 如果超过 max_chars，找软标点
        if len(remaining) > max_chars:
            soft_cut = -1
            for p in soft_punc:
                idx = remaining.rfind(p, 0, max_chars + 1)
                if idx > 0 and (soft_cut < 0 or idx > soft_cut):
                    soft_cut = idx
            
            if soft_cut > 0:
                seg_text = remaining[:soft_cut + 1]
                seg_start, seg_end = _allocate_timestamps_from_words(
                    seg_text, seg_words, word_idx, seg.start_ms, seg.end_ms
                )
                segments.append(Segment(
                    speaker=seg.speaker,
                    start_ms=seg_start,
                    end_ms=seg_end,
                    text=seg_text,
                ))
                text_pos += soft_cut + 1
                word_idx = _advance_word_idx(seg_text, seg_words, word_idx)
                continue
            
            # 没有标点，按字数硬切
            seg_text = remaining[:max_chars]
            seg_start, seg_end = _allocate_timestamps_from_words(
                seg_text, seg_words, word_idx, seg.start_ms, seg.end_ms
            )
            segments.append(Segment(
                speaker=seg.speaker,
                start_ms=seg_start,
                end_ms=seg_end,
                text=seg_text,
            ))
            text_pos += max_chars
            word_idx = _advance_word_idx(seg_text, seg_words, word_idx)
        else:
            # 剩余部分不足 max_chars，直接输出
            seg_text = remaining
            seg_start, seg_end = _allocate_timestamps_from_words(
                seg_text, seg_words, word_idx, seg.start_ms, seg.end_ms
            )
            segments.append(Segment(
                speaker=seg.speaker,
                start_ms=seg_start,
                end_ms=seg_end,
                text=seg_text,
            ))
            break
    
    return segments if segments else [seg]


def _split_by_chars_proportional(
    seg: Segment,
    max_chars: int,
    hard_punc: str,
    soft_punc: str,
) -> List[Segment]:
    """当没有 words 时，按字符比例分配时间切分"""
    text = seg.text
    if len(text) <= max_chars:
        return [seg]
    
    segments: List[Segment] = []
    dur = seg.end_ms - seg.start_ms
    
    text_pos = 0
    while text_pos < len(text):
        remaining = text[text_pos:]
        
        # 优先在硬标点处切
        hard_cut = -1
        for p in hard_punc:
            idx = remaining.find(p, 0, max_chars + 1)
            if idx > 0 and (hard_cut < 0 or idx < hard_cut):
                hard_cut = idx
        
        if hard_cut > 0:
            seg_text = remaining[:hard_cut + 1]
            seg_start = seg.start_ms + int(dur * (text_pos / len(text)))
            seg_end = seg.start_ms + int(dur * ((text_pos + len(seg_text)) / len(text)))
            segments.append(Segment(
                speaker=seg.speaker,
                start_ms=seg_start,
                end_ms=seg_end,
                text=seg_text,
            ))
            text_pos += hard_cut + 1
            continue
        
        # 如果超过 max_chars，找软标点
        if len(remaining) > max_chars:
            soft_cut = -1
            for p in soft_punc:
                idx = remaining.rfind(p, 0, max_chars + 1)
                if idx > 0 and (soft_cut < 0 or idx > soft_cut):
                    soft_cut = idx
            
            if soft_cut > 0:
                seg_text = remaining[:soft_cut + 1]
                seg_start = seg.start_ms + int(dur * (text_pos / len(text)))
                seg_end = seg.start_ms + int(dur * ((text_pos + len(seg_text)) / len(text)))
                segments.append(Segment(
                    speaker=seg.speaker,
                    start_ms=seg_start,
                    end_ms=seg_end,
                    text=seg_text,
                ))
                text_pos += soft_cut + 1
                continue
            
            # 没有标点，按字数硬切
            seg_text = remaining[:max_chars]
            seg_start = seg.start_ms + int(dur * (text_pos / len(text)))
            seg_end = seg.start_ms + int(dur * ((text_pos + len(seg_text)) / len(text)))
            segments.append(Segment(
                speaker=seg.speaker,
                start_ms=seg_start,
                end_ms=seg_end,
                text=seg_text,
            ))
            text_pos += max_chars
        else:
            # 剩余部分
            seg_text = remaining
            seg_start = seg.start_ms + int(dur * (text_pos / len(text)))
            seg_end = seg.end_ms
            segments.append(Segment(
                speaker=seg.speaker,
                start_ms=seg_start,
                end_ms=seg_end,
                text=seg_text,
            ))
            break
    
    return segments if segments else [seg]


def _allocate_timestamps_from_words(
    seg_text: str,
    words: List[Word],
    word_idx: int,
    chunk_start: int,
    chunk_end: int,
) -> Tuple[int, int]:
    """为语义切分的文本片段分配时间戳（使用 words 边界）"""
    if not words or word_idx >= len(words):
        return (chunk_start, chunk_end)
    
    # 找到 seg_text 对应的 words 范围
    text_consumed = 0
    start_word_idx = word_idx
    end_word_idx = word_idx
    
    for i in range(word_idx, len(words)):
        w = words[i]
        w_text = w.text
        if text_consumed + len(w_text) <= len(seg_text):
            text_consumed += len(w_text)
            end_word_idx = i + 1
        else:
            break
    
    if start_word_idx < len(words) and end_word_idx > start_word_idx:
        seg_start = words[start_word_idx].start_ms
        seg_end = words[end_word_idx - 1].end_ms
        return (seg_start, seg_end)
    
    # 回退：按字符比例分配时间
    if word_idx < len(words):
        ratio = len(seg_text) / max(1, sum(len(w.text) for w in words[word_idx:]))
        dur = chunk_end - chunk_start
        seg_start = chunk_start
        seg_end = chunk_start + int(dur * ratio)
        return (seg_start, seg_end)
    
    return (chunk_start, chunk_end)


def _advance_word_idx(seg_text: str, words: List[Word], word_idx: int) -> int:
    """根据消耗的文本，推进 word_idx"""
    text_consumed = 0
    for i in range(word_idx, len(words)):
        w = words[i]
        text_consumed += len(w.text)
        if text_consumed >= len(seg_text):
            return i + 1
    return len(words)


def speaker_aware_postprocess(
    utterances: List[Utterance],
    profile_name: str = "axis",  # 默认：轴优先模式
    profiles: Dict[str, Dict[str, Any]] = None,
) -> List[Segment]:
    """
    轴优先（口型优先）切分策略：Utterance[] → Segment[]
    
    总原则：
    1. 时间轴优先于语义：只要有可感知停顿，就切
    2. 只拆不合：任何情况下都不把两段合回去
    3. speaker 永远是硬边界：不同 speaker 必切
    4. VAD 是主切，word-gap 是兜底切
    
    切分信号优先级（从高到低）：
    A. 硬切（必须切）：
       1. speaker 变化
       2. utterance 边界（VAD 输出）
       3. word-gap ≥ hard_gap_ms
       4. segment 时长 ≥ max_dur_ms
    
    B. 软切（轴切）：
       5. word-gap ≥ soft_gap_ms（400ms）
    
    C. 语义切（只用于"过长"兜底）：
       6. 文本超过 max_chars：按标点优先拆
    
    Args:
        utterances: 原始话语单元列表（已按时间排序）
        profile_name: 后处理策略名称（axis, axis_default, axis_soft）
        profiles: 后处理策略配置字典（如果为 None，使用默认配置）
    
    Returns:
        Segment[]: 已完成切分的中间数据结构（仍带 speaker，绝不合并）
    """
    if not utterances:
        return []
    
    # 获取后处理策略配置
    if profiles is None:
        profiles = POSTPROFILES
    
    # 获取配置（如果不存在，使用默认 "axis"）
    p = profiles.get(profile_name, POSTPROFILES.get("axis", {}))
    
    # 工程约束 1：axis* profiles 强制不合并（运行时 assert）
    if profile_name.startswith("axis"):
        allow_merge = p.get("allow_merge", False)
        assert not allow_merge, f"Axis profiles must never merge. Profile '{profile_name}' has allow_merge=True, which is forbidden."
    
    soft_gap_ms = int(p.get("soft_gap_ms", 400))  # 轴切：400ms 就切
    max_dur_ms = int(p.get("max_dur_ms", 2800))    # 单条字幕最大时长
    max_chars = int(p.get("max_chars", 18))         # 最大字数阈值
    hard_punc = p.get("hard_punc", "。！？；")      # 必切标点
    soft_punc = p.get("soft_punc", "，")            # 可切标点
    pad_end_ms = int(p.get("pad_end_ms", 60))       # 轻微拉长尾巴
    
    segments: List[Segment] = []
    
    # Step 1：先按 utterance（VAD）生成初始 segments（必切）
    # 轴优先：不跨 utterance 是铁律之一
    for utt in utterances:
        # Step 2：对每个 utterance 内部按 speaker + word-gap 再切
        utt_segments = split_utterance_axis_first(utt, soft_gap_ms)
        
        # Step 3：对每个 segment 检查是否需要语义切分（长句兜底）
        for seg in utt_segments:
            # 检查硬边界：max_dur_ms（如果超过，强制切分）
            if seg.end_ms - seg.start_ms > max_dur_ms:
                # 超过最大时长，强制语义切分
                long_segs = semantic_split_long_segment(
                    seg, utt.words or [], max_chars, max_dur_ms, hard_punc, soft_punc
                )
                segments.extend(long_segs)
            else:
                # 检查是否需要语义切分（超长文本）
                if len(seg.text) > max_chars:
                    long_segs = semantic_split_long_segment(
                        seg, utt.words or [], max_chars, max_dur_ms, hard_punc, soft_punc
                    )
                    segments.extend(long_segs)
                else:
                    # 正常 segment，应用 pad_end_ms
                    segments.append(Segment(
                        speaker=seg.speaker,
                        start_ms=seg.start_ms,
                        end_ms=seg.end_ms + pad_end_ms,
                        text=seg.text,
                    ))
    
    # Step 4：禁止合并（明确写死）
    # IMPORTANT: NO MERGE. Keep original segmentation.
    # 无论多短的段，都保持原状
    
    # 安全检查：确保 segments 时间严格递增
    fixed: List[Segment] = []
    last_end = -1
    for seg in segments:
        st, et = seg.start_ms, seg.end_ms
        if st <= last_end:
            st = last_end + 1
        if et <= st:
            et = st + 200
        fixed.append(Segment(
            speaker=seg.speaker,
            start_ms=st,
            end_ms=et,
            text=seg.text,
        ))
        last_end = et
    
    return fixed
