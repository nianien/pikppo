"""
豆包 ASR 运行器：负责调用 ASR API 并管理结果缓存

职责：
- 根据预设调用 ASR 模型
- 检查缓存，避免重复调用
- 保存原始响应结果
"""
import json
import os
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

from video_remix.models.doubao import (
    DoubaoASRClient,
    get_preset,
    guess_audio_format,
    parse_utterances,
)
from video_remix.models.doubao.presets import RESOURCE_ID
from video_remix.models.doubao.request_types import (
    DoubaoASRRequest,
    AudioConfig,
    UserInfo,
)
from video_remix.utils.logger import info, warning


def get_response_path(output_dir: Path, preset: str) -> Path:
    """
    获取原始响应文件的路径。
    
    Args:
        output_dir: 输出目录
        preset: ASR 预设名称
    
    Returns:
        原始响应文件路径
    """
    output_dir.mkdir(parents=True, exist_ok=True)
    return output_dir / f"{preset}-response.json"


def load_cached_result(output_dir: Path, preset: str) -> Optional[Tuple[Dict[str, Any], List]]:
    """
    检查并加载缓存的 ASR 结果。
    
    Args:
        output_dir: 输出目录
        preset: ASR 预设名称
    
    Returns:
        如果存在缓存，返回 (query_result, utterances)，否则返回 None
    """
    raw_response_file = get_response_path(output_dir, preset)
    
    if not raw_response_file.exists():
        return None
    
    try:
        with open(raw_response_file, "r", encoding="utf-8") as f:
            query_result = json.load(f)
        
        # 解析 utterances
        utterances = parse_utterances(query_result)
        
        info(f"使用缓存的 ASR 结果: {raw_response_file}")
        return query_result, utterances
    except Exception as e:
        warning(f"加载缓存失败: {e}，将重新调用 API")
        return None


def run_asr(
    preset: str,
    audio_url: str,
    output_dir: Path,
    appid: Optional[str] = None,
    access_token: Optional[str] = None,
    use_cache: bool = True,
    poll_interval_s: float = 2.0,
    max_wait_s: int = 3600,
) -> Tuple[Dict[str, Any], List]:
    """
    运行 ASR，返回原始响应和 utterances。
    
    如果 use_cache=True 且存在缓存，直接使用缓存结果，否则调用 API。
    
    Args:
        preset: ASR 预设名称
        audio_url: 音频文件 URL
        output_dir: 输出目录（用于保存和查找缓存）
        appid: 应用标识（如果为 None，从环境变量读取）
        access_token: 访问令牌（如果为 None，从环境变量读取）
        use_cache: 是否使用缓存
        poll_interval_s: 轮询间隔（秒）
        max_wait_s: 最大等待时间（秒）
    
    Returns:
        (query_result, utterances)
    
    Raises:
        ValueError: 如果缺少必要的配置
    """
    # 检查缓存
    if use_cache:
        cached = load_cached_result(output_dir, preset)
        if cached is not None:
            return cached
        else:
            # 缓存不存在，需要调用 API，先检查配置
            info(f"缓存不存在，将调用 ASR API (预设: {preset})...")
    
    # 获取配置（只有在需要调用 API 时才需要）
    if appid is None:
        appid = os.getenv("DOUBAO_APPID")
    if access_token is None:
        access_token = os.getenv("DOUBAO_ACCESS_TOKEN")
    
    if not appid:
        raw_response_file = get_response_path(output_dir, preset)
        raise ValueError(
            f"DOUBAO_APPID 环境变量未设置或未提供 appid\n"
            f"缓存文件不存在: {raw_response_file}\n"
            f"需要设置环境变量 DOUBAO_APPID 或通过参数提供 appid 才能调用 API"
        )
    if not access_token:
        raw_response_file = get_response_path(output_dir, preset)
        raise ValueError(
            f"DOUBAO_ACCESS_TOKEN 环境变量未设置或未提供 access_token\n"
            f"缓存文件不存在: {raw_response_file}\n"
            f"需要设置环境变量 DOUBAO_ACCESS_TOKEN 或通过参数提供 access_token 才能调用 API"
        )
    
    # 获取预设配置
    request_config = get_preset(preset)
    
    # 猜测音频格式
    audio_format = guess_audio_format(audio_url)
    
    # 构建完整请求（固定 audio 层关键默认值，确保稳定复现）
    req = DoubaoASRRequest(
        user=UserInfo(uid=str(appid)),  # 使用 appid 作为 uid
        audio=AudioConfig(
            url=audio_url,
            format=audio_format,  # 从 URL 猜测
            language="zh-CN",  # ✅ 固定，确保 ssd_version 生效条件稳定
            rate=16000,  # ✅ 固定
            bits=16,  # ✅ 固定
            channel=1,  # ✅ 固定
            # codec=None  # wav/mp3/ogg 通常不需要
        ),
        request=request_config,
    )
    
    info(f"调用 ASR API (预设: {preset}, format: {audio_format})...")
    client = DoubaoASRClient(app_key=appid, access_key=access_token)
    
    # 提交并轮询
    query_result = client.submit_and_poll(
        req=req,
        resource_id=RESOURCE_ID,
        poll_interval_s=poll_interval_s,
        max_wait_s=max_wait_s,
    )
    
    # 解析结果
    utterances = parse_utterances(query_result)
    
    # 保存原始响应（缓存）
    raw_response_file = get_response_path(output_dir, preset)
    with open(raw_response_file, "w", encoding="utf-8") as f:
        json.dump(query_result, f, indent=2, ensure_ascii=False)
    info(f"已保存原始响应到: {raw_response_file}")
    
    return query_result, utterances
