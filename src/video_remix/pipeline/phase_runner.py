"""
Phase-based Pipeline Runner: Maven-like lifecycle execution.

Phases:
1. demux: 从视频中提取音频（Extract 16k mono audio）
2. asr: 语音识别（ASR output Chinese segments + subs/zh.srt）
3. mt: 机器翻译（Machine Translation: Translate to English subtitles -> subs/en.srt）
4. tts: 语音合成（Synthesize dubbing audio -> audio/tts.wav）
5. mix: 混音（Mix audio: tts + accompaniment/ducking -> audio/mix.wav）
6. burn: 烧字幕（Burn subtitles + replace audio track -> video/final.mp4）
"""
import json
from pathlib import Path
from typing import Dict, List, Optional, Any

from video_remix.config.settings import PipelineConfig
from video_remix.utils.logger import info, success

# Phase 定义（固定顺序）
PHASES = ["demux", "asr", "mt", "tts", "mix", "burn"]


def _postprocess_subtitle_segments(segments: List[Dict]) -> List[Dict]:
    """
    字幕后处理：Vozo 风格 - 允许"脏"，不允许漏。
    
    策略（recall > precision）：
    1. 合并连续 2-4 字短行（如果它们相邻且时间连续）
    2. ❌ 不丢弃孤立短行（Vozo 风格：宁可多写，不能漏）
    3. 只过滤明显的高频重复短词（如果同一短词在短时间内重复出现 >= 3 次）
    
    Args:
        segments: 原始片段列表
    
    Returns:
        处理后的片段列表
    """
    if not segments:
        return segments
    
    processed = []
    i = 0
    
    while i < len(segments):
        seg = segments[i]
        text = seg.get("text", "").strip()
        char_count = len(text)
        
        # 如果是 2-4 字短行，尝试与下一个合并
        if 2 <= char_count <= 4 and i + 1 < len(segments):
            next_seg = segments[i + 1]
            next_text = next_seg.get("text", "").strip()
            next_char_count = len(next_text)
            
            # 检查时间连续性（间隔 < 0.5s）
            gap = next_seg.get("start", 0) - seg.get("end", 0)
            
            # 如果下一个也是短行，或者间隔很小，则合并
            if (next_char_count <= 6 or gap < 0.5) and gap < 1.0:
                # 合并
                merged_text = text + next_text
                merged_seg = {
                    "id": len(processed),
                    "start": seg.get("start", 0),
                    "end": next_seg.get("end", 0),
                    "text": merged_text,
                    "speaker": seg.get("speaker", "speaker_0"),
                }
                processed.append(merged_seg)
                i += 2  # 跳过下一个，因为已合并
                continue
        
        # Vozo 风格：不丢弃孤立短行（允许"脏"，不允许漏）
        # 只过滤明显的高频重复短词（>= 3 次重复）
        if 2 <= char_count <= 4:
            # 检查是否是高频重复短词
            repeat_count = 0
            for j in range(max(0, i - 5), min(len(segments), i + 6)):
                if j != i and segments[j].get("text", "").strip() == text:
                    repeat_count += 1
            
            # 如果重复 >= 3 次，才过滤（明显是噪声）
            if repeat_count >= 3:
                i += 1
                continue
        
        # Vozo 风格：保留所有其他段（包括孤立短行）
        seg["id"] = len(processed)
        processed.append(seg)
        i += 1
    
    # Vozo 风格：只过滤明显的高频重复短词（>= 3 次重复）
    if len(processed) > 0:
        seen_short_words = {}  # {text: [(start_time, index), ...]}
        
        for idx, seg in enumerate(processed):
            text = seg.get("text", "").strip()
            if 2 <= len(text) <= 4:
                start_time = seg.get("start", 0)
                if text not in seen_short_words:
                    seen_short_words[text] = []
                seen_short_words[text].append((start_time, idx))
        
        # 找出高频重复的短词（>= 3 次）
        to_remove_indices = set()
        for text, occurrences in seen_short_words.items():
            if len(occurrences) >= 3:
                # 检查是否在短时间内重复
                occurrences.sort()
                for i in range(len(occurrences) - 2):
                    time_span = occurrences[i + 2][0] - occurrences[i][0]
                    if time_span < 3.0:  # 3 秒内重复 3 次
                        # 标记为需要移除（保留第一次出现）
                        for j in range(1, len(occurrences)):
                            to_remove_indices.add(occurrences[j][1])
        
        # 移除标记的片段
        if to_remove_indices:
            processed = [seg for idx, seg in enumerate(processed) if idx not in to_remove_indices]
            # 重新编号
            for idx, seg in enumerate(processed):
                seg["id"] = idx
    
    return processed


def get_workdir(video_path: str, output_dir: Optional[str] = None) -> Path:
    """
    获取工作目录：<video_dir>/dub/<stem>/
    
    例如：videos/dbqsfy/1.mp4 -> videos/dbqsfy/dub/1/
    
    Args:
        video_path: 输入视频路径
        output_dir: 输出目录（可选，默认使用视频目录下的 dub 目录）
        
    Returns:
        工作目录路径
    """
    video = Path(video_path)
    stem = video.stem
    
    if output_dir:
        # 如果指定了输出目录，使用指定的目录
        base_dir = Path(output_dir)
        return base_dir / stem
    else:
        # 默认：在视频目录下创建 dub/<stem>/ 目录
        video_dir = video.parent  # videos/dbqsfy/
        return video_dir / "dub" / stem  # videos/dbqsfy/dub/1/


def load_manifest(workdir: Path) -> Dict[str, Any]:
    """加载 manifest.json"""
    manifest_path = workdir / "manifest.json"
    if manifest_path.exists():
        with open(manifest_path, "r", encoding="utf-8") as f:
            return json.load(f)
    else:
        return {
            "phases": {phase: {"done": False, "outputs": {}} for phase in PHASES},
            "video": str(workdir),
        }


def save_manifest(workdir: Path, manifest: Dict[str, Any]) -> None:
    """保存 manifest.json"""
    manifest_path = workdir / "manifest.json"
    workdir.mkdir(parents=True, exist_ok=True)
    with open(manifest_path, "w", encoding="utf-8") as f:
        json.dump(manifest, f, indent=2, ensure_ascii=False)


def mark_phase_done(manifest: Dict[str, Any], phase: str, outputs: Dict[str, str]) -> None:
    """标记 phase 完成并记录输出文件"""
    if phase not in manifest["phases"]:
        manifest["phases"][phase] = {"done": False, "outputs": {}}
    manifest["phases"][phase]["done"] = True
    manifest["phases"][phase]["outputs"] = outputs


def is_phase_done(manifest: Dict[str, Any], phase: str) -> bool:
    """检查 phase 是否已完成"""
    return manifest["phases"].get(phase, {}).get("done", False)


def outputs_exist(manifest: Dict[str, Any], phase: str, workdir: Path) -> bool:
    """检查 phase 的输出文件是否存在"""
    outputs = manifest["phases"].get(phase, {}).get("outputs", {})
    if not outputs:
        return False
    
    for output_path in outputs.values():
        if not (workdir / output_path).exists():
            return False
    
    return True


def invalidate_phases_from(manifest: Dict[str, Any], from_phase: str) -> None:
    """从指定 phase 开始，将所有后续 phases 标记为未完成"""
    from_idx = PHASES.index(from_phase)
    for phase in PHASES[from_idx:]:
        manifest["phases"][phase]["done"] = False
        manifest["phases"][phase]["outputs"] = {}


def run_phase(
    phase: str,
    video_path: str,
    workdir: Path,
    manifest: Dict[str, Any],
    config: PipelineConfig,
    *,
    force: bool = False,
) -> Dict[str, str]:
    """
    执行单个 phase。
    
    Returns:
        输出文件路径字典（相对于 workdir）
    """
    if phase == "demux":
        return _run_phase_demux(video_path, workdir, config)
    elif phase == "asr":
        return _run_phase_asr(video_path, workdir, manifest, config, force=force)
    elif phase == "mt":
        return _run_phase_mt(workdir, manifest, config)
    elif phase == "tts":
        return _run_phase_tts(workdir, manifest, config)
    elif phase == "mix":
        return _run_phase_mix(video_path, workdir, manifest, config)
    elif phase == "burn":
        return _run_phase_burn(video_path, workdir, manifest, config)
    else:
        raise ValueError(f"Unknown phase: {phase}")


def _run_phase_demux(video_path: str, workdir: Path, config: PipelineConfig) -> Dict[str, str]:
    """Phase: demux - 从视频中提取音频（Extract 16k mono audio）"""
    from video_remix.pipeline.media import extract_raw_audio
    
    # 验证视频文件
    video_file = Path(video_path)
    if not video_file.exists():
        raise FileNotFoundError(f"Video file not found: {video_path}")
    if video_file.stat().st_size == 0:
        raise RuntimeError(f"Video file is empty: {video_path}")
    
    # 从 workdir 提取 episode stem（workdir 名称就是 episode stem）
    # 例如: videos/dbqsfy/dub/1/ -> episode_stem = "1"
    episode_stem = workdir.name
    
    audio_dir = workdir / "audio"
    audio_dir.mkdir(parents=True, exist_ok=True)
    audio_path = audio_dir / f"{episode_stem}.wav"
    
    extract_raw_audio(video_path, str(audio_path))
    
    # 验证提取的音频文件
    if not audio_path.exists():
        raise RuntimeError(f"Audio extraction failed: {audio_path} was not created")
    if audio_path.stat().st_size == 0:
        raise RuntimeError(f"Audio extraction failed: {audio_path} is empty. Check video file.")
    
    info(f"Audio extracted: {audio_path.name} (size: {audio_path.stat().st_size / 1024 / 1024:.2f} MB)")
    
    return {"audio": f"audio/{episode_stem}.wav"}


def _run_phase_asr(
    video_path: str,
    workdir: Path,
    manifest: Dict[str, Any],
    config: PipelineConfig,
    *,
    force: bool = False,
) -> Dict[str, str]:
    """
    Phase: asr - 语音识别（ASR output Chinese segments + subs/zh.srt）
    
    使用豆包大模型 ASR。
    """
    from video_remix.pipeline.asr import transcribe
    from video_remix.pipeline._shared.subtitle import generate_subtitles
    from video_remix.infra.storage.tos import TosStorage
    from video_remix.models.doubao import POSTPROFILES, speaker_aware_postprocess
    
    # 获取 episode stem（从 workdir 路径提取，如 "1"）
    episode_stem = workdir.name
    
    # 需要 demux phase 的输出（使用动态路径）
    audio_path = workdir / "audio" / f"{episode_stem}.wav"
    if not audio_path.exists():
        raise RuntimeError(f"Audio file not found: {audio_path}. Run 'demux' phase first.")
    
    # 验证音频文件
    if audio_path.stat().st_size == 0:
        raise RuntimeError(f"Audio file is empty: {audio_path}. Check video file and audio extraction.")
    
    # 使用 ASR
    preset = getattr(config, "doubao_asr_preset", "asr_vad_spk")
    postprofile = getattr(config, "doubao_postprofile", "axis")
    info(f"Strategy: ASR (preset: {preset})")
    info(f"Audio file: {audio_path.name} (size: {audio_path.stat().st_size / 1024 / 1024:.2f} MB)")
    info(f"Audio file: {audio_path.name} (size: {audio_path.stat().st_size / 1024 / 1024:.2f} MB)")
    
    try:
        # 1. 获取音频 URL（上传到 TOS 如果需要）
        audio_url = getattr(config, "doubao_audio_url", None)
        if not audio_url:
            # 如果是 URL 直接使用，否则上传到 TOS
            audio_path_str = str(audio_path)
            if audio_path_str.startswith(("http://", "https://")):
                audio_url = audio_path_str
            else:
                # 从视频路径提取系列名（如 videos/dbqsfy/1.mp4 -> dbqsfy）
                video_path_obj = Path(video_path)
                series = None
                if len(video_path_obj.parts) >= 2:
                    parts = video_path_obj.parts
                    if "videos" in parts:
                        idx = parts.index("videos")
                        if idx + 1 < len(parts):
                            series = parts[idx + 1]
                
                storage = TosStorage()
                audio_url = storage.upload(audio_path, prefix=series)
        
        # 2. 调用 ASR
        hotwords = getattr(config, "doubao_hotwords", None)
        raw_response, utterances = transcribe(
            audio_url=audio_url,
            preset=preset,
            hotwords=hotwords,
        )
        
        if not utterances:
            raise RuntimeError("ASR produced no utterances")
        
        info(f"ASR succeeded ({len(utterances)} utterances)")
        
        # 3. 生成字幕
        result = generate_subtitles(
            utterances=utterances,
            postprocess_fn=speaker_aware_postprocess,
            postprofiles=POSTPROFILES,
            postprofile=postprofile,
            output_dir=workdir,
            video_stem=episode_stem,
            use_cache=not force,
        )
        
        # 读取生成的 segments
        with open(result["segments"], "r", encoding="utf-8") as f:
            segments = json.load(f)
        
        info(f"Generated subtitles ({len(segments)} segments)")
    except Exception as e:
        raise RuntimeError(f"ASR failed: {e}")
    
    # generate_subtitles 已经保存了文件，直接使用返回的路径
    segments_path = result["segments"]
    srt_path = result["srt"]
    
    # 保存原始 ASR 响应数据到 subs 目录
    subs_dir = workdir / "subs"
    subs_dir.mkdir(parents=True, exist_ok=True)
    raw_response_path = subs_dir / "asr-raw-response.json"
    
    with open(raw_response_path, "w", encoding="utf-8") as f:
        json.dump(raw_response, f, indent=2, ensure_ascii=False)
    info(f"Saved raw ASR response to: {raw_response_path}")
    
    return {
        "zh-segments": "subs/zh-segments.json",
        "zh-srt": "subs/zh.srt",
        "asr-raw-response": "subs/asr-raw-response.json",
    }


def _run_phase_mt(
    workdir: Path,
    manifest: Dict[str, Any],
    config: PipelineConfig,
) -> Dict[str, str]:
    """Phase: mt - 机器翻译（Machine Translation: Translate to English subtitles）"""
    from video_remix.utils.timecode import write_srt_from_segments
    import shutil
    
    subs_dir = workdir / "subs"
    subs_dir.mkdir(parents=True, exist_ok=True)
    segments_path = workdir / "subs/zh-segments.json"
    en_segments_path = subs_dir / "en-segments.json"
    context_path = subs_dir / "translation-context.json"
    
    # 直接使用 zh-segments.json，如果不存在则报错
    if not segments_path.exists():
        raise RuntimeError(
            f"{segments_path} not found. Run 'asr' phase first to generate zh-segments.json."
        )
    
    info(f"Using {segments_path} for translation")
    input_path = str(segments_path)
    
    # 检查是否已存在翻译结果
    if en_segments_path.exists() and context_path.exists():
        info("Translation files already exist, skipping translation")
    else:
        # 尝试导入 translate_episode
        try:
            from video_remix.pipeline.mt import translate_episode
        except ImportError:
            raise NotImplementedError(
                "translate_episode function is not implemented yet. "
                "Please implement it in video_remix.pipeline.mt module."
            )
        
        temp_translate_dir = workdir / ".temp_translate"
        temp_translate_dir.mkdir(exist_ok=True)
        
        try:
            context_path_temp, en_segments_path_temp = translate_episode(
                input_path,
                str(temp_translate_dir),
                model=config.openai_model,
                temperature=config.openai_temperature,
            )
            
            if Path(context_path_temp).exists():
                shutil.move(context_path_temp, context_path)
            if Path(en_segments_path_temp).exists():
                shutil.move(en_segments_path_temp, en_segments_path)
        finally:
            if temp_translate_dir.exists():
                shutil.rmtree(temp_translate_dir, ignore_errors=True)
    
    # 加载并生成 SRT
    if not en_segments_path.exists():
        raise RuntimeError(f"English segments not found: {en_segments_path}. Translation may have failed.")
    
    with open(en_segments_path, "r", encoding="utf-8") as f:
        en_segments = json.load(f)
    
    en_srt_path = subs_dir / "en.srt"
    write_srt_from_segments(en_segments, str(en_srt_path), text_key="en_text")
    
    return {
        "segments": "subs/en-segments.json",
        "context": "subs/translation-context.json",
        "srt": "subs/en.srt",
    }


def _run_phase_tts(
    workdir: Path,
    manifest: Dict[str, Any],
    config: PipelineConfig,
) -> Dict[str, str]:
    """Phase: tts - 语音合成（Synthesize dubbing audio）"""
    from video_remix.pipeline.tts import assign_voices, synthesize_tts
    import shutil
    
    en_segments_path = workdir / "subs/en-segments.json"
    if not en_segments_path.exists():
        raise RuntimeError(f"English segments not found: {en_segments_path}. Run 'mt' phase first.")
    
    # 获取 episode stem（从 workdir 路径提取）
    episode_stem = workdir.name
    audio_path = workdir / "audio" / f"{episode_stem}.wav"
    vocals_path = workdir / "audio/vocals.wav"
    
    # 分配声线
    voice_assignment_path = workdir / "voice-assignment.json"
    if not voice_assignment_path.exists():
        temp_voices_dir = workdir / ".temp_voices"
        temp_voices_dir.mkdir(exist_ok=True)
        
        voice_pool_path = config.voice_pool_path
        if not voice_pool_path:
            pool_file = temp_voices_dir / "voice_pool.json"
            from video_remix.models.voice_pool import DEFAULT_VOICE_POOL
            with open(pool_file, "w", encoding="utf-8") as f:
                json.dump(DEFAULT_VOICE_POOL, f, indent=2, ensure_ascii=False)
            voice_pool_path = str(pool_file)
        
        assignment_path_temp = assign_voices(
            str(workdir / "subs/zh-segments.json"),
            str(vocals_path) if vocals_path.exists() else str(audio_path),
            voice_pool_path,
            str(temp_voices_dir),
        )
        
        if Path(assignment_path_temp).exists():
            shutil.move(assignment_path_temp, voice_assignment_path)
        
        if temp_voices_dir.exists():
            shutil.rmtree(temp_voices_dir, ignore_errors=True)
    
    # TTS 合成
    audio_dir = workdir / "audio"
    tts_path = audio_dir / "tts.wav"
    
    if not tts_path.exists():
        if not config.azure_tts_key or not config.azure_tts_region:
            raise ValueError("Azure TTS credentials not set.")
        
        temp_tts_dir = workdir / ".temp_tts"
        temp_tts_dir.mkdir(exist_ok=True)
        
        tts_path_temp = synthesize_tts(
            str(en_segments_path),
            str(voice_assignment_path),
            config.voice_pool_path,
            str(temp_tts_dir),
            azure_key=config.azure_tts_key,
            azure_region=config.azure_tts_region,
            language=config.azure_tts_language,
            max_workers=config.tts_max_workers,
        )
        
        if Path(tts_path_temp).exists():
            shutil.move(tts_path_temp, tts_path)
        
        if temp_tts_dir.exists():
            shutil.rmtree(temp_tts_dir, ignore_errors=True)
    
    return {
        "tts": "audio/tts.wav",
        "voice_assignment": "voice-assignment.json",
    }


def _run_phase_mix(
    video_path: str,
    workdir: Path,
    manifest: Dict[str, Any],
    config: PipelineConfig,
) -> Dict[str, str]:
    """Phase: mix - 混音（Mix audio: tts + accompaniment/ducking）"""
    from video_remix.pipeline.tts import mix_audio
    
    tts_path = workdir / "audio/tts.wav"
    if not tts_path.exists():
        raise RuntimeError(f"TTS audio not found: {tts_path}. Run 'tts' phase first.")
    
    accompaniment_path = workdir / "audio/accompaniment.wav"
    audio_dir = workdir / "audio"
    mix_path = audio_dir / "mix.wav"
    
    # mix_audio 输出视频，我们需要先混音再提取音频
    if not mix_path.exists():
        temp_video = workdir / ".temp_mix.mp4"
        mix_audio(
            str(tts_path),
            str(accompaniment_path) if accompaniment_path.exists() else None,
            video_path,
            str(temp_video),
            target_lufs=config.dub_target_lufs,
            true_peak=config.dub_true_peak,
        )
        
        # 从视频提取音频
        import subprocess
        cmd = [
            "ffmpeg",
            "-i", str(temp_video),
            "-map", "0:a:0",
            "-acodec", "pcm_s16le",
            "-y",
            str(mix_path),
        ]
        subprocess.run(cmd, check=True, capture_output=True)
        
        if temp_video.exists():
            temp_video.unlink()
    
    return {"mix": "audio/mix.wav"}


def _run_phase_burn(
    video_path: str,
    workdir: Path,
    manifest: Dict[str, Any],
    config: PipelineConfig,
) -> Dict[str, str]:
    """Phase: burn - 烧字幕（Burn subtitles + replace audio track）"""
    from video_remix.pipeline.tts import mix_audio
    import subprocess
    import os
    
    mix_path = workdir / "audio/mix.wav"
    if not mix_path.exists():
        raise RuntimeError(f"Mixed audio not found: {mix_path}. Run 'mix' phase first.")
    
    en_srt_path = workdir / "subs/en.srt"
    if not en_srt_path.exists():
        raise RuntimeError(f"English subtitles not found: {en_srt_path}. Run 'mt' phase first.")
    
    video_dir = workdir / "video"
    video_dir.mkdir(parents=True, exist_ok=True)
    final_video = video_dir / "final.mp4"
    
    if not final_video.exists():
        # 替换音轨（使用 mix_audio，但只替换音轨，不混音）
        temp_video = workdir / ".temp_burn.mp4"
        mix_audio(
            str(mix_path),
            None,  # 不再混音，直接替换音轨
            video_path,
            str(temp_video),
            target_lufs=config.dub_target_lufs,
            true_peak=config.dub_true_peak,
        )
        
        # 烧录字幕
        escaped_srt = os.path.abspath(str(en_srt_path)).replace("\\", "\\\\").replace(":", "\\:")
        cmd = [
            "ffmpeg",
            "-i", str(temp_video),
            "-vf", f"subtitles={escaped_srt}",
            "-c:v", "libx264",
            "-preset", "medium",
            "-crf", "23",
            "-c:a", "copy",
            "-y",
            str(final_video),
        ]
        subprocess.run(cmd, check=True, capture_output=True)
        
        if temp_video.exists():
            temp_video.unlink()
    
    return {"final": "video/final.mp4"}


def run_pipeline(
    video_path: str,
    to_phase: str,
    *,
    from_phase: Optional[str] = None,
    output_dir: Optional[str] = None,
    config: Optional[PipelineConfig] = None,
) -> Dict[str, str]:
    """
    运行 pipeline 到指定 phase。
    
    Args:
        video_path: 输入视频路径
        to_phase: 目标 phase（必选）
        from_phase: 起始 phase（可选，如果指定则从该 phase 开始强制刷新）
        output_dir: 输出目录（可选，默认 runs）
        config: PipelineConfig
        
    Returns:
        最终输出的文件路径字典
    """
    if to_phase not in PHASES:
        raise ValueError(f"Unknown phase: {to_phase}. Valid phases: {', '.join(PHASES)}")
    
    if from_phase and from_phase not in PHASES:
        raise ValueError(f"Unknown phase: {from_phase}. Valid phases: {', '.join(PHASES)}")
    
    if from_phase:
        from_idx = PHASES.index(from_phase)
        to_idx = PHASES.index(to_phase)
        if from_idx > to_idx:
            raise ValueError(f"from_phase ({from_phase}) must be before to_phase ({to_phase})")
    
    cfg = config or PipelineConfig()
    workdir = get_workdir(video_path, output_dir)
    manifest = load_manifest(workdir)
    
    # 如果指定了 from_phase，失效化后续 phases
    if from_phase:
        invalidate_phases_from(manifest, from_phase)
        save_manifest(workdir, manifest)
    
    # 确定需要强制执行的 phases
    # 1. 如果指定了 from_phase，从 from_phase 到 to_phase 都强制执行
    # 2. to_phase 本身必须强制执行（即使没有 from_phase）
    force_phases = set()
    if from_phase:
        from_idx = PHASES.index(from_phase)
        to_idx = PHASES.index(to_phase)
        force_phases = set(PHASES[from_idx:to_idx + 1])
    else:
        # 即使没有 from_phase，to_phase 也必须强制执行
        force_phases = {to_phase}
    
    # 执行 phases
    to_idx = PHASES.index(to_phase)
    for phase in PHASES[:to_idx + 1]:
        info(f"\n{'=' * 60}")
        info(f"Phase: {phase}")
        info(f"{'=' * 60}")
        
        # 检查缓存（如果不在强制列表中，且已完成，则跳过）
        if phase not in force_phases and is_phase_done(manifest, phase) and outputs_exist(manifest, phase, workdir):
            info(f"Skipped (already done)")
            continue
        
        # 执行 phase（强制或首次执行）
        is_forced = phase in force_phases
        if is_forced:
            info(f"Running (forced)...")
        else:
            info(f"Running...")
        try:
            outputs = run_phase(phase, video_path, workdir, manifest, cfg, force=is_forced)
            
            # 标记完成
            mark_phase_done(manifest, phase, outputs)
            save_manifest(workdir, manifest)
            
            success(f"Complete")
            for key, path in outputs.items():
                info(f"{key}: {path}")
        except Exception as e:
            # 保存错误状态到 manifest
            if phase not in manifest["phases"]:
                manifest["phases"][phase] = {"done": False, "outputs": {}}
            manifest["phases"][phase]["done"] = False
            # 处理异常：如果 e 是字符串，直接使用；否则使用 str(e)
            error_msg = e if isinstance(e, str) else str(e)
            manifest["phases"][phase]["error"] = error_msg
            save_manifest(workdir, manifest)
            # 如果 e 已经是字符串，创建一个新的 RuntimeError
            if isinstance(e, str):
                raise RuntimeError(f"Phase '{phase}' failed: {e}")
            else:
                raise RuntimeError(f"Phase '{phase}' failed: {e}") from e
    
    # 返回最终输出
    if to_phase not in manifest["phases"]:
        raise RuntimeError(f"Phase '{to_phase}' not found in manifest. This should not happen.")
    final_outputs = manifest["phases"][to_phase].get("outputs", {})
    if not final_outputs:
        raise RuntimeError(f"Phase '{to_phase}' has no outputs. Phase may have failed.")
    return {k: str(workdir / v) for k, v in final_outputs.items()}
