"""
构建 Subtitle Model v1.2（SSOT）

职责：
- 直接从 asr_result.json 的 utterances 生成 SSOT
- 按照语义切分 cues
- 根据 words 的时间轴生成 cue 的时间轴
"""
from typing import Any, Dict, List, Optional, Tuple
from pikppo.schema.subtitle_model import (
    SubtitleModel,
    SubtitleUtterance,
    SubtitleCue,
    SourceText,
    SpeechRate,
    SchemaInfo,
    EmotionInfo,
)
from pikppo.schema.types import Word


def normalize_speaker_id(speaker: str) -> str:
    """
    规范化 speaker ID。
    
    规则：
    - 如果已经是 "spk_" 开头，直接返回
    - 否则添加 "spk_" 前缀
    """
    if not speaker:
        return "spk_0"
    
    speaker = str(speaker).strip()
    if speaker.startswith("spk_"):
        return speaker
    
    return f"spk_{speaker}"


def build_emotion_info(
    emotion_label: Optional[str],
    emotion_score: Optional[float] = None,
    emotion_degree: Optional[str] = None,
) -> Optional[EmotionInfo]:
    """构建 EmotionInfo 对象。"""
    if not emotion_label:
        return None
    
    return EmotionInfo(
        label=str(emotion_label),
        confidence=float(emotion_score) if emotion_score is not None else None,
        intensity=str(emotion_degree) if emotion_degree else None,
    )


def calculate_speech_rate_zh_tps(words: List[Word]) -> float:
    """
    计算语速（中文 tokens per second）。
    
    规则：
    - 只统计有效的 words（start_ms >= 0, end_ms >= 0, text 非空）
    - 合并 words 的时间区间（union）
    - zh_tps = 有效 token 数 / 发声秒数
    """
    if not words:
        return 0.0
    
    # 过滤有效 words
    valid_words = []
    for w in words:
        if w.start_ms >= 0 and w.end_ms >= 0 and w.start_ms < w.end_ms:
            text = str(w.text).strip()
            if text:
                valid_words.append(w)
    
    if not valid_words:
        return 0.0
    
    # 合并时间区间（union）
    intervals = [(w.start_ms, w.end_ms) for w in valid_words]
    intervals.sort(key=lambda x: (x[0], x[1]))
    
    merged = []
    for start, end in intervals:
        if not merged:
            merged.append((start, end))
        else:
            last_start, last_end = merged[-1]
            if start <= last_end:
                # 重叠或相邻，合并
                merged[-1] = (last_start, max(last_end, end))
            else:
                # 不重叠，添加新区间
                merged.append((start, end))
    
    # 计算总发声时间（秒）
    total_duration_ms = sum(end - start for start, end in merged)
    total_duration_s = total_duration_ms / 1000.0
    
    if total_duration_s <= 0:
        return 0.0
    
    # 计算有效 token 数（中文字符数）
    total_chars = sum(len(str(w.text).strip()) for w in valid_words)
    
    # zh_tps = token 数 / 秒
    zh_tps = total_chars / total_duration_s
    
    return zh_tps


def semantic_split_text(
    text: str,
    words: List[Word],
    max_chars: int = 18,
    max_dur_ms: int = 2800,
    hard_punc: str = "。！？；",
    soft_punc: str = "，",
) -> List[Tuple[str, int, int]]:
    """
    按照语义切分文本，返回 (text, start_ms, end_ms) 列表。
    
    Args:
        text: 要切分的文本
        words: 词列表（用于计算时间戳）
        max_chars: 最大字数阈值
        max_dur_ms: 最大时长阈值（毫秒）
        hard_punc: 硬标点（必切）
        soft_punc: 软标点（可切）
    
    Returns:
        List[Tuple[str, int, int]]: (cue_text, start_ms, end_ms) 列表
    """
    if not text or not words:
        # 如果没有文本或 words，返回整个 utterance 的时间范围
        if words:
            start_ms = words[0].start_ms
            end_ms = words[-1].end_ms
        else:
            start_ms = 0
            end_ms = 0
        return [(text, start_ms, end_ms)]
    
    cues: List[Tuple[str, int, int]] = []
    text_pos = 0
    word_idx = 0
    
    # 计算 utterance 的总时长
    utt_start_ms = words[0].start_ms
    utt_end_ms = words[-1].end_ms
    
    while text_pos < len(text):
        remaining = text[text_pos:]
        
        # 如果剩余文本不足 max_chars，直接作为最后一个 cue
        if len(remaining) <= max_chars:
            # 找到对应的 words 范围
            cue_start_ms, cue_end_ms = _get_timestamps_for_text(
                remaining, words, word_idx, utt_start_ms, utt_end_ms
            )
            cues.append((remaining, cue_start_ms, cue_end_ms))
            break
        
        # 优先在硬标点处切
        hard_cut = -1
        for p in hard_punc:
            idx = remaining.find(p, 0, max_chars + 1)
            if idx > 0 and (hard_cut < 0 or idx < hard_cut):
                hard_cut = idx
        
        if hard_cut > 0:
            cue_text = remaining[:hard_cut + 1]
            cue_start_ms, cue_end_ms = _get_timestamps_for_text(
                cue_text, words, word_idx, utt_start_ms, utt_end_ms
            )
            cues.append((cue_text, cue_start_ms, cue_end_ms))
            text_pos += hard_cut + 1
            word_idx = _advance_word_idx(cue_text, words, word_idx)
            continue
        
        # 如果超过 max_chars，找软标点
        soft_cut = -1
        for p in soft_punc:
            idx = remaining.rfind(p, 0, max_chars + 1)
            if idx > 0 and (soft_cut < 0 or idx > soft_cut):
                soft_cut = idx
        
        if soft_cut > 0:
            cue_text = remaining[:soft_cut + 1]
            cue_start_ms, cue_end_ms = _get_timestamps_for_text(
                cue_text, words, word_idx, utt_start_ms, utt_end_ms
            )
            cues.append((cue_text, cue_start_ms, cue_end_ms))
            text_pos += soft_cut + 1
            word_idx = _advance_word_idx(cue_text, words, word_idx)
            continue
        
        # 没有标点，按字数硬切
        cue_text = remaining[:max_chars]
        cue_start_ms, cue_end_ms = _get_timestamps_for_text(
            cue_text, words, word_idx, utt_start_ms, utt_end_ms
        )
        cues.append((cue_text, cue_start_ms, cue_end_ms))
        text_pos += max_chars
        word_idx = _advance_word_idx(cue_text, words, word_idx)
    
    return cues if cues else [(text, utt_start_ms, utt_end_ms)]


def _get_timestamps_for_text(
    cue_text: str,
    words: List[Word],
    word_idx: int,
    fallback_start: int,
    fallback_end: int,
) -> Tuple[int, int]:
    """
    根据文本内容找到对应的 words 范围，返回时间戳。
    
    Args:
        cue_text: cue 的文本
        words: 词列表
        word_idx: 起始 word 索引
        fallback_start: 回退开始时间
        fallback_end: 回退结束时间
    
    Returns:
        (start_ms, end_ms)
    """
    if not words or word_idx >= len(words):
        return (fallback_start, fallback_end)
    
    # 找到 cue_text 对应的 words 范围
    text_consumed = 0
    start_word_idx = word_idx
    end_word_idx = word_idx
    
    for i in range(word_idx, len(words)):
        w = words[i]
        w_text = str(w.text).strip()
        if text_consumed + len(w_text) <= len(cue_text):
            text_consumed += len(w_text)
            end_word_idx = i + 1
        else:
            break
    
    if start_word_idx < len(words) and end_word_idx > start_word_idx:
        cue_start_ms = words[start_word_idx].start_ms
        cue_end_ms = words[end_word_idx - 1].end_ms
        return (cue_start_ms, cue_end_ms)
    
    # 回退：按字符比例分配时间
    if word_idx < len(words):
        total_text_len = sum(len(str(w.text).strip()) for w in words[word_idx:])
        if total_text_len > 0:
            ratio = len(cue_text) / total_text_len
            dur = fallback_end - fallback_start
            cue_start_ms = fallback_start
            cue_end_ms = fallback_start + int(dur * ratio)
            return (cue_start_ms, cue_end_ms)
    
    return (fallback_start, fallback_end)


def _advance_word_idx(cue_text: str, words: List[Word], word_idx: int) -> int:
    """
    根据 cue_text 推进 word_idx。
    
    Args:
        cue_text: cue 的文本
        words: 词列表
        word_idx: 当前 word 索引
    
    Returns:
        新的 word_idx
    """
    text_consumed = 0
    for i in range(word_idx, len(words)):
        text_consumed += len(str(words[i].text).strip())
        if text_consumed >= len(cue_text):
            return i + 1
    return len(words)


def _split_words_by_pause(words: List[Word], *, long_pause_ms: int) -> List[List[Word]]:
    """
    将 ASR 的 words 按“超长停顿”二次切分成多个 chunk。

    SSOT 的 utterance 需要服务于翻译/TTS/预算等下游，因此必须避免被超长停顿“污染”：
    - 如果同一 utterance 内存在显著空白（word gap），语义/听觉上已经不连续
    - 必须拆分，否则会导致时间窗虚高、TTS/对齐被误导
    """
    if not words:
        return []
    if long_pause_ms <= 0:
        return [words]

    chunks: List[List[Word]] = []
    cur: List[Word] = [words[0]]
    for prev, curr in zip(words, words[1:]):
        gap = int(curr.start_ms) - int(prev.end_ms)
        if gap >= long_pause_ms:
            chunks.append(cur)
            cur = [curr]
        else:
            cur.append(curr)
    if cur:
        chunks.append(cur)
    return chunks


def _map_words_to_text_spans(utt_text: str, words: List[Word]) -> List[Tuple[int, int]]:
    """
    将 words 映射到 utt_text 的 (start_idx, end_idx) span（从左到右贪心匹配）。

    目的：按 pause 切分后，尽量保留原文中的标点/符号（它们通常不在 words 中）。
    """
    spans: List[Tuple[int, int]] = []
    if not utt_text or not words:
        return spans

    pos = 0
    for w in words:
        token = str(w.text or "")
        if not token:
            spans.append((-1, -1))
            continue
        idx = utt_text.find(token, pos)
        if idx < 0:
            spans.append((-1, -1))
            continue
        start = idx
        end = idx + len(token)
        spans.append((start, end))
        pos = end
    return spans


def _extract_text_for_word_range(
    utt_text: str,
    word_spans: List[Tuple[int, int]],
    start_word_idx: int,
    end_word_idx_exclusive: int,
    fallback_words: List[Word],
) -> str:
    """
    从原 utterance 文本中提取一个 word 范围对应的子串（尽量保留标点）。
    若 span 映射不完整，则回退为拼接 words.text。
    """
    if not utt_text or not word_spans or start_word_idx >= end_word_idx_exclusive:
        return "".join(str(w.text or "") for w in fallback_words).strip()

    start_span = word_spans[start_word_idx] if 0 <= start_word_idx < len(word_spans) else (-1, -1)
    end_span = (
        word_spans[end_word_idx_exclusive - 1]
        if 0 <= end_word_idx_exclusive - 1 < len(word_spans)
        else (-1, -1)
    )
    if start_span[0] >= 0 and end_span[1] >= 0 and start_span[0] < end_span[1]:
        return utt_text[start_span[0] : end_span[1]].strip()

    return "".join(str(w.text or "") for w in fallback_words).strip()


def build_subtitle_model(
    raw_response: Dict[str, Any],
    *,
    source_lang: str = "zh",
    audio_duration_ms: Optional[int] = None,
    max_chars: int = 18,
    max_dur_ms: int = 2800,
    hard_punc: str = "。！？；",
    soft_punc: str = "，",
    long_pause_ms: int = 1000,
) -> SubtitleModel:
    """
    直接从 asr_result.json 的 utterances 构建 Subtitle Model v1.2（SSOT）。
    
    Args:
        raw_response: ASR 原始响应（SSOT，包含完整语义信息）
        source_lang: 源语言代码（如 "zh", "en"），默认 "zh"
        audio_duration_ms: 音频时长（毫秒，可选）
        max_chars: 最大字数阈值（用于语义切分）
        max_dur_ms: 最大时长阈值（毫秒，用于语义切分）
        hard_punc: 硬标点（必切）
        soft_punc: 软标点（可切）
    
    Returns:
        SubtitleModel: 完整的字幕模型 v1.2（SSOT）
    
    注意：
    - 直接从 raw_response 的 utterances 生成，不依赖 segments
    - 按照语义切分 cues（基于标点、字数等）
    - 根据 words 的时间轴生成 cue 的时间轴
    """
    # 1. 从 raw_response 中提取原始 utterances
    result = raw_response.get("result") or {}
    raw_utterances = result.get("utterances") or []
    
    # 2. 构建 utterances 和 cues（直接遍历 raw_utterances；允许按 pause 二次拆分）
    utterances: List[SubtitleUtterance] = []

    ssot_utt_index = 0

    for raw_utt in raw_utterances:
        # 从 asr-result.json 的 utterance 中获取 text 和时间
        utt_text = str(raw_utt.get("text", "")).strip()

        # 如果 text 为空，跳过（SSOT 不记录空 utterance）
        if not utt_text:
            continue
        
        # 规范化 speaker ID（从 raw_utt 的 additions 中获取）
        additions = raw_utt.get("additions") or {}
        raw_speaker = str(additions.get("speaker", "0"))
        normalized_speaker = normalize_speaker_id(raw_speaker)
        
        # 解析 words（用于 pause 切分、计算语速和生成 cue 时间轴）
        words: List[Word] = []
        words_list = raw_utt.get("words") or []
        for w in words_list:
            words.append(Word(
                start_ms=int(w.get("start_time", 0)),
                end_ms=int(w.get("end_time", w.get("start_time", 0))),
                text=str(w.get("text", "")).strip(),
                speaker="",
            ))
        
        # 提取 emotion（从 raw_utt 的 additions 中）
        utterance_emotion: Optional[EmotionInfo] = None
        emotion_label = additions.get("emotion")
        if emotion_label:
            emotion_score = additions.get("emotion_score")
            if emotion_score:
                try:
                    emotion_score = float(emotion_score)
                except (ValueError, TypeError):
                    emotion_score = None
            else:
                emotion_score = None
            emotion_degree = additions.get("emotion_degree")
            utterance_emotion = build_emotion_info(
                emotion_label=emotion_label,
                emotion_score=emotion_score,
                emotion_degree=emotion_degree,
            )
        
        # 没有 words 时，无法按 pause 切分，且 cue 时间轴也无法可靠生成：退化为单条
        if not words:
            ssot_utt_index += 1
            utterances.append(
                SubtitleUtterance(
                    utt_id=f"utt_{ssot_utt_index:04d}",
                    speaker=normalized_speaker,
                    start_ms=int(raw_utt.get("start_time", 0)),
                    end_ms=int(raw_utt.get("end_time", int(raw_utt.get("start_time", 0)))),
                    speech_rate=SpeechRate(zh_tps=0.0),
                    emotion=utterance_emotion,
                    cues=[
                        SubtitleCue(
                            start_ms=int(raw_utt.get("start_time", 0)),
                            end_ms=int(raw_utt.get("end_time", int(raw_utt.get("start_time", 0)))),
                            source=SourceText(lang=source_lang, text=utt_text),
                        )
                    ],
                )
            )
            continue

        # 规则：按超长停顿拆分 utterance
        chunks = _split_words_by_pause(words, long_pause_ms=long_pause_ms)
        word_spans = _map_words_to_text_spans(utt_text, words)

        cursor = 0
        for chunk_words in chunks:
            if not chunk_words:
                continue

            start_word_idx = cursor
            end_word_idx_exclusive = start_word_idx + len(chunk_words)
            cursor = end_word_idx_exclusive

            chunk_text = _extract_text_for_word_range(
                utt_text=utt_text,
                word_spans=word_spans,
                start_word_idx=start_word_idx,
                end_word_idx_exclusive=end_word_idx_exclusive,
                fallback_words=chunk_words,
            )
            if not chunk_text:
                continue

            # 计算语速（从 chunk words）
            zh_tps = calculate_speech_rate_zh_tps(chunk_words)

            # 按照语义切分 cues（在 chunk 内）
            cue_data_list = semantic_split_text(
                text=chunk_text,
                words=chunk_words,
                max_chars=max_chars,
                max_dur_ms=max_dur_ms,
                hard_punc=hard_punc,
                soft_punc=soft_punc,
            )

            cues: List[SubtitleCue] = []
            for cue_text, cue_start_ms, cue_end_ms in cue_data_list:
                cues.append(
                    SubtitleCue(
                        start_ms=int(cue_start_ms),
                        end_ms=int(cue_end_ms),
                        source=SourceText(lang=source_lang, text=str(cue_text)),
                    )
                )

            if not cues:
                continue

            # SSOT hard invariant：utterance 时间范围 == cues 覆盖范围（避免被长空白污染）
            utt_start_ms = int(min(cue.start_ms for cue in cues))
            utt_end_ms = int(max(cue.end_ms for cue in cues))

            ssot_utt_index += 1
            utterances.append(
                SubtitleUtterance(
                    utt_id=f"utt_{ssot_utt_index:04d}",
                    speaker=normalized_speaker,
                    start_ms=utt_start_ms,
                    end_ms=utt_end_ms,
                    speech_rate=SpeechRate(zh_tps=float(zh_tps)),
                    emotion=utterance_emotion,
                    cues=cues,
                )
            )
    
    # 3. 构建 audio 元数据
    audio: Optional[Dict[str, Any]] = None
    if audio_duration_ms is not None:
        audio = {
            "duration_ms": audio_duration_ms,
        }
    elif utterances:
        # 从最后一个 utterance 推断时长
        last_utt = utterances[-1]
        audio = {
            "duration_ms": last_utt.end_ms,
        }
    
    # 4. 构建 Subtitle Model v1.2
    model = SubtitleModel(
        schema=SchemaInfo(name="subtitle.model", version="1.2"),
        audio=audio,
        utterances=utterances,
    )
    
    return model
