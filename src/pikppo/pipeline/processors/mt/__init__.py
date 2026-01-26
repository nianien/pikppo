"""
Machine Translation (MT) module for video remix pipeline.
"""
from pathlib import Path
from typing import Tuple
import json

from pikppo.config.settings import PipelineConfig, get_openai_api_key


def translate_episode(
    segments_path: str,
    output_dir: str,
    *,
    model: str = "gpt-4o-mini",
    temperature: float = 0.3,
) -> Tuple[str, str]:
    """
    翻译整集字幕（薄封装：只负责读写 + 调用 models.openai.translate）。
    
    Args:
        segments_path: 中文 segments JSON 文件路径
        output_dir: 输出目录（临时目录）
        model: OpenAI 模型名称
        temperature: 温度参数
    
    Returns:
        (context_path, en_segments_path) 元组
    """
    from pikppo.models.openai import build_translation_context, translate_segments
    
    # 读取 segments
    with open(segments_path, "r", encoding="utf-8") as f:
        segments = json.load(f)
    
    if not segments:
        raise RuntimeError(f"No segments found in {segments_path}")
    
    # 获取 API key
    api_key = get_openai_api_key()
    if not api_key:
        raise RuntimeError(
            "OpenAI API key not found. Please set OPENAI_API_KEY environment variable."
        )
    
    # Stage 1: 生成翻译上下文
    # 提取整集文本
    zh_episode_text = "\n".join([
        seg.get("text", "").strip()
        for seg in segments
        if seg.get("text", "").strip()
    ])
    
    if not zh_episode_text:
        raise RuntimeError(f"No text found in segments from {segments_path}")
    
    context = build_translation_context(
        zh_episode_text=zh_episode_text,
        api_key=api_key,
        model=model,
        temperature=temperature,
    )
    
    # Stage 2: 翻译 segments
    en_texts = translate_segments(
        segments=segments,
        context=context,
        api_key=api_key,
        model=model,
        temperature=temperature,
        use_tag_alignment=True,
    )
    
    # 生成英文 segments（保留原始时间轴和结构）
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
    
    # 保存文件
    output_path = Path(output_dir)
    output_path.mkdir(parents=True, exist_ok=True)
    
    context_path = str(output_path / "translation-context.json")
    en_segments_path = str(output_path / "en-segments.json")
    
    with open(context_path, "w", encoding="utf-8") as f:
        json.dump(context, f, indent=2, ensure_ascii=False)
    
    with open(en_segments_path, "w", encoding="utf-8") as f:
        json.dump(en_segments, f, indent=2, ensure_ascii=False)
    
    return context_path, en_segments_path


def translate_segments_with_fallback(
    config: PipelineConfig,
    texts: list[str],
) -> list[str]:
    """
    翻译文本列表（带回退机制）。
    
    Args:
        config: PipelineConfig
        texts: 要翻译的文本列表
    
    Returns:
        翻译后的文本列表
    """
    from .openai_translate import translate_segments_openai
    
    api_key = get_openai_api_key()
    if not api_key:
        raise RuntimeError(
            "OpenAI API key not found. Please set OPENAI_API_KEY environment variable."
        )
    
    return translate_segments_openai(
        texts=texts,
        api_key=api_key,
        model=config.openai_model,
        temperature=config.openai_temperature,
    )
