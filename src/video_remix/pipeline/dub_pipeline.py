"""
Main Dubbing Pipeline: Complete workflow from video to dubbed output.
"""
import json
import shutil
from pathlib import Path
from typing import Dict, Optional

from video_remix.pipeline.qc_report import generate_qc_report

from video_remix.config.settings import PipelineConfig
from video_remix.pipeline.media import extract_raw_audio, separate_vocals
from video_remix.pipeline.mt import translate_episode
from video_remix.pipeline.tts import (
    assign_voices,
    synthesize_tts,
    mix_audio,
)
from video_remix.utils.logger import info, success, warning
from video_remix.utils.timecode import write_srt_from_segments


def run_dub_pipeline(
    video_path: str,
    *,
    output_dir: Optional[str] = None,
    config: Optional[PipelineConfig] = None,
) -> Dict[str, str]:
    """
    Run complete dubbing pipeline.
    
    Pipeline:
    1. MediaPrep: Extract audio
    2. VocalSeparation: Demucs separation
    3. ASR + Diarization: Google STT
    4. SubtitleBuild: zh.srt
    5. Translation: OpenAI two-stage
    6. SubtitleBuild: en.srt
    7. VoicePool + Assignment
    8. TTS: Azure Neural TTS
    9. DurationAlign
    10. Mixing + Mastering
    11. QC Report
    
    Args:
        video_path: Input video file (e.g., xxxx/1.mp4)
        output_dir: Output directory (optional, default: <video_dir>.dub/<video_stem>/)
        config: PipelineConfig
        
    Returns:
        Dict with paths to all outputs
        
    Output structure:
        Input: xxxx/1.mp4
        Output: xxxx/dub/1/
          - 1.wav (raw audio)
          - 1-vocals.wav
          - 1-accompaniment.wav
          - 1-zh.srt
          - 1-en.srt
          - 1-dub.mp4
          - etc.
    """
    cfg = config or PipelineConfig()
    
    video = Path(video_path)
    # 如果是相对路径，先尝试解析
    if not video.is_absolute():
        video = (Path.cwd() / video).resolve()
    
    if not video.exists():
        # 提供更详细的错误信息和建议
        cwd = Path.cwd()
        videos_dir = cwd / "videos"
        if videos_dir.exists():
            video_files = list(videos_dir.glob("*.mp4"))
            suggestions = "\n".join([f"    - {videos_dir.name}/{f.name}" for f in video_files[:5]])
            if len(video_files) > 5:
                suggestions += f"\n    ... and {len(video_files) - 5} more files"
        else:
            suggestions = "    (videos directory not found)"
        
        raise FileNotFoundError(
            f"Video not found: {video_path}\n"
            f"  Resolved path: {video}\n"
            f"  Current working directory: {cwd}\n"
            f"  Available videos in '{videos_dir.name}/' directory:\n{suggestions}\n"
            f"  Please use the correct path, e.g., 'videos/1.mp4' (from project root)"
        )
    
    # Determine output directory structure:
    # Input: xxxx/1.mp4 -> Output: xxxx/dub/1/
    video_stem = video.stem  # e.g., "1"
    video_dir = video.parent  # e.g., "xxxx"
    
    # Create dub directory inside video directory
    if output_dir:
        dub_dir = Path(output_dir)
    else:
        dub_dir = video_dir / "dub"
    
    run_dir = dub_dir / video_stem
    
    # Create output directory
    run_dir.mkdir(parents=True, exist_ok=True)
    
    # All files go directly into run_dir with prefix (e.g., 1.wav, 1-zh.srt, etc.)
    
    result = {}
    
    # Initialize temp directory variables (may not be created if steps are skipped)
    temp_sep_dir = None
    temp_translate_dir = None
    temp_voices_dir = None
    temp_tts_dir = None
    
    print("=" * 60)
    print("Video Dubbing Pipeline")
    print("=" * 60)
    print(f"Video: {video}")
    print(f"Output: {run_dir}")
    print("=" * 60)
    print()
    
    # Step 1: MediaPrep
    print("Step 1/11: Extracting audio...")
    audio_raw = run_dir / f"{video_stem}.wav"
    if audio_raw.exists():
        info("  Skipped (already exists)")
    else:
        extract_raw_audio(str(video), str(audio_raw))
        success("  Audio extracted")
    result["audio_raw"] = str(audio_raw)
    print()
    
    # Step 2: VocalSeparation
    print("Step 2/11: Separating vocals (Demucs)...")
    final_vocals = run_dir / f"{video_stem}-vocals.wav"
    final_accompaniment = run_dir / f"{video_stem}-accompaniment.wav"
    
    if final_vocals.exists() and (not final_accompaniment.exists() or final_accompaniment.exists()):
        info("  Skipped (already exists)")
        vocals_path = str(final_vocals)
        accompaniment_path = str(final_accompaniment) if final_accompaniment.exists() else None
        # temp_sep_dir remains None (not needed)
    else:
        # Use temporary directory for Demucs output
        temp_sep_dir = run_dir / ".temp_separation"
        temp_sep_dir.mkdir(exist_ok=True)
        vocals_path, accompaniment_path = separate_vocals(
            str(audio_raw),
            str(temp_sep_dir),
            model=cfg.demucs_model,
            device=cfg.demucs_device,
            shifts=cfg.demucs_shifts,
            split=cfg.demucs_split,
        )
        # Move to final location
        if Path(vocals_path).exists():
            shutil.move(vocals_path, final_vocals)
            vocals_path = str(final_vocals)
        if accompaniment_path and Path(accompaniment_path).exists():
            shutil.move(accompaniment_path, final_accompaniment)
            accompaniment_path = str(final_accompaniment)
        # Clean up temp directory
        if temp_sep_dir.exists():
            shutil.rmtree(temp_sep_dir, ignore_errors=True)
        success("  Vocals separated")
    
    result["vocals"] = vocals_path
    if accompaniment_path:
        result["accompaniment"] = accompaniment_path
    print()
    
    # Step 3: ASR + Diarization
    print("Step 3/11: ASR + Speaker Diarization (Google STT)...")
    segments_path = run_dir / f"{video_stem}-zh-segments.json"
    words_path = run_dir / f"{video_stem}-zh-words.json"
    
    # 检查是否强制重新识别
    force_asr = getattr(cfg, "force_asr", False)
    
    if not force_asr and segments_path.exists() and words_path.exists():
        # 检查文件是否非空
        if segments_path.stat().st_size > 0 and words_path.stat().st_size > 0:
            print("  ⏭️  Skipped (ASR cache hit)")
            # Load existing segments
            with open(segments_path, "r", encoding="utf-8") as f:
                segments = json.load(f)
        else:
            force_asr = True  # 文件为空，强制重新识别
    
    if force_asr or not (segments_path.exists() and words_path.exists()):
        # 使用统一的 ASR 接口（GoogleASR）
        if not cfg.google_stt_credentials_path:
            raise ValueError(
                "google_stt_credentials_path not set. "
                "Please set it in PipelineConfig or via CLI argument."
            )
        
        # 使用豆包大模型 ASR
        from video_remix.pipeline.asr import DoubaoLLMASR
        
        # v2 简化：只允许两种 ASR 输入音频
        # 1. vocals_16k_mono.wav（推荐，短剧对白更稳）
        # 2. 1.wav（当 vocals 太"金属感"时回退）
        if cfg.asr_use_vocals:
            # 使用 vocals
            if not vocals_path or not Path(vocals_path).exists():
                warning(f"   Vocals file not found, falling back to raw audio")
                audio_for_asr = run_dir / f"{video_stem}-raw-16k.wav"
                cfg.asr_use_vocals = False  # 标记已回退
            else:
                audio_for_asr = run_dir / f"{video_stem}-vocals-16k.wav"
        else:
            # 使用 raw
            audio_for_asr = run_dir / f"{video_stem}-raw-16k.wav"
        
        # 预处理音频（如果尚未处理）
        if not audio_for_asr.exists():
            import subprocess
            source_audio = vocals_path if cfg.asr_use_vocals and vocals_path and Path(vocals_path).exists() else str(audio_raw)
            info(f"   Preprocessing audio for ASR (16k mono + dynaudnorm)...")
            cmd = [
                "ffmpeg",
                "-i", source_audio,
                "-ar", "16000",  # 16kHz
                "-ac", "1",      # mono
                "-af", "dynaudnorm",  # 动态音频归一化（恢复人声音量）
                "-acodec", "pcm_s16le",  # LINEAR16
                "-y",
                str(audio_for_asr),
            ]
            subprocess.run(cmd, check=True, capture_output=True)
            success(f"   Audio preprocessed for ASR")
        
        # 验证音频文件存在且非空
        if not audio_for_asr.exists():
            raise FileNotFoundError(f"Audio file for ASR not found: {audio_for_asr}")
        if audio_for_asr.stat().st_size == 0:
            raise RuntimeError(f"Audio file for ASR is empty: {audio_for_asr}")
        
        # 打印调试信息
        import subprocess
        duration_result = subprocess.run(
            ["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "default=noprint_wrappers=1:nokey=1", str(audio_for_asr)],
            capture_output=True,
            text=True,
        )
        duration = duration_result.stdout.strip() if duration_result.returncode == 0 else "unknown"
        info(f"   Using audio file: {audio_for_asr.name} (size: {audio_for_asr.stat().st_size / 1024 / 1024:.2f} MB, duration: {duration}s)")
        
        # 执行 ASR（使用 DoubaoLLMASR）
        asr_instance = DoubaoLLMASR(cfg)
        # 注意：DoubaoLLMASR.transcribe 需要 video_path, workdir, episode_stem
        # 这里需要适配，暂时保留原逻辑
        segments = asr_instance.transcribe(
            video_path=str(audio_for_asr),
            workdir=run_dir,
            episode_stem=video_stem,
        )
        # DoubaoLLMASR 返回 (diarized_json, segments)，取 segments
        _, segments = segments if isinstance(segments, tuple) else (None, segments)
        
        if not segments:
            raise RuntimeError("ASR produced no segments. Check audio quality and ASR settings.")
        
        # 豆包大模型 ASR 不需要质量检查和回退机制
        # 直接使用结果
        
        # 转换为统一格式（如果 ASR 返回的不是标准格式）
        # faster-whisper 已经返回标准格式，这里只是确保
        segments = [
            {
                "id": i,
                "start": seg.get("start", seg.get("start_time", 0.0)),
                "end": seg.get("end", seg.get("end_time", 0.0)),
                "text": seg.get("text", "").strip(),
                "speaker": seg.get("speaker", "speaker_0"),  # Whisper 不支持 diarization，统一为 speaker_0
            }
            for i, seg in enumerate(segments)
        ]
        
        # 保存缓存（episode 级别）
        segments_path.parent.mkdir(parents=True, exist_ok=True)
        with open(segments_path, "w", encoding="utf-8") as f:
            json.dump(segments, f, indent=2, ensure_ascii=False)
        
        # 保存 words JSON（向后兼容）
        words = []
        for seg in segments:
            words.append({
                "word": seg.get("text", ""),
                "start": seg.get("start", 0.0),
                "end": seg.get("end", 0.0),
                "speaker": seg.get("speaker", "speaker_0"),
            })
        with open(words_path, "w", encoding="utf-8") as f:
            json.dump(words, f, indent=2, ensure_ascii=False)
        
        # 保存 SRT（用于缓存检查）
        write_srt_from_segments(segments, str(segments_path.parent / f"{video_stem}-zh.srt"), text_key="text")
        
        success("  ASR + Diarization complete")
        
        success("  ASR + Diarization complete")
    
    result["zh_words"] = str(words_path)
    result["zh_segments"] = str(segments_path)
    print()
    
    # Load segments for subtitle generation
    with open(segments_path, "r", encoding="utf-8") as f:
        zh_segments = json.load(f)
    
    # Step 4: SubtitleBuild (Chinese)
    # 注意：SRT 文件已由 asr.transcribe() 的 _save_cache() 生成，这里只检查是否存在
    print("Step 4/11: Building Chinese subtitles...")
    zh_srt = run_dir / f"{video_stem}-zh.srt"
    if zh_srt.exists():
        print("  ⏭️  Skipped (already exists, generated by ASR cache)")
    else:
        # 如果 ASR 缓存没有生成 SRT，这里生成（向后兼容）
        write_srt_from_segments(zh_segments, str(zh_srt), text_key="text")
        success("  Chinese subtitles generated")
    result["zh_srt"] = str(zh_srt)
    print()
    
    # Step 5: Translation
    print("Step 5/11: Translation (OpenAI two-stage)...")
    final_en_segments = run_dir / f"{video_stem}-en-segments.json"
    final_context = run_dir / f"{video_stem}-translation-context.json"
    
    if final_en_segments.exists() and final_context.exists():
        info("  Skipped (already exists)")
        en_segments_path = str(final_en_segments)
        context_path = str(final_context)
        # Load English segments
        with open(en_segments_path, "r", encoding="utf-8") as f:
            en_segments = json.load(f)
        # temp_translate_dir remains None (not needed)
    else:
        # Use temp directory for translation intermediate files
        temp_translate_dir = run_dir / ".temp_translate"
        temp_translate_dir.mkdir(exist_ok=True)
        context_path, en_segments_path = translate_episode(
            str(segments_path),
            str(temp_translate_dir),
            model=cfg.openai_model,
            temperature=cfg.openai_temperature,
        )
        # Move translation context to final location
        if Path(context_path).exists():
            shutil.move(context_path, final_context)
            context_path = str(final_context)
        # Move en_segments to final location
        if Path(en_segments_path).exists():
            shutil.move(en_segments_path, final_en_segments)
            en_segments_path = str(final_en_segments)
        
        # Load English segments
        with open(en_segments_path, "r", encoding="utf-8") as f:
            en_segments = json.load(f)
        
        if not en_segments:
            raise RuntimeError("Translation produced no segments. Check OpenAI API and translation settings.")
        
        success("  Translation complete")
    
    result["translation_context"] = context_path
    result["en_segments"] = en_segments_path
    print()
    
    # Step 6: SubtitleBuild (English)
    print("Step 6/11: Building English subtitles...")
    en_srt = run_dir / f"{video_stem}-en.srt"
    
    if en_srt.exists():
        info("  Skipped (already exists)")
    else:
        write_srt_from_segments(en_segments, str(en_srt), text_key="en_text")
        success("  English subtitles generated")
    
    result["en_srt"] = str(en_srt)
    print()
    
    # Step 7: VoicePool + Assignment
    print("Step 7/11: Assigning voices...")
    final_voice_assignment = run_dir / f"{video_stem}-voice-assignment.json"
    
    if final_voice_assignment.exists():
        info("  Skipped (already exists)")
        voice_assignment_path = str(final_voice_assignment)
        # Load voice pool path (needed for TTS)
        voice_pool_path = cfg.voice_pool_path
        if not voice_pool_path:
            # Use default pool (will be created if needed)
            temp_voices_dir = run_dir / ".temp_voices"
            temp_voices_dir.mkdir(exist_ok=True)
            pool_file = temp_voices_dir / "voice_pool.json"
            from video_remix.models.voice_pool import DEFAULT_VOICE_POOL
            with open(pool_file, "w", encoding="utf-8") as f:
                json.dump(DEFAULT_VOICE_POOL, f, indent=2, ensure_ascii=False)
            voice_pool_path = str(pool_file)
        # temp_voices_dir may be set above, or remains None if using custom pool
    else:
        voice_pool_path = cfg.voice_pool_path
        temp_voices_dir = run_dir / ".temp_voices"
        temp_voices_dir.mkdir(exist_ok=True)
        
        if voice_pool_path:
            # Use custom voice pool
            pass
        else:
            # Save default pool
            pool_file = temp_voices_dir / "voice_pool.json"
            from video_remix.models.voice_pool import DEFAULT_VOICE_POOL
            with open(pool_file, "w", encoding="utf-8") as f:
                json.dump(DEFAULT_VOICE_POOL, f, indent=2, ensure_ascii=False)
            voice_pool_path = str(pool_file)
        
        voice_assignment_path = assign_voices(
            str(segments_path),
            vocals_path,
            voice_pool_path,
            str(temp_voices_dir),
        )
        # Move to final location
        if Path(voice_assignment_path).exists():
            shutil.move(voice_assignment_path, final_voice_assignment)
            voice_assignment_path = str(final_voice_assignment)
        success("  Voices assigned")
    
    result["voice_assignment"] = voice_assignment_path
    print()
    
    # Step 8: TTS
    print("Step 8/11: TTS Synthesis (Azure Neural TTS)...")
    final_tts = run_dir / f"{video_stem}-tts.wav"
    
    if final_tts.exists():
        info("  Skipped (already exists)")
        tts_audio_path = str(final_tts)
        # temp_tts_dir remains None (will be created for alignment if needed)
    else:
        if not cfg.azure_tts_key or not cfg.azure_tts_region:
            raise ValueError(
                "Azure TTS credentials not set. Set AZURE_SPEECH_KEY and AZURE_SPEECH_REGION environment variables."
            )
        
        temp_tts_dir = run_dir / ".temp_tts"
        temp_tts_dir.mkdir(exist_ok=True)
        tts_audio_path = synthesize_tts(
            en_segments_path,
            voice_assignment_path,
            voice_pool_path,
            str(temp_tts_dir),
            azure_key=cfg.azure_tts_key,
            azure_region=cfg.azure_tts_region,
            language=cfg.azure_tts_language,
            max_workers=cfg.tts_max_workers,
        )
        # Move to final location
        if Path(tts_audio_path).exists():
            shutil.move(tts_audio_path, final_tts)
            tts_audio_path = str(final_tts)
        success("  TTS synthesis complete")
    
    result["tts_audio"] = tts_audio_path
    print()
    
    # Step 9: DurationAlign (v1 整改：已改为 no-op，因为 tts_azure.py 已经做了段内对齐)
    print("Step 9/11: Duration alignment (skipped - done in TTS synthesis)...")
    # v1 整改：tts_azure.py 已经在合成时做了段内对齐和 gap 插入，这里不再需要
    # 直接使用 tts_en.wav 作为最终音频
    final_aligned_tts = run_dir / f"{video_stem}-tts-aligned.wav"
    
    if final_aligned_tts.exists():
        info("  Skipped (already exists)")
        aligned_tts_path = str(final_aligned_tts)
    else:
        # 直接复制 tts_en.wav 到 tts-aligned.wav（保持接口兼容）
        if Path(tts_audio_path).exists():
            shutil.copy2(tts_audio_path, final_aligned_tts)
            aligned_tts_path = str(final_aligned_tts)
            success("  Using TTS audio (already aligned per-segment)")
        else:
            raise RuntimeError(f"TTS audio not found: {tts_audio_path}")
    
    result["tts_aligned"] = aligned_tts_path
    print()
    
    # Step 10: Mixing + Mastering
    print("Step 10/11: Mixing audio...")
    output_video_nosub = run_dir / f"{video_stem}-dub-nosub.mp4"  # 不烧录字幕版本（只换音轨）
    
    # 生成不烧录字幕版本（只换音轨）
    if output_video_nosub.exists():
        print("  ⏭️  Skipped (nosub version already exists)")
    else:
        # accompaniment_path might be None if Demucs failed
        mix_audio(
            aligned_tts_path,
            accompaniment_path if accompaniment_path else None,
            str(video),
            str(output_video_nosub),
            target_lufs=cfg.dub_target_lufs,
            true_peak=cfg.dub_true_peak,
        )
        success("  Audio mixed (nosub version)")
    
    result["output_video_nosub"] = str(output_video_nosub)
    result["output_video"] = str(output_video_nosub)  # 只生成一个版本（不烧录字幕）
    print()
    
    # Step 10.5: Copy final output to video directory
    print("Step 10.5/11: Copying final output to video directory...")
    final_copy = video_dir / f"{video_stem}-dub.mp4"
    
    if final_copy.exists():
        info("  Skipped (already exists)")
    else:
        shutil.copy2(output_video_nosub, final_copy)
        success(f"  Copied to: {final_copy}")
    
    result["output_video_final"] = str(final_copy)
    print()
    
    # Step 11: QC Report
    if cfg.dub_enable_qc:
        print("Step 11/11: Generating QC report...")
        qc_report_path = run_dir / f"{video_stem}-qc.json"
        generate_qc_report(
            video_stem,
            str(dub_dir),
            zh_segments_path=str(segments_path),
            en_segments_path=en_segments_path,
            voice_assignment_path=voice_assignment_path,
            tts_audio_path=aligned_tts_path,
            output_path=str(qc_report_path),
        )
        result["qc_report"] = str(qc_report_path)
        print("  ✅ QC report generated")
        print()
    
    # Clean up temp directories (only if they were created)
    for temp_dir in [temp_sep_dir, temp_translate_dir, temp_voices_dir, temp_tts_dir]:
        if temp_dir is not None and temp_dir.exists():
            shutil.rmtree(temp_dir, ignore_errors=True)
    
    print("=" * 60)
    print("✅ Pipeline complete!")
    print("=" * 60)
    for k, v in result.items():
        print(f"  {k}: {v}")
    print()
    
    return result
