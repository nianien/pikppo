#!/usr/bin/env python3
"""
测试 ASR 工具模块的使用示例

演示如何使用拆分后的 ASR 运行器和字幕生成器。
"""
import sys
from pathlib import Path

# 添加项目路径
project_root = Path(__file__).parent.parent
sys.path.insert(0, str(project_root / "src"))

from video_remix.pipeline._shared.subtitle import (
    generate_subtitles,
    generate_subtitles_from_preset,
    check_cached_subtitles,
)
from video_remix.pipeline.asr import transcribe


def example_1_check_cache_then_run():
    """示例 1: 检查缓存，如果有就用，没有就调用 API"""
    audio_url = "https://example.com/audio.m4a"
    output_dir = Path("test_output")
    preset = "asr_vad_spk"
    
    # 调用 ASR 服务
    raw_response, utterances = transcribe(
        audio_url=audio_url,
        preset=preset,
    )
    print(f"获取结果: {len(utterances)} 片段")


def example_2_generate_subtitles():
    """示例 2: 生成字幕文件（带缓存检查）"""
    audio_url = "https://example.com/audio.m4a"
    output_dir = Path("test_output")
    video_stem = "audio"  # 从 URL 提取或手动指定
    preset = "asr_vad_spk"
    postprofile = "axis"
    
    # 方式 1: 一站式生成（自动处理 ASR + 字幕生成）
    # 测试工具：使用调试命名用于对比
    debug_video_stem = f"{preset}_{postprofile}"
    files = generate_subtitles_from_preset(
        preset=preset,
        postprofile=postprofile,
        audio_url=audio_url,
        output_dir=output_dir,
        video_stem=debug_video_stem,  # 测试工具使用调试命名
        use_cache=True,  # 会检查 ASR 缓存和字幕缓存
    )
    print(f"生成的文件: {files}")
    
    # 方式 2: 分步生成（先获取 ASR 结果，再生成字幕）
    # client = DoubaoASRClient(app_key=appid, access_key=access_token)
    # query_result, utterances = transcribe(
    #     client=client,
    #     audio_url=audio_url,
    #     preset=preset,
    # )
    # files = generate_subtitles(
    #     utterances=utterances,
    #     preset=preset,
    #     postprofile=postprofile,
    #     output_dir=output_dir,
    #     use_cache=True,
    # )


def example_3_specify_preset():
    """示例 3: 指定模型预设名称生成字幕"""
    audio_url = "https://example.com/audio.m4a"
    output_dir = Path("test_output")
    
    # 可以指定不同的预设
    presets = ["asr_vad_spk", "asr_vad_spk_smooth", "asr_spk_semantic"]
    postprofiles = ["axis", "axis_default", "axis_soft"]
    
    for preset in presets:
        for postprofile in postprofiles:
            # 测试工具：使用调试命名用于对比
            debug_video_stem = f"{preset}_{postprofile}"
            # 检查是否已有字幕文件
            cached = check_cached_subtitles(output_dir, debug_video_stem)
            if cached:
                print(f"跳过 {preset}_{postprofile}（已有缓存）")
                continue
            
            # 生成字幕（会自动检查 ASR 缓存）
            files = generate_subtitles_from_preset(
                preset=preset,
                postprofile=postprofile,
                audio_url=audio_url,
                output_dir=output_dir,
                video_stem=debug_video_stem,  # 测试工具使用调试命名
                use_cache=True,
            )
            print(f"生成 {preset}_{postprofile}: {files}")


if __name__ == "__main__":
    print("这是使用示例，请根据实际需求调用相应的函数")
    print("\n示例 1: 检查缓存然后运行 ASR")
    print("  example_1_check_cache_then_run()")
    print("\n示例 2: 生成字幕文件")
    print("  example_2_generate_subtitles()")
    print("\n示例 3: 指定预设生成字幕")
    print("  example_3_specify_preset()")
