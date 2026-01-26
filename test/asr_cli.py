#!/usr/bin/env python3
"""
ASR 命令行工具：使用拆分后的模块

功能：
1. 根据预设调用 ASR 模型（带缓存）
2. 根据字幕策略生成 segment.json 和 srt 文件（带缓存）
3. 可以指定模型预设名称和字幕策略
"""
import argparse
import sys
from pathlib import Path

# 添加项目路径
project_root = Path(__file__).parent.parent
sys.path.insert(0, str(project_root / "src"))

from pikppo import load_env_file
from pikppo.pipeline.processors.subtitle import (
    generate_subtitles_from_preset,
    check_cached_subtitles,
)
from pikppo.pipeline.processors.asr import transcribe
from pikppo.infra.storage.tos import TosStorage
from pikppo.utils.logger import info, success, error


def extract_url_path(url: str) -> str:
    """从 URL 中提取路径部分（去掉域名和查询参数）。"""
    from urllib.parse import urlparse
    url_without_query = url.split("?")[0]
    parsed = urlparse(url_without_query)
    return parsed.path.lstrip("/")


def main():
    parser = argparse.ArgumentParser(
        description="ASR 命令行工具：调用模型并生成字幕文件",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
使用示例:

1. 生成字幕（自动处理 ASR 和字幕生成，带缓存）:
   python test/asr_cli.py --url <音频URL> --preset asr_vad_spk --postprofile axis

2. 只运行 ASR（不生成字幕）:
   python test/asr_cli.py --url <音频URL> --preset asr_vad_spk --asr-only

3. 检查缓存状态:
   python test/asr_cli.py --url <音频URL> --preset asr_vad_spk --postprofile axis --check-cache

4. 强制重新生成（忽略缓存）:
   python test/asr_cli.py --url <音频URL> --preset asr_vad_spk --postprofile axis --no-cache

5. 批量生成多个策略组合:
   python test/asr_cli.py --url <音频URL> --preset asr_vad_spk --postprofiles axis axis_default axis_soft

6. 使用本地文件（自动上传）:
   python test/asr_cli.py --file audio.mp3 --preset asr_vad_spk --postprofile axis

环境变量:
  DOUBAO_APPID: 应用标识（必填）
  DOUBAO_ACCESS_TOKEN: 访问令牌（必填）
        """
    )

    parser.add_argument(
        "--url",
        type=str,
        help="音频文件 URL"
    )

    parser.add_argument(
        "--file",
        type=str,
        help="本地音频文件路径（会自动上传到 TOS）"
    )

    parser.add_argument(
        "--preset",
        type=str,
        default=None,
        help="ASR 预设名称，支持逗号分隔的多个预设（例如: asr_vad_spk 或 asr_vad_spk,asr_vad_spk_smooth）。不传则执行所有预设"
    )

    parser.add_argument(
        "--postprofile",
        type=str,
        help="字幕策略名称（例如: axis, axis_default, axis_soft）。如果指定，会生成字幕文件"
    )

    parser.add_argument(
        "--postprofiles",
        nargs="+",
        help="多个字幕策略名称（批量生成）"
    )

    parser.add_argument(
        "--output-dir",
        type=str,
        default="doubao_test",
        help="输出目录（默认: doubao_test）"
    )

    parser.add_argument(
        "--asr-only",
        action="store_true",
        help="只运行 ASR，不生成字幕文件"
    )

    parser.add_argument(
        "--check-cache",
        action="store_true",
        help="只检查缓存状态，不执行任何操作"
    )

    parser.add_argument(
        "--no-cache",
        action="store_true",
        help="忽略缓存，强制重新生成"
    )

    args = parser.parse_args()

    # 加载环境变量
    load_env_file()

    # 检查参数
    if not args.url and not args.file:
        parser.error("必须提供 --url 或 --file 参数")

    if args.url and args.file:
        parser.error("不能同时提供 --url 和 --file 参数")

    if args.postprofile and args.postprofiles:
        parser.error("不能同时提供 --postprofile 和 --postprofiles 参数")

    if args.asr_only and (args.postprofile or args.postprofiles):
        parser.error("--asr-only 不能与 --postprofile/--postprofiles 同时使用")

    # 获取音频 URL
    if args.file:
        info(f"处理本地文件: {args.file}")
        # 如果是 URL 直接使用，否则上传到 TOS
        file_str = str(args.file)
        if file_str.startswith(("http://", "https://")):
            audio_url = file_str
        else:
            storage = TosStorage()
            audio_url = storage.upload(Path(args.file))
        info(f"音频 URL: {audio_url}")
    else:
        audio_url = args.url.strip()

    # 根据 URL 构建输出目录
    if audio_url.startswith(("http://", "https://")):
        url_path = extract_url_path(audio_url)
        output_dir = Path(args.output_dir) / url_path
    else:
        output_dir = Path(args.output_dir)

    output_dir.mkdir(parents=True, exist_ok=True)
    info(f"输出目录: {output_dir}")

    use_cache = not args.no_cache

    # 解析预设列表（支持逗号分隔，不传则使用所有预设）
    if args.preset:
        presets = [p.strip() for p in args.preset.split(",") if p.strip()]
        if not presets:
            parser.error("--preset 参数不能为空")
    else:
        # 获取所有可用预设
        from pikppo.models.doubao import get_presets
        presets = sorted(get_presets().keys())
        info(f"未指定预设，将执行所有预设: {', '.join(presets)}")

    # 检查缓存模式
    if args.check_cache:
        info("检查缓存状态...")
        
        # 从 URL 提取视频文件名（用于检查缓存）
        video_stem = extract_url_path(audio_url).split("/")[-1].rsplit(".", 1)[0] if audio_url else "test"
        if not video_stem or video_stem == "test":
            video_stem = "test"  # 默认值
        
        for preset in presets:
            # 检查 ASR 缓存（通过 adapter 的缓存路径）
            cache_path = output_dir / f"{preset}-response.json"
            if cache_path.exists():
                success(f"✓ ASR 结果已缓存: {preset}-response.json")
            else:
                info(f"✗ ASR 结果未缓存: {preset}")
            
            # 检查字幕缓存（测试工具：保留 preset_postprofile 命名用于调试对比）
            if args.postprofile:
                # 测试工具使用调试命名
                debug_name = f"{preset}_{args.postprofile}"
                cached_sub = check_cached_subtitles(output_dir, debug_name)
                if cached_sub:
                    success(f"✓ 字幕文件已缓存: {debug_name}")
                else:
                    info(f"✗ 字幕文件未缓存: {debug_name}")
            elif args.postprofiles:
                for postprofile in args.postprofiles:
                    debug_name = f"{preset}_{postprofile}"
                    cached_sub = check_cached_subtitles(output_dir, debug_name)
                    if cached_sub:
                        success(f"✓ 字幕文件已缓存: {debug_name}")
                    else:
                        info(f"✗ 字幕文件未缓存: {debug_name}")
        
        return

    # ASR 模式
    if args.asr_only:
        # 调用 ASR 服务
        for preset in presets:
            raw_response, utterances = transcribe(
                audio_url=audio_url,
                preset=preset,
            )
            info(f"{preset}: {len(utterances)} 片段")
        return

    # 从 URL 提取视频文件名（用于文件命名）
    video_stem = extract_url_path(audio_url).split("/")[-1].rsplit(".", 1)[0] if audio_url else "test"
    if not video_stem or video_stem == "test":
        video_stem = "test"  # 默认值
    
    # 生成字幕模式
    if args.postprofile:
        # 单个策略，支持多个预设
        if len(presets) > 1:
            info(f"批量生成字幕 ({len(presets)} 个预设, 策略: {args.postprofile})...")
        else:
            info(f"生成字幕 (预设: {presets[0]}, 策略: {args.postprofile})...")
        
        failed = []
        for preset in presets:
            try:
                info(f"\n处理预设: {preset}, 策略: {args.postprofile}")
                # 测试工具：使用调试命名（preset_postprofile）用于对比
                debug_video_stem = f"{preset}_{args.postprofile}"
                files = generate_subtitles_from_preset(
                    preset=preset,
                    postprofile=args.postprofile,
                    audio_url=audio_url,
                    output_dir=output_dir,
                    video_stem=debug_video_stem,  # 测试工具使用调试命名
                    use_cache=use_cache,
                )
                success(f"  ✓ {preset}_{args.postprofile} 完成")
                info(f"    segments: {files['segments']}")
                info(f"    srt: {files['srt']}")
            except Exception as e:
                error(f"  ✗ {preset}_{args.postprofile} 失败: {e}")
                failed.append(f"{preset}_{args.postprofile}")
                import traceback
                traceback.print_exc()
        
        if failed:
            error(f"\n失败的组合: {', '.join(failed)}")
            sys.exit(1)
        else:
            success(f"\n所有组合处理完成！")

    elif args.postprofiles:
        # 多个策略，支持多个预设
        total = len(presets) * len(args.postprofiles)
        info(f"批量生成字幕 ({len(presets)} 个预设 × {len(args.postprofiles)} 个策略 = {total} 个组合)...")
        
        failed = []
        for preset in presets:
            for postprofile in args.postprofiles:
                try:
                    info(f"\n处理预设: {preset}, 策略: {postprofile}")
                    # 测试工具：使用调试命名（preset_postprofile）用于对比
                    debug_video_stem = f"{preset}_{postprofile}"
                    files = generate_subtitles_from_preset(
                        preset=preset,
                        postprofile=postprofile,
                        audio_url=audio_url,
                        output_dir=output_dir,
                        video_stem=debug_video_stem,  # 测试工具使用调试命名
                        use_cache=use_cache,
                    )
                    success(f"  ✓ {preset}_{postprofile} 完成")
                    info(f"    segments: {files['segments']}")
                    info(f"    srt: {files['srt']}")
                except Exception as e:
                    error(f"  ✗ {preset}_{postprofile} 失败: {e}")
                    failed.append(f"{preset}_{postprofile}")
                    import traceback
                    traceback.print_exc()
        
        if failed:
            error(f"\n失败的组合: {', '.join(failed)}")
            sys.exit(1)
        else:
            success(f"\n所有组合处理完成！")

    else:
        # 默认：只运行 ASR（已在上面处理）
        pass


if __name__ == "__main__":
    main()
