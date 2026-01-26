"""
OpenAI 翻译提示词模板：Stage1/Stage2/Fallback
"""
from typing import List


def build_stage1_prompt(
    zh_episode_text: str,
    *,
    max_chars_per_line: int = 42,
    max_lines: int = 2,
    target_cps: str = "12-17",
    avoid_formal: bool = True,
    profanity_policy: str = "soften",
) -> List[dict]:
    """
    构建 Stage 1 提示词（生成翻译上下文）。
    
    Args:
        zh_episode_text: 整集中文字幕文本（用换行符连接）
        max_chars_per_line: 每行最大字符数
        max_lines: 每段最大行数
        target_cps: 目标字符每秒
        avoid_formal: 避免正式用语
        profanity_policy: 脏话处理策略
    
    Returns:
        messages 列表（用于 OpenAI API）
    """
    system_prompt = """You are a professional subtitle translation expert. Your task is to analyze the Chinese subtitle text and generate translation guidelines (context) for consistent, natural English subtitle translation.

Focus on:
- Character names and their relationships
- Key terminology and domain-specific terms
- Tone and style (conversational, formal, etc.)
- Cultural context that affects translation choices
- Any recurring phrases or expressions

Return a JSON object with:
{
  "characters": [{"name": "...", "role": "..."}, ...],
  "terminology": {"chinese_term": "english_term", ...},
  "style_notes": "...",
  "tone": "conversational|formal|casual",
  "context": "..."
}"""

    user_prompt = f"""Analyze the following Chinese subtitle text and generate translation context:

{zh_episode_text}

Guidelines:
- Max {max_chars_per_line} chars per line
- Max {max_lines} lines per subtitle
- Target CPS: {target_cps}
- Avoid formal language: {avoid_formal}
- Profanity policy: {profanity_policy}

Return only the JSON object, no additional text."""

    return [
        {"role": "system", "content": system_prompt},
        {"role": "user", "content": user_prompt},
    ]


def build_stage2_prompt(
    segments: List[dict],
    context: dict,
    *,
    max_chars_per_line: int = 42,
    max_lines: int = 2,
) -> List[dict]:
    """
    构建 Stage 2 提示词（翻译 segments）。
    
    Args:
        segments: 中文 segments 列表（每个包含 text, start, end 等）
        context: Stage 1 生成的翻译上下文
        max_chars_per_line: 每行最大字符数
        max_lines: 每段最大行数
    
    Returns:
        messages 列表（用于 OpenAI API）
    """
    system_prompt = """You are a professional subtitle translator. Translate Chinese subtitles to natural, concise English suitable for video subtitles.

Rules:
1. Use the provided translation context for consistency
2. Keep translations natural and conversational
3. Respect character limits per line
4. Use proper names and terminology from context
5. Output format: Use tags <<<0>>>, <<<1>>>, etc. to mark each translation

Example output format:
<<<0>>>
I did ten years in prison.
<<<1>>>
I was framed for killing my parents.
<<<2>>>
That's not true!"""

    # 构建 segments 文本（带索引）
    segments_text = "\n\n".join([
        f"Segment {i}:\n{seg.get('text', '')}"
        for i, seg in enumerate(segments)
        if seg.get('text', '').strip()
    ])
    
    context_str = f"""
Translation Context:
- Characters: {context.get('characters', [])}
- Terminology: {context.get('terminology', {})}
- Style: {context.get('style_notes', '')}
- Tone: {context.get('tone', 'conversational')}
"""
    
    user_prompt = f"""{context_str}

Translate the following {len(segments)} Chinese subtitle segments to English:

{segments_text}

Requirements:
- Max {max_chars_per_line} chars per line
- Max {max_lines} lines per subtitle
- Use tags <<<0>>>, <<<1>>>, <<<2>>>, etc. to mark each translation
- Return exactly {len(segments)} translations, one per tag
- If a segment is empty, return an empty string for that tag

Output format:
<<<0>>>
[translation 0]
<<<1>>>
[translation 1]
...
"""

    return [
        {"role": "system", "content": system_prompt},
        {"role": "user", "content": user_prompt},
    ]


def build_fallback_prompt(
    texts: List[str],
) -> List[dict]:
    """
    构建 Fallback 提示词（简单翻译，无上下文）。
    
    Args:
        texts: 要翻译的文本列表
    
    Returns:
        messages 列表（用于 OpenAI API）
    """
    system_prompt = """You are a professional translator specializing in subtitle translation. Translate Chinese subtitles to natural, concise English suitable for video subtitles.

Output format: Use tags <<<0>>>, <<<1>>>, etc. to mark each translation."""

    segments_text = "\n\n".join([
        f"<<<{i}>>>\n{text}"
        for i, text in enumerate(texts)
    ])
    
    user_prompt = f"""Translate the following {len(texts)} Chinese subtitle segments to English:

{segments_text}

Return the translations in the same format with tags:
<<<0>>>
[translation 0]
<<<1>>>
[translation 1]
...
"""

    return [
        {"role": "system", "content": system_prompt},
        {"role": "user", "content": user_prompt},
    ]
