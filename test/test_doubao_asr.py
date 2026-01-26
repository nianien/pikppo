#!/usr/bin/env python3
"""
豆包大模型版 API 音频转文字测试工具

基于火山引擎大模型录音文件识别 API：
https://www.volcengine.com/docs/6561/1631584?lang=zh

功能：
1. 单个测试：测试单个音频文件，单个预设配置
2. 批量测试：测试多个预设配置，支持并行执行
3. 查询模式：查询已有任务的结果

使用方法:
    # 单个测试（使用默认预设）
    python test/test_doubao_asr.py --llm <音频文件路径或URL> [--preset <预设名>]
    
    # 批量测试所有预设
    python test/test_doubao_asr.py --llm --all-presets <音频文件路径或URL> [--presets <预设列表>] [--parallel]

    # 查询任务结果
    python test/test_doubao_asr.py --llm --query <任务ID>

环境变量:
    DOUBAO_APPID: 应用标识（appid，必填）
    DOUBAO_ACCESS_TOKEN: 访问令牌（access_token，必填）
"""
import os
import sys
import json
import time
import argparse
import requests
from pathlib import Path
from typing import List, Dict, Any, Tuple
from concurrent.futures import ThreadPoolExecutor, as_completed

# 添加项目路径到 sys.path
project_root = Path(__file__).parent.parent
sys.path.insert(0, str(project_root / "src"))


def get_doubao_config():
    """
    获取豆包 API 配置。
    
    Returns:
        (appid, access_token)
    """
    appid = os.getenv("DOUBAO_APPID")
    access_token = os.getenv("DOUBAO_ACCESS_TOKEN")
    
    if not appid:
        raise ValueError(
            "DOUBAO_APPID 环境变量未设置。"
            "请在 .env 文件中设置 DOUBAO_APPID，或使用: export DOUBAO_APPID=your_appid"
        )
    
    if not access_token:
        raise ValueError(
            "DOUBAO_ACCESS_TOKEN 环境变量未设置。"
            "请在 .env 文件中设置 DOUBAO_ACCESS_TOKEN，或使用: export DOUBAO_ACCESS_TOKEN=your_token"
        )
    
    from pikppo.utils.logger import info
    info("豆包 API 配置:")
    info(f"  AppID: {appid}")
    info(f"  Access Token: {access_token[:8]}...{access_token[-4:] if len(access_token) > 12 else ''}")
    
    return appid, access_token


def extract_url_path(url: str) -> str:
    """
    从 URL 中提取路径部分（去掉域名和查询参数）。
    
    例如：
        https://pikppo-video.tos-cn-beijing.volces.com/dbqsfy/1.m4a
        -> dbqsfy/1.m4a
        
        https://example.com/path/to/file.mp3?param=value
        -> path/to/file.mp3
    
    Args:
        url: 完整的 URL
    
    Returns:
        路径部分（不含域名和查询参数）
    """
    from urllib.parse import urlparse
    
    # 去掉查询参数
    url_without_query = url.split("?")[0]
    
    # 解析 URL
    parsed = urlparse(url_without_query)
    
    # 提取路径（去掉开头的 /）
    path = parsed.path.lstrip("/")
    
    return path


def get_audio_url(audio_path_or_url: str) -> str:
    """
    获取音频文件的 URL。
    
    如果输入是 URL，直接返回；如果是本地文件路径，自动上传到 TOS 并返回 URL。
    
    Args:
        audio_path_or_url: 本地音频文件路径或 URL
    
    Returns:
        音频文件的公开访问 URL
    
    Raises:
        FileNotFoundError: 如果文件不存在
        ValueError: 如果无法获取 URL
        RuntimeError: 如果上传失败
    """
    from pikppo.infra.storage.tos import TosStorage
    from pathlib import Path

    # 如果是 URL 直接返回，否则上传到 TOS
    s = str(audio_path_or_url)
    if s.startswith(("http://", "https://")):
        return s
    
    storage = TosStorage()
    return storage.upload(Path(audio_path_or_url))


def get_llm_preset_config(preset: str = "asr_vad_spk"):
    """
    获取大模型版预设配置。
    
    从 doubao_asr.py 加载预设配置（优先从 YAML 文件，否则使用内置预设）。

    Speaker-aware 字幕生成方案：4 套预设（职责明确、正交）

    共同配置（四套全一致）：
    - resource_id: volc.seedasr.auc
    - language: zh-CN
    - enable_speaker_info: true
    - show_utterances: true
    - use_punc: true  # 必须有标点做阅读分隔
    - use_itn: true
    - use_ddc: false

    ASR 预设配置表（只关心模型行为，不关心字幕长短）：

    | 预设名 | VAD | end_window_size | 用途 |
    |--------|-----|------------------|------|
    | asr_vad_spk | ✅ | 750 | VAD + Speaker（默认，所有回归/对照的基线） |
    | asr_vad_spk_sensitive | ✅ | 600 | VAD + Speaker（更敏感，更短的窗口） |
    | asr_vad_spk_smooth | ✅ | 1000 | VAD + Speaker（更稳，更长的窗口） |
    | asr_spk_semantic | ❌ | null | 语义优先（不走 VAD，让模型语义切，但仍保留 speaker） |
    
    注意：后处理策略在运行时组合，不在配置层预组合。
    
    Args:
        preset: ASR 预设名称（默认：asr_vad_spk）
    
    Returns:
        RequestConfig 实例
    """
    from pikppo.models.doubao import get_preset

    return get_preset(preset)




def save_results(
    segments: List[Dict[str, Any]],
    output_dir: Path,
    audio_stem: str,
):
    """
    保存转录结果到文件。
    
    Args:
        segments: segments 列表
        output_dir: 输出目录
        audio_stem: 音频文件名（不含扩展名）
    """
    output_dir.mkdir(parents=True, exist_ok=True)
    
    # 保存 JSON（包含 speaker 信息）
    # 确保所有 segments 都有 speaker 字段（如果缺失则设置为 "unknown"）
    segments_with_speaker = []
    for seg in segments:
        seg_copy = seg.copy()
        if "speaker" not in seg_copy:
            seg_copy["speaker"] = "unknown"
        segments_with_speaker.append(seg_copy)

    json_path = output_dir / f"{audio_stem}-doubao-segments.json"
    with open(json_path, "w", encoding="utf-8") as f:
        json.dump(segments_with_speaker, f, indent=2, ensure_ascii=False)
    from pikppo.utils.logger import info
    info(f"保存 JSON（含 speaker 信息）: {json_path}")
    
    # 保存 SRT
    srt_path = output_dir / f"{audio_stem}.srt"
    try:
        from pikppo.utils.timecode import write_srt_from_segments
        write_srt_from_segments(segments, str(srt_path), text_key="text")
        info(f"保存 SRT: {srt_path}")
    except Exception as e:
        from pikppo.utils.logger import warning
        warning(f"保存 SRT 失败: {e}")
        # 如果工具函数失败，手动生成 SRT
        with open(srt_path, "w", encoding="utf-8") as f:
            for idx, seg in enumerate(segments, 1):
                start = seg.get("start", 0.0)
                end = seg.get("end", 0.0)
                text = seg.get("text", "")
                
                # 转换为 SRT 时间格式 (HH:MM:SS,mmm)
                def format_time(seconds):
                    hours = int(seconds // 3600)
                    minutes = int((seconds % 3600) // 60)
                    secs = int(seconds % 60)
                    millis = int((seconds % 1) * 1000)
                    return f"{hours:02d}:{minutes:02d}:{secs:02d},{millis:03d}"
                
                f.write(f"{idx}\n")
                f.write(f"{format_time(start)} --> {format_time(end)}\n")
                f.write(f"{text}\n\n")
        info(f"手动保存 SRT: {srt_path}")
    
    # 打印统计信息
    if segments:
        total_duration = max(seg.get("end", 0.0) for seg in segments)
        total_chars = sum(len(seg.get("text", "")) for seg in segments)
        from pikppo.utils.logger import info, warning
        info("统计信息:")
        info(f"  片段数: {len(segments)}")
        info(f"  总时长: {total_duration:.2f}s")
        info(f"  总字数: {total_chars}")
        if total_duration > 0:
            info(f"  语速: {total_chars / total_duration:.1f} 字/秒")
        else:
            warning("未生成任何字幕片段")


# ============================================================================
# 批量测试功能（从 test_all_presets.py 合并）
# ============================================================================

# 所有可用的预设（从 doubao_asr.py 动态获取）
def get_all_presets() -> List[str]:
    """获取所有可用的预设名称"""
    from pikppo.models.doubao import get_presets
    return sorted(get_presets().keys())


ALL_PRESETS = get_all_presets()


def _run_asr_once(
        preset: str,
        audio_url: str,
        appid: str,
        access_token: str,
) -> Tuple[Dict[str, Any], List]:
    """
    运行 ASR 一次，返回原始响应和 utterances。
    
    用于优化：相同 ASR 预设只调用一次 API。
    
    Returns:
        (query_result, utterances)
    """
    from pikppo.models.doubao import (
        DoubaoASRClient,
        guess_audio_format,
        parse_utterances,
        RESOURCE_ID,
    )
    from pikppo.models.doubao.request_types import (
        DoubaoASRRequest,
        AudioConfig,
        UserInfo,
    )
    from pikppo.utils.logger import info
    
    # 获取预设配置
    request_config = get_llm_preset_config(preset)
    
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
        poll_interval_s=2.0,
        max_wait_s=3600,
    )
    
    # 解析结果（获取原始 utterances）
    utterances = parse_utterances(query_result)
    
    return query_result, utterances


def test_single_preset(
        preset: str,
        audio_url: str,
        appid: str,
        access_token: str,
        output_dir: Path,
        postprofile: str = "axis",  # 后处理策略（运行时组合）
        query_result: Dict[str, Any] = None,  # 可选：如果提供，跳过 ASR 调用
        utterances: List = None,  # 可选：如果提供，跳过 ASR 调用
) -> Dict[str, Any]:
    """
    测试单个预设配置。
    
    Args:
        preset: 预设名称
        audio_url: 音频文件 URL
        appid: 应用标识
        access_token: 访问令牌
        output_dir: 输出目录
    
    Returns:
        测试结果字典
    """
    start_time = time.time()
    result = {
        "preset": f"{preset}_{postprofile}",  # 组合名称（仅用于显示）
        "asr_preset": preset,  # ASR 预设
        "postprofile": postprofile,  # 后处理策略
        "status": "pending",
        "error": None,
        "task_id": None,
        "duration": 0,
        "segment_count": 0,
        "output_file": None,
    }

    try:
        from pikppo.utils.logger import info
        print(f"\n{'=' * 60}")
        info(f"测试预设: {preset}")
        print(f"{'=' * 60}")

        # 获取预设配置
        preset_config = get_llm_preset_config(preset)
        print(f"   ASR preset: {preset}")
        print(f"   Postprofile: {postprofile}")
        from pikppo.models.doubao import RESOURCE_ID
        print(f"   配置: {RESOURCE_ID}")
        print(f"   VAD: {preset_config.vad_segment}")
        if preset_config.end_window_size:
            print(f"   end_window_size: {preset_config.end_window_size}ms")

        # 如果提供了 query_result 和 utterances，跳过 ASR 调用（优化：相同 ASR 预设只调用一次）
        if query_result is None or utterances is None:
            query_result, utterances = _run_asr_once(preset, audio_url, appid, access_token)
        else:
            info(f"复用 ASR 结果（预设: {preset}）...")
        
        # 运行时组合：应用后处理策略
        from pikppo.models.doubao import speaker_aware_postprocess
        from pikppo.models.doubao.types import Utterance
        
        info(f"应用后处理策略: {postprofile}")
        postprocessed_segments = speaker_aware_postprocess(utterances, profile_name=postprofile)
        
        # 转换为标准格式（时间单位为秒，包含 speaker）
        segments = [
            {
                "start": seg.start_ms / 1000.0,  # 毫秒转秒
                "end": seg.end_ms / 1000.0,
                "text": seg.text.strip(),
                "speaker": seg.speaker,
            }
            for seg in postprocessed_segments
        ]

        result["segment_count"] = len(segments)

        # 检查是否有 speaker 信息
        has_speaker = any(seg.get("speaker") and seg.get("speaker") != "unknown" for seg in segments)
        if has_speaker:
            speaker_count = len(
                set(seg.get("speaker", "unknown") for seg in segments if seg.get("speaker") != "unknown"))
            from pikppo.utils.logger import info, warning
            info(f"检测到 {speaker_count} 个不同的 speaker")
        else:
            warning("警告：未检测到 speaker 信息")

        # 保存结果
        output_dir.mkdir(parents=True, exist_ok=True)
        
        # 原始响应数据以 ASR 预设名称命名（相同 ASR 预设只保存一次）
        raw_response_file = output_dir / f"{preset}-raw-response.json"
        if not raw_response_file.exists():  # 只在第一次保存原始响应
            with open(raw_response_file, "w", encoding="utf-8") as f:
                json.dump(query_result, f, indent=2, ensure_ascii=False)
            info(f"已保存原始响应到: {raw_response_file}")
        else:
            info(f"原始响应已存在，跳过保存: {raw_response_file}")

        # segments 和 srt 以策略组合下划线命名
        combo_prefix = f"{preset}_{postprofile}"  # 下划线组合：asr_vad_spk_axis

        # 保存 segments JSON（含 speaker）
        segments_file = output_dir / f"{combo_prefix}-segments.json"
        with open(segments_file, "w", encoding="utf-8") as f:
            json.dump(segments, f, indent=2, ensure_ascii=False)
        info(f"已保存 segments（含 speaker）到: {segments_file}")

        # 保存 SRT（不含 speaker）
        segments_no_speaker = [
            {
                "start": seg.get("start", 0.0),
                "end": seg.get("end", 0.0),
                "text": seg.get("text", ""),
            }
            for seg in segments
        ]
        srt_path = output_dir / f"{combo_prefix}.srt"
        try:
            from pikppo.utils.timecode import write_srt_from_segments
            write_srt_from_segments(segments_no_speaker, str(srt_path), text_key="text")
            info(f"已保存 SRT 到: {srt_path}")
        except Exception as e:
            from pikppo.utils.logger import warning
            warning(f"保存 SRT 失败: {e}")

        result["output_file"] = str(srt_path)
        result["raw_response_file"] = str(raw_response_file)
        result["segments_file"] = str(segments_file)
        result["status"] = "success"
        result["duration"] = time.time() - start_time
        result["asr_preset"] = preset  # 记录 ASR 预设
        result["postprofile"] = postprofile  # 记录后处理策略

        from pikppo.utils.logger import success
        success(f"组合测试完成 (ASR: {preset}, Post: {postprofile})")
        info(f"  片段数: {len(segments)}")
        info(f"  耗时: {result['duration']:.2f} 秒")
        info(f"  输出文件: {result['output_file']}")

    except Exception as e:
        result["status"] = "error"
        error_str = str(e)
        result["error"] = error_str
        result["duration"] = time.time() - start_time
        
        # 尝试从异常中提取 task_id
        if hasattr(e, 'task_id'):
            result["task_id"] = e.task_id
        else:
            # 尝试从错误信息中提取 task_id（X-Api-Request-Id）
            import re
            match = re.search(r"'X-Api-Request-Id':\s*'([^']+)'", error_str)
            if match:
                result["task_id"] = match.group(1)
        
        from pikppo.utils.logger import error
        error(f"预设 {preset} 测试失败: {error_str}")
        if result.get("task_id"):
            print(f"   任务 ID: {result['task_id']}")
        # 打印完整错误信息以便调试
        import traceback
        print(f"   详细错误信息:")
        traceback.print_exc()
    
    return result
            

def test_all_presets(
        audio_url: str,
        presets: List[str],
        output_dir: Path,
        postprofiles: List[str] = None,  # 后处理策略列表（如果为 None，使用默认 ["axis"]）
        parallel: bool = False,
        max_workers: int = 3,
) -> List[Dict[str, Any]]:
    """
    测试所有预设配置（运行时组合 ASR 预设 × 后处理策略）。
    
    优化：相同 ASR 预设只调用一次 API，原始响应以 ASR 预设命名。
    segments 和 srt 以策略组合下划线命名。
    
    组合是"使用时的选择"，不是"配置里的实体"。
    不命名组合，只显示 ASR preset 和 Postprofile。
    
    Args:
        audio_url: 音频文件 URL
        presets: ASR 预设列表
        output_dir: 输出目录
        postprofiles: 后处理策略列表（如果为 None，使用默认 ["axis"]）
        parallel: 是否并行执行（注意：ASR 调用会按预设分组，但后处理可以并行）
        max_workers: 并行执行时的最大工作线程数
    
    Returns:
        所有测试结果列表
    """
    # 加载环境变量
    from pikppo import load_env_file
    load_env_file()
    
    # 获取配置
    appid, access_token = get_doubao_config()
    
    # 默认后处理策略
    if postprofiles is None:
        postprofiles = ["axis"]
    
    # 生成组合矩阵（不命名组合）
    from pikppo.models.doubao import POSTPROFILES
    available_postprofiles = list(POSTPROFILES.keys())
    
    # 验证后处理策略是否存在
    for postprofile in postprofiles:
        if postprofile not in available_postprofiles:
            from pikppo.utils.logger import warning
            warning(f"未知的后处理策略: {postprofile}，可用策略: {', '.join(available_postprofiles)}")
            warning(f"使用默认策略: axis")
            postprofiles = ["axis"]
            break
        
    print(f"\n{'=' * 60}")
    print(f"🚀 开始测试 ASR 预设 × 后处理策略组合")
    print(f"{'=' * 60}")
    print(f"ASR 预设: {', '.join(presets)}")
    print(f"后处理策略: {', '.join(postprofiles)}")
    print(f"总组合数: {len(presets) * len(postprofiles)}")
    print(f"音频 URL: {audio_url}")
    print(f"输出目录: {output_dir}")
    print(f"执行模式: {'并行' if parallel else '串行'}")
    print(f"优化: 相同 ASR 预设只调用一次 API")
    if parallel:
        print(f"最大并发数: {max_workers}")

    results = []
    
    # 优化：按 ASR 预设分组，相同预设只调用一次 API
    asr_results_cache = {}  # {preset: (query_result, utterances)}
    
    # 第一步：对每个唯一的 ASR 预设调用一次 API
    from pikppo.utils.logger import info
    unique_presets = list(set(presets))
    info(f"需要调用 ASR API 的预设数: {len(unique_presets)} (去重后)")
    
    for preset in unique_presets:
        try:
            info(f"调用 ASR API (预设: {preset})...")
            query_result, utterances = _run_asr_once(preset, audio_url, appid, access_token)
            asr_results_cache[preset] = (query_result, utterances)
            info(f"✅ ASR 预设 {preset} 调用成功，已缓存结果")
        except Exception as e:
            from pikppo.utils.logger import error
            error(f"❌ ASR 预设 {preset} 调用失败: {e}")
            # 即使失败也记录，后续会跳过
            asr_results_cache[preset] = (None, None)
    
    # 第二步：生成所有组合，复用 ASR 结果
    test_cases = [
        (preset, postprofile)
        for preset in presets
        for postprofile in postprofiles
    ]
    
    # 过滤掉 ASR 调用失败的组合
    valid_test_cases = [
        (preset, postprofile)
        for preset, postprofile in test_cases
        if asr_results_cache.get(preset, (None, None))[0] is not None
    ]
    
    if len(valid_test_cases) < len(test_cases):
        from pikppo.utils.logger import warning
        warning(f"跳过 {len(test_cases) - len(valid_test_cases)} 个无效组合（ASR 调用失败）")

    if parallel:
        # 并行执行后处理（ASR 结果已缓存）
        with ThreadPoolExecutor(max_workers=max_workers) as executor:
            futures = {
                executor.submit(
                    test_single_preset,
                    preset,
                    audio_url,
                    appid,
                    access_token,
                    output_dir,
                    postprofile,
                    query_result=asr_results_cache[preset][0],  # 复用 ASR 结果
                    utterances=asr_results_cache[preset][1],     # 复用 ASR 结果
                ): (preset, postprofile)
                for preset, postprofile in valid_test_cases
            }

            for future in as_completed(futures):
                preset, postprofile = futures[future]
                try:
                    result = future.result()
                    results.append(result)
                except Exception as e:
                    from pikppo.utils.logger import error
                    error(f"组合 (ASR: {preset}, Post: {postprofile}) 执行异常: {e}")
                    results.append({
                        "preset": f"{preset}_{postprofile}",  # 仅用于显示
                        "status": "error",
                        "error": str(e),
                        "duration": 0,
                    })
    else:
        # 串行执行后处理（ASR 结果已缓存）
        for preset, postprofile in valid_test_cases:
            result = test_single_preset(
                preset,
                audio_url,
                appid,
                access_token,
                output_dir,
                postprofile,
                query_result=asr_results_cache[preset][0],  # 复用 ASR 结果
                utterances=asr_results_cache[preset][1],     # 复用 ASR 结果
            )
            results.append(result)

    return results


def test_6_groups(
        audio_url: str,
        test_cases: List[Tuple[str, str]],  # [(preset, postprofile), ...]
        output_dir: Path,
        parallel: bool = False,
        max_workers: int = 3,
) -> List[Dict[str, Any]]:
    """
    测试6组推荐组合（特定组合，不是全组合）。
    
    Args:
        audio_url: 音频文件 URL
        test_cases: 测试组合列表 [(preset, postprofile), ...]
        output_dir: 输出目录
        parallel: 是否并行执行
        max_workers: 并行执行时的最大工作线程数
    
    Returns:
        所有测试结果列表
    """
    # 加载环境变量
    from pikppo import load_env_file
    load_env_file()
    
    # 获取配置
    appid, access_token = get_doubao_config()
    
    from pikppo.utils.logger import info
    print(f"\n{'=' * 60}")
    print(f"🚀 开始测试6组推荐组合")
    print(f"{'=' * 60}")
    print(f"总组合数: {len(test_cases)}")
    print(f"音频 URL: {audio_url}")
    print(f"输出目录: {output_dir}")
    print(f"执行模式: {'并行' if parallel else '串行'}")
    if parallel:
        print(f"最大并发数: {max_workers}")
    
    # 按 ASR 预设分组，相同预设只调用一次 API
    asr_results_cache = {}
    unique_presets = list(set(preset for preset, _ in test_cases))
    info(f"需要调用 ASR API 的预设数: {len(unique_presets)} (去重后)")
    
    for preset in unique_presets:
        try:
            info(f"调用 ASR API (预设: {preset})...")
            query_result, utterances = _run_asr_once(preset, audio_url, appid, access_token)
            asr_results_cache[preset] = (query_result, utterances)
            info(f"✅ ASR 预设 {preset} 调用成功，已缓存结果")
        except Exception as e:
            from pikppo.utils.logger import error
            error(f"❌ ASR 预设 {preset} 调用失败: {e}")
            asr_results_cache[preset] = (None, None)
    
    # 过滤掉 ASR 调用失败的组合
    valid_test_cases = [
        (preset, postprofile)
        for preset, postprofile in test_cases
        if asr_results_cache.get(preset, (None, None))[0] is not None
    ]
    
    if len(valid_test_cases) < len(test_cases):
        from pikppo.utils.logger import warning
        warning(f"跳过 {len(test_cases) - len(valid_test_cases)} 个无效组合（ASR 调用失败）")
    
    results = []
    
    if parallel:
        # 并行执行后处理（ASR 结果已缓存）
        with ThreadPoolExecutor(max_workers=max_workers) as executor:
            futures = {
                executor.submit(
                    test_single_preset,
                    preset,
                    audio_url,
                    appid,
                    access_token,
                    output_dir,
                    postprofile,
                    query_result=asr_results_cache[preset][0],
                    utterances=asr_results_cache[preset][1],
                ): (preset, postprofile)
                for preset, postprofile in valid_test_cases
            }
            
            for future in as_completed(futures):
                preset, postprofile = futures[future]
                try:
                    result = future.result()
                    results.append(result)
                except Exception as e:
                    from pikppo.utils.logger import error
                    error(f"组合 (ASR: {preset}, Post: {postprofile}) 执行异常: {e}")
                    results.append({
                        "preset": f"{preset}_{postprofile}",
                        "status": "error",
                        "error": str(e),
                        "duration": 0,
                    })
    else:
        # 串行执行后处理（ASR 结果已缓存）
        for preset, postprofile in valid_test_cases:
            result = test_single_preset(
                preset,
                audio_url,
                appid,
                access_token,
                output_dir,
                postprofile,
                query_result=asr_results_cache[preset][0],
                utterances=asr_results_cache[preset][1],
            )
            results.append(result)
    
    return results


def print_summary(results: List[Dict[str, Any]]):
    """打印测试结果摘要。"""
    from pikppo.utils.logger import success, error, info
    
    print(f"\n{'=' * 60}")
    print(f"📊 测试结果摘要")
    print(f"{'=' * 60}")

    # 统计
    total = len(results)
    success_count = sum(1 for r in results if r["status"] == "success")
    failed_count = sum(1 for r in results if r["status"] == "error")

    print(f"\n总计: {total} 个预设")
    print(f"成功: {success_count} 个")
    print(f"失败: {failed_count} 个")

    if success_count > 0:
        success("成功的组合:")
        for r in results:
            if r["status"] == "success":
                asr_preset = r.get("asr_preset", r.get("preset", "unknown"))
                postprofile = r.get("postprofile", "unknown")
                print(
                    f"  - ASR: {asr_preset:20s} | Post: {postprofile:15s} | 条数: {r['segment_count']:4d} | 耗时: {r['duration']:6.2f}s | {r['output_file']}")

    if failed_count > 0:
        error("失败的组合:")
        for r in results:
            if r["status"] == "error":
                asr_preset = r.get("asr_preset", r.get("preset", "unknown"))
                postprofile = r.get("postprofile", "unknown")
                error_msg = r.get('error', 'Unknown')
                # 直接显示完整的 API 返回错误信息（不猜测，不简化）
                print(f"  - ASR: {asr_preset:20s} | Post: {postprofile:15s} | 错误: {error_msg}")
                if r.get('task_id'):
                    print(f"   任务 ID: {r['task_id']}")
                    print(f"   提示: 可以稍后使用以下命令查询:")
                    print(f"   python test_doubao_asr.py --llm --query {r['task_id']}")

    # 保存结果到 JSON
    if results:
        # 找到第一个有 output_file 的结果，或者使用输出目录
        output_dir = None
        for r in results:
            if r.get("output_file"):
                output_dir = Path(r["output_file"]).parent
                break

        # 如果没有找到，使用默认输出目录
        if not output_dir:
            output_dir = Path("doubao_test")

        summary_file = output_dir / "test_summary.json"
        with open(summary_file, "w", encoding="utf-8") as f:
            json.dump(results, f, indent=2, ensure_ascii=False)
        info(f"详细结果已保存到: {summary_file}")


def main():
    """主函数 - 统一的命令行接口"""
    parser = argparse.ArgumentParser(
        description="豆包大模型版 API 音频转文字测试工具",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
使用模式:

1. 默认测试模式（推荐）:
   python test_doubao_asr.py --llm <音频文件路径或URL>
   默认测试以下策略组合：
   - asr_vad_spk + {axis, axis_default, axis_soft}
   - asr_vad_spk_smooth + {axis_soft}
   - asr_spk_semantic + {axis}

2. 单个测试模式:
   python test_doubao_asr.py --llm <音频文件路径或URL> [--preset <预设名>]

3. 批量测试模式:
   python test_doubao_asr.py --llm --all-presets <音频文件路径或URL> [--presets <预设列表>] [--parallel]

4. 查询模式:
   python test_doubao_asr.py --llm --query <任务ID>

示例:
  # 默认测试（推荐，测试所有默认策略组合）
  python test_doubao_asr.py --llm https://your-bucket.com/audio.wav

  # 单个测试（指定 ASR 预设，使用默认后处理策略 axis）
  python test_doubao_asr.py --llm audio.wav --preset asr_vad_spk

  # 批量测试所有 ASR 预设 × 后处理策略组合
  python test_doubao_asr.py --llm --all-presets https://your-bucket.com/audio.wav

  # 测试5组推荐组合（只测试这5组，不是全组合）
  python test_doubao_asr.py --llm --all-presets audio.wav --test-6-groups

  # 批量测试指定组合（注意：这会生成全排列组合，4个preset × 3个postprofile = 12组）
  # python test_doubao_asr.py --llm --all-presets audio.wav --presets asr_vad_spk asr_vad_spk_sensitive asr_vad_spk_smooth asr_spk_semantic --postprofiles axis axis_default axis_soft

  # 批量测试指定组合（并行，少量组合）
  python test_doubao_asr.py --llm --all-presets audio.wav --presets asr_vad_spk asr_spk_semantic --postprofiles axis axis_soft --parallel

  # 查询任务结果
  python test_doubao_asr.py --llm --query 9b20c23a-ca0a-4dcc-a5f6-7ed82240e5fa

环境变量:
  DOUBAO_APPID: 应用标识（必填）
  DOUBAO_ACCESS_TOKEN: 访问令牌（必填）
        """
    )

    parser.add_argument(
        "--llm",
        action="store_true",
        help="使用大模型版 API（必填）"
    )

    parser.add_argument(
        "audio",
        nargs="?",
        help="音频文件路径或 URL（默认测试模式必需，单个测试模式必需，批量测试模式可选）"
    )

    parser.add_argument(
        "--url",
        type=str,
        help="音频文件 URL（批量测试模式，如果未提供 audio 参数，使用此 URL 或默认 URL）"
    )

    parser.add_argument(
        "--preset",
        type=str,
        default="axis",
        help="预设配置名称（单个测试模式，默认: axis）"
    )

    parser.add_argument(
        "--all-presets",
        action="store_true",
        help="批量测试模式：测试多个预设配置（如果不指定此参数且只传入 URL，则使用默认策略组合）"
    )

    parser.add_argument(
        "--test-6-groups",
        action="store_true",
        help="测试5组推荐组合（只测试这5组特定组合，不是全排列）: "
             "1. asr_vad_spk+axis, 2. asr_vad_spk+axis_default, 3. asr_vad_spk+axis_soft, "
             "4. asr_vad_spk_smooth+axis_soft, 5. asr_spk_semantic+axis. "
             "使用此参数时会忽略 --presets 和 --postprofiles"
    )

    parser.add_argument(
        "--presets",
        nargs="+",
        choices=ALL_PRESETS,
        default=ALL_PRESETS,
        help=f"要测试的预设列表（批量测试模式，默认: {', '.join(ALL_PRESETS)}）"
    )

    parser.add_argument(
        "--postprofiles",
        nargs="+",
        default=None,
        help="后处理策略列表（批量测试模式，默认: ['axis']）"
    )

    parser.add_argument(
        "--query",
        type=str,
        metavar="TASK_ID",
        help="查询模式：查询已有任务的结果（任务 ID）"
    )

    parser.add_argument(
        "--output-dir",
        type=str,
        default="doubao_test",
        help="输出目录（默认: doubao_test）"
    )

    parser.add_argument(
        "--parallel",
        action="store_true",
        help="并行执行（批量测试模式，更快，但可能受 API 限流影响）"
    )

    parser.add_argument(
        "--max-workers",
        type=int,
        default=3,
        help="并行执行时的最大工作线程数（默认: 3）"
    )

    args = parser.parse_args()

    # 检查是否使用大模型版
    if not args.llm:
        parser.error("必须使用 --llm 参数")

    # 提前导入 logger，确保异常处理时可用
    from pikppo.utils.logger import info, success, error, warning

    # 加载环境变量
    from pikppo import load_env_file
    load_env_file()
    
    try:
        # 模式1: 查询模式（不需要音频参数，先处理）
        if args.query:
            # 获取豆包 API 配置
            appid, access_token = get_doubao_config()
            
            from pikppo.models.doubao import DoubaoASRClient
            
            from pikppo.utils.logger import info
            info(f"查询任务结果（大模型版，Task ID: {args.query}）...")
            
            # 查询时直接使用默认的 resource_id（所有预设都使用 volc.seedasr.auc）
            resource_id = "volc.seedasr.auc"
            
            # 使用 DoubaoASRClient 查询
            client = DoubaoASRClient(app_key=appid, access_key=access_token)
            result = client.query(args.query, resource_id)
            
            # 检查任务是否完成
            result_data = result.get("result", {})
            if not result_data.get("utterances"):
                # 任务可能还在处理中，需要轮询
                import time
                max_wait_s = 3600
                poll_interval_s = 2.0
                deadline = time.time() + max_wait_s
                
                while time.time() < deadline:
                    result = client.query(args.query, resource_id)
                    result_data = result.get("result", {})
                    if result_data.get("utterances"):
                        break
                    time.sleep(poll_interval_s)
                else:
                    raise TimeoutError(f"任务查询超时：在 {max_wait_s} 秒内未完成")
            
            # 解析结果
            from pikppo.models.doubao import parse_utterances
            utterances = parse_utterances(result)
            segments = [
                {
                    "start": utt.start_ms / 1000.0,  # 转换为秒
                    "end": utt.end_ms / 1000.0,
                    "text": utt.text.strip(),
                }
                for utt in utterances
            ]
            
            # 打印完整文本
            full_text = " ".join(seg.get("text", "") for seg in segments)
            info("转录文本:")
            print("=" * 60)
            print(full_text)
            print("=" * 60)
            
            # 保存结果
            output_dir = Path(args.output_dir)
            prefix = "llm-query"
            save_results(segments, output_dir, f"{prefix}-{args.query}")
            
            from pikppo.utils.logger import success
            success(f"查询完成！结果保存在: {output_dir}")
            return
        
        # 模式2: 批量测试模式
        if args.all_presets:
            # 先检查参数，再获取 API 配置（避免不必要的配置输出）
            if not args.url and not args.audio:
                from pikppo.utils.logger import error, info
                error("批量测试模式需要提供音频文件路径或 URL")
                print()
                info("使用方式：")
                print("  方式 1: 使用位置参数（推荐）")
                print("    python test/test_doubao_asr.py --llm --all-presets <音频文件路径或URL>")
                print()
                print("  方式 2: 使用 --url 参数")
                print("    python test/test_doubao_asr.py --llm --all-presets --url <音频URL>")
                print()
                print("  示例：")
                print("    python test/test_doubao_asr.py --llm --all-presets audio.mp3")
                print("    python test/test_doubao_asr.py --llm --all-presets --url https://example.com/audio.mp3")
                sys.exit(1)
            
            # 获取豆包 API 配置
            appid, access_token = get_doubao_config()
            
            # 确定音频 URL：优先使用 --url，其次使用 audio 参数
            if args.url:
                audio_url = args.url.strip()
            else:
                audio_url = get_audio_url(args.audio)

            # 根据 URL 构建输出目录
            if audio_url.startswith(("http://", "https://")):
                url_path = extract_url_path(audio_url)
                output_dir = Path(args.output_dir) / url_path
            else:
                output_dir = Path(args.output_dir)

            # 如果指定了 --test-6-groups，使用6组推荐组合（只测试这6组，不是全排列）
            if args.test_6_groups:
                from pikppo.utils.logger import info, warning
                if args.presets != ALL_PRESETS or args.postprofiles is not None:
                    warning("使用 --test-6-groups 时，--presets 和 --postprofiles 参数将被忽略")
                info("使用5组推荐测试组合（只测试这5组特定组合，不是全排列）...")
                # 5组组合（不是全组合，而是特定组合）：
                # 1. asr_vad_spk + axis
                # 2. asr_vad_spk + axis_default
                # 3. asr_vad_spk + axis_soft
                # 4. asr_vad_spk_smooth + axis_soft
                # 5. asr_spk_semantic + axis
                test_6_groups_cases = [
                    ("asr_vad_spk", "axis"),
                    ("asr_vad_spk", "axis_default"),
                    ("asr_vad_spk", "axis_soft"),
                    ("asr_vad_spk_smooth", "axis_soft"),
                    ("asr_spk_semantic", "axis"),
                ]
                info(f"将测试 {len(test_6_groups_cases)} 组特定组合（不是全排列）")
                
                # 使用 test_6_groups 函数，只测试这6组特定组合
                results = test_6_groups(
                    audio_url=audio_url,
                    test_cases=test_6_groups_cases,
                    output_dir=output_dir,
                    parallel=args.parallel,
                    max_workers=args.max_workers,
                )
            else:
                # 执行批量测试（运行时组合，会生成全排列）
                from pikppo.utils.logger import warning
                if len(args.presets) > 1 and args.postprofiles and len(args.postprofiles) > 1:
                    total_combinations = len(args.presets) * len(args.postprofiles)
                    warning(f"将生成 {total_combinations} 组全排列组合（{len(args.presets)} 个预设 × {len(args.postprofiles)} 个后处理策略）")
                    warning("如果只想测试6组推荐组合，请使用 --test-6-groups 参数")
                
                results = test_all_presets(
                    audio_url=audio_url,
                    presets=args.presets,
                    postprofiles=args.postprofiles,
                    output_dir=output_dir,
                    parallel=args.parallel,
                    max_workers=args.max_workers,
                )

            # 打印摘要
            print_summary(results)

            # 返回退出码
            failed_count = sum(1 for r in results if r["status"] == "error")
            sys.exit(0 if failed_count == 0 else 1)

        # 模式2.5: 默认测试模式（只传入 URL，使用默认策略组合）
        # 如果只传入了 audio/url，没有 --all-presets，使用默认策略组合
        if (args.audio or args.url) and not args.all_presets:
            # 获取豆包 API 配置
            appid, access_token = get_doubao_config()
            
            # 确定音频 URL：优先使用 --url，其次使用 audio 参数
            if args.url:
                audio_url = args.url.strip()
            else:
                audio_url = get_audio_url(args.audio)

            # 根据 URL 构建输出目录
            if audio_url.startswith(("http://", "https://")):
                url_path = extract_url_path(audio_url)
                output_dir = Path(args.output_dir) / url_path
            else:
                output_dir = Path(args.output_dir)

            # 默认策略组合
            default_test_cases = [
                ("asr_vad_spk", "axis"),
                ("asr_vad_spk", "axis_default"),
                ("asr_vad_spk", "axis_soft"),
                ("asr_vad_spk_smooth", "axis_soft"),
                ("asr_spk_semantic", "axis"),
            ]
            
            from pikppo.utils.logger import info
            info("使用默认策略组合测试")
            info(f"将测试 {len(default_test_cases)} 组策略组合")
            
            # 使用 test_6_groups 函数测试默认策略组合
            results = test_6_groups(
                audio_url=audio_url,
                test_cases=default_test_cases,
                output_dir=output_dir,
                parallel=args.parallel,
                max_workers=args.max_workers,
            )

            # 打印摘要
            print_summary(results)

            # 返回退出码
            failed_count = sum(1 for r in results if r["status"] == "error")
            sys.exit(0 if failed_count == 0 else 1)

        # 模式3: 单个测试模式
        if not args.audio:
            from pikppo.utils.logger import error, info
            error("单个测试模式需要提供音频文件路径或 URL")
            print()
            info("使用方式：")
            print("  python test/test_doubao_asr.py --llm <音频文件路径或URL> [--preset <预设名>]")
            print()
            print("  示例：")
            print("    python test/test_doubao_asr.py --llm audio.mp3")
            print("    python test/test_doubao_asr.py --llm https://example.com/audio.mp3 --preset axis")
            sys.exit(1)

        # 获取豆包 API 配置
        appid, access_token = get_doubao_config()
        
        audio_path = args.audio

        # 获取音频 URL（如果是本地文件，自动上传到 TOS）
        audio_url = get_audio_url(audio_path)
        
        # 获取预设配置
        request_config = get_llm_preset_config(args.preset)
        from pikppo.utils.logger import info
        info(f"音频: {audio_url}")
        print(f"   预设配置: {args.preset}")

        # 直接使用 doubao_asr.py 的功能
        from pikppo.models.doubao import (
            DoubaoASRClient,
            guess_audio_format,
            parse_utterances,
            RESOURCE_ID,
        )
        from pikppo.models.doubao.request_types import (
            DoubaoASRRequest,
            AudioConfig,
            UserInfo,
        )
        
        client = DoubaoASRClient(app_key=appid, access_key=access_token)
        
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
        
        # 提交并轮询
        result = client.submit_and_poll(
            req=req,
            resource_id=RESOURCE_ID,
            poll_interval_s=2.0,
            max_wait_s=3600,
        )
        
        # 解析结果（doubao_asr.py 已经返回最终的 segments_with_speaker）
        utterances = parse_utterances(result)
        segments = [
            {
                "start": utt.start_ms / 1000.0,  # 转换为秒
                "end": utt.end_ms / 1000.0,
                "text": utt.text.strip(),
                "speaker": utt.speaker,
            }
            for utt in utterances
        ]
        
        # 保存时移除 speaker（SRT 不需要 speaker）
        segments_no_speaker = [
            {
                "start": seg.get("start", 0.0),
                "end": seg.get("end", 0.0),
                "text": seg.get("text", ""),
            }
            for seg in segments
        ]
        
        # 打印完整文本
        full_text = " ".join(seg.get("text", "") for seg in segments)
        info("转录文本:")
        print("=" * 60)
        print(full_text)
        print("=" * 60)
        
        # 根据 URL 构建输出目录
        if audio_url.startswith(("http://", "https://")):
            url_path = extract_url_path(audio_url)
            output_dir = Path(args.output_dir) / url_path
            # 使用文件名（不含扩展名）作为前缀
            url_filename = Path(url_path).stem or "audio"
            prefix = f"llm-{url_filename}"
        else:
            audio_file = Path(audio_path)
            output_dir = Path(args.output_dir)
            prefix = f"llm-{audio_file.stem}"
        
        save_results(segments_no_speaker, output_dir, prefix)
        
        success(f"测试完成！结果保存在: {output_dir}")
        
    except Exception as e:
        error(f"测试失败: {e}")
        import traceback
        traceback.print_exc()
        sys.exit(1)


if __name__ == "__main__":
    main()
