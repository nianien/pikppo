"""
TTS Synthesis: Azure Neural TTS per segment with episode-level caching.
Output: tts/seg_XXXX.wav files, then concatenate to tts_en.wav
"""
import hashlib
import json
import os
import re
import shutil
import subprocess
from datetime import datetime
from pathlib import Path
from typing import List, Dict, Any, Optional

# Cache configuration
CACHE_ENGINE = "azure"
CACHE_ENGINE_VER = "v1"
CACHE_SAMPLE_RATE = 24000
CACHE_CHANNELS = 1
CACHE_FORMAT = "wav"


def _normalize_text(text: str) -> str:
    """
    Normalize text for cache key generation.
    - strip()
    - collapse consecutive whitespace to single space
    """
    text = text.strip()
    text = re.sub(r'\s+', ' ', text)
    return text


def _generate_cache_key(
    text: str,
    voice_id: str,
    prosody: Dict[str, Any],
    language: str,
) -> str:
    """
    Generate cache key for a TTS segment.
    
    Args:
        text: Normalized text
        voice_id: Azure voice ID (e.g., "en-US-JennyNeural")
        prosody: Prosody settings (rate, pitch, style, etc.)
        language: Language code (e.g., "en-US")
        
    Returns:
        SHA256 hash (hex string)
    """
    # Normalize text
    text_norm = _normalize_text(text)
    
    # Build payload
    payload = {
        "engine": CACHE_ENGINE,
        "engine_ver": CACHE_ENGINE_VER,
        "voice": voice_id,
        "lang": language,
        "format": CACHE_FORMAT,
        "sample_rate": CACHE_SAMPLE_RATE,
        "channels": CACHE_CHANNELS,
        "prosody": {
            "rate": prosody.get("rate", 1.0),
            "pitch": prosody.get("pitch", 0),
            "style": prosody.get("style", "general"),
            "role": prosody.get("role", ""),
            "volume": prosody.get("volume", ""),
        },
        "text": text_norm,
    }
    
    # Generate SHA256 hash
    payload_json = json.dumps(payload, sort_keys=True, ensure_ascii=False)
    cache_key = hashlib.sha256(payload_json.encode('utf-8')).hexdigest()
    
    return cache_key


def _get_cache_paths(output_dir: Path) -> tuple[Path, Path]:
    """
    Get cache directory and manifest path.
    
    Returns:
        (cache_dir, manifest_path)
    """
    cache_dir = output_dir.parent / ".cache" / "tts" / CACHE_ENGINE / "segments"
    manifest_path = output_dir.parent / ".cache" / "tts" / CACHE_ENGINE / "manifest.jsonl"
    return cache_dir, manifest_path


def _write_cache_atomic(cache_file: Path, source_file: Path):
    """
    Atomically write cache file (write to .tmp first, then rename).
    
    Args:
        cache_file: Final cache file path
        source_file: Source file to copy
    """
    cache_file.parent.mkdir(parents=True, exist_ok=True)
    temp_file = cache_file.with_suffix('.tmp')
    
    # Copy to temp file
    shutil.copy2(source_file, temp_file)
    
    # Atomic rename
    temp_file.replace(cache_file)


def _append_manifest(
    manifest_path: Path,
    seg_id: int,
    cache_key: str,
    voice_id: str,
    text: str,
):
    """
    Append entry to manifest.jsonl.
    
    Args:
        manifest_path: Path to manifest.jsonl
        seg_id: Segment ID
        cache_key: Cache key (SHA256)
        voice_id: Voice ID
        text: Original text (for debugging)
    """
    manifest_path.parent.mkdir(parents=True, exist_ok=True)
    
    # Generate text digest
    text_digest = hashlib.sha1(text.encode('utf-8')).hexdigest()
    
    entry = {
        "seg": seg_id,
        "key": cache_key,
        "voice": voice_id,
        "text_sha1": text_digest,
        "ts": datetime.now().isoformat(),
    }
    
    with open(manifest_path, "a", encoding="utf-8") as f:
        f.write(json.dumps(entry, ensure_ascii=False) + "\n")


def _normalize_audio_format(
    input_path: str,
    output_path: str,
    sample_rate: int = CACHE_SAMPLE_RATE,
    channels: int = CACHE_CHANNELS,
):
    """
    Normalize audio to specified format using ffmpeg.
    
    Args:
        input_path: Input audio file
        output_path: Output audio file
        sample_rate: Target sample rate
        channels: Target channels (1=mono, 2=stereo)
    """
    cmd = [
        "ffmpeg",
        "-i", input_path,
        "-ar", str(sample_rate),
        "-ac", str(channels),
        "-sample_fmt", "s16",  # 16-bit PCM
        "-y",
        output_path,
    ]
    subprocess.run(cmd, check=True, capture_output=True)


def synthesize_tts(
    en_segments_path: str,
    voice_assignment_path: str,
    voice_pool_path: Optional[str],
    output_dir: str,
    *,
    azure_key: str,
    azure_region: str,
    language: str = "en-US",
    max_workers: int = 4,
) -> str:
    """
    Synthesize TTS for each segment using Azure Neural TTS with episode-level caching.
    
    Args:
        en_segments_path: Path to segments JSON file (临时文件，由 processor 创建)
        voice_assignment_path: Path to voice_assignment.json
        voice_pool_path: Path to voice pool JSON (None = use default)
        output_dir: Output directory (should be .temp_tts)
        azure_key: Azure Speech Service key
        azure_region: Azure Speech Service region
        language: TTS language
        max_workers: Number of concurrent workers (not used in v1, kept for compatibility)
        
    Returns:
        Path to tts_en.wav
    """
    try:
        import azure.cognitiveservices.speech as speechsdk
    except ImportError:
        raise ImportError(
            "azure-cognitiveservices-speech is not installed. "
            "Install it with: pip install azure-cognitiveservices-speech"
        )
    
    from pikppo.models.voice_pool import VoicePool
    
    # Load data
    with open(en_segments_path, "r", encoding="utf-8") as f:
        en_segments = json.load(f)
    
    with open(voice_assignment_path, "r", encoding="utf-8") as f:
        voice_assignment = json.load(f)
    
    voice_pool = VoicePool(pool_path=voice_pool_path)
    
    # Initialize Azure Speech
    speech_config = speechsdk.SpeechConfig(
        subscription=azure_key,
        region=azure_region,
    )
    speech_config.speech_synthesis_language = language
    
    # Set output format to 24kHz mono PCM (WAV)
    # Note: Azure SDK doesn't directly support WAV, so we'll convert from MP3
    speech_config.set_speech_synthesis_output_format(
        speechsdk.SpeechSynthesisOutputFormat.Audio24Khz48KBitRateMonoMp3
    )
    
    output = Path(output_dir)
    segments_dir = output / "segments"
    segments_dir.mkdir(parents=True, exist_ok=True)
    
    # Get cache paths
    cache_dir, manifest_path = _get_cache_paths(output)
    
    # v1 整改：合成每个 segment 后立刻做段内对齐，在 concat 前插入 gap 静音段
    # 排序 segments 按 start 时间
    en_segments_sorted = sorted(en_segments, key=lambda x: x["start"])
    
    segment_files = []
    cache_hits = 0
    cache_misses = 0
    max_stretch = 1.35  # 最大压缩比（25% 更快）
    
    for seg in en_segments_sorted:
        seg_id = seg['id']
        speaker = seg["speaker"]
        text = seg.get("en_text", "").strip()
        seg_start = seg["start"]
        seg_end = seg["end"]
        seg_duration = seg_end - seg_start
        
        if not text:
            # Empty segment - create silent audio of exact duration
            segment_file = segments_dir / f"seg_{seg_id:04d}.wav"
            _create_silent_audio(str(segment_file), seg_duration)
            segment_files.append((str(segment_file), seg_start, seg_end))
            continue
        
        voice_info = voice_assignment["speakers"].get(speaker, {})
        voice_id = voice_info.get("voice", {}).get("voice_id", "en-US-JennyNeural")
        
        # Get voice config from pool
        pool_key = voice_info.get("voice", {}).get("pool_key")
        if pool_key:
            voice_config = voice_pool.get_voice(pool_key)
            prosody = voice_config.get("prosody", {})
        else:
            prosody = {}
        
        # Generate cache key
        cache_key = _generate_cache_key(text, voice_id, prosody, language)
        cache_file = cache_dir / f"{cache_key}.wav"
        segment_file_raw = segments_dir / f"seg_{seg_id:04d}_raw.wav"
        segment_file = segments_dir / f"seg_{seg_id:04d}.wav"
        
        # Check cache
        if cache_file.exists():
            # Cache hit - copy to raw segment file
            shutil.copy2(cache_file, segment_file_raw)
            cache_hits += 1
            print(f"  💾 [{seg_id}] Cache hit: {text[:50]}...")
        else:
            # Cache miss - synthesize
            cache_misses += 1
            
            # Set voice
            speech_config.speech_synthesis_voice_name = voice_id
            
            # Create temporary file for Azure output (Azure outputs MP3 by default)
            temp_azure_output = segments_dir / f"seg_{seg_id:04d}_azure.mp3"
            audio_config = speechsdk.audio.AudioOutputConfig(filename=str(temp_azure_output))
            
            synthesizer = speechsdk.SpeechSynthesizer(
                speech_config=speech_config,
                audio_config=audio_config,
            )
            
            # Build SSML with prosody
            ssml = f"""<speak version="1.0" xmlns="http://www.w3.org/2001/10/synthesis" xml:lang="{language}">
    <voice name="{voice_id}">
        <prosody rate="{prosody.get('rate', 1.0)}" pitch="{prosody.get('pitch', 0)}%">
            {text}
        </prosody>
    </voice>
</speak>"""
            
            try:
                result = synthesizer.speak_ssml_async(ssml).get()
                
                if result.reason == speechsdk.ResultReason.SynthesizingAudioCompleted:
                    # Normalize to WAV 24k mono PCM
                    _normalize_audio_format(
                        str(temp_azure_output),
                        str(segment_file_raw),
                        sample_rate=CACHE_SAMPLE_RATE,
                        channels=CACHE_CHANNELS,
                    )
                    
                    # Write to cache (atomic)
                    _write_cache_atomic(cache_file, segment_file_raw)
                    
                    # Clean up temp Azure output
                    temp_azure_output.unlink(missing_ok=True)
                else:
                    cancellation_details = speechsdk.CancellationDetails(result)
                    error_msg = f"{result.reason}"
                    if cancellation_details.reason == speechsdk.CancellationReason.Error:
                        error_msg += f": {cancellation_details.error_details}"
                    print(f"Warning: TTS failed for segment {seg_id}: {error_msg}")
                    # Create silent segment as fallback
                    _create_silent_audio(str(segment_file_raw), seg_duration)
                    temp_azure_output.unlink(missing_ok=True)
            except Exception as e:
                print(f"Warning: TTS exception for segment {seg_id}: {e}")
                # Create silent segment as fallback
                _create_silent_audio(str(segment_file_raw), seg_duration)
                temp_azure_output.unlink(missing_ok=True)
        
        # v1 整改：合成每个 segment 后立刻做段内对齐
        _align_segment_to_window(str(segment_file_raw), str(segment_file), seg_duration, max_stretch)
        
        segment_files.append((str(segment_file), seg_start, seg_end))
        
        # Append to manifest
        _append_manifest(manifest_path, seg_id, cache_key, voice_id, text)
    
    # Print cache statistics
    total = cache_hits + cache_misses
    if total > 0:
        hit_rate = (cache_hits / total) * 100
        print(f"  📊 Cache: {cache_hits}/{total} hits ({hit_rate:.1f}%)")
    
    # v1 整改：在 concat 前插入 gap 静音段
    tts_output = output / "tts_en.wav"
    _concatenate_with_gaps(segment_files, str(tts_output))
    
    return str(tts_output)


def _create_silent_audio(output_path: str, duration: float):
    """Create silent audio file of specified duration in WAV 24k mono PCM format."""
    cmd = [
        "ffmpeg",
        "-f", "lavfi",
        "-i", f"anullsrc=r={CACHE_SAMPLE_RATE}:cl=mono",
        "-t", str(duration),
        "-ar", str(CACHE_SAMPLE_RATE),
        "-ac", str(CACHE_CHANNELS),
        "-sample_fmt", "s16",
        "-y",
        output_path,
    ]
    subprocess.run(cmd, check=True, capture_output=True)


def _align_segment_to_window(input_path: str, output_path: str, target_duration: float, max_stretch: float = 1.35):
    """
    Align segment audio to exact time window (seg.end - seg.start).
    
    v1 整改：合成每个 segment 后立刻做段内对齐。
    
    Args:
        input_path: Raw segment audio file
        output_path: Aligned segment audio file
        target_duration: Target duration (seg.end - seg.start)
        max_stretch: Maximum stretch ratio (1.35 = 35% faster)
    """
    import subprocess
    
    # Get actual duration
    result = subprocess.run(
        ["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "default=noprint_wrappers=1:nokey=1", input_path],
        capture_output=True,
        text=True,
        check=True,
    )
    actual_duration = float(result.stdout.strip())
    
    if actual_duration <= target_duration:
        # Audio is shorter or equal - pad with silence to fill time window
        pad_duration = target_duration - actual_duration
        cmd = [
            "ffmpeg",
            "-i", input_path,
            "-af", f"apad=pad_dur={pad_duration}",
            "-ar", str(CACHE_SAMPLE_RATE),
            "-ac", str(CACHE_CHANNELS),
            "-t", str(target_duration),
            "-y",
            output_path,
        ]
        subprocess.run(cmd, check=True, capture_output=True)
    elif actual_duration / target_duration <= max_stretch:
        # Can stretch within limit
        stretch_ratio = target_duration / actual_duration
        # atempo supports 0.5-2.0, chain for larger ratios
        if stretch_ratio < 0.5:
            ratios = []
            remaining = stretch_ratio
            while remaining < 0.5:
                ratios.append(0.5)
                remaining /= 0.5
            ratios.append(remaining)
            filter_str = ",".join([f"atempo={r}" for r in ratios])
        elif stretch_ratio > 2.0:
            ratios = []
            remaining = stretch_ratio
            while remaining > 2.0:
                ratios.append(2.0)
                remaining /= 2.0
            ratios.append(remaining)
            filter_str = ",".join([f"atempo={r}" for r in ratios])
        else:
            filter_str = f"atempo={stretch_ratio}"
        
        cmd = [
            "ffmpeg",
            "-i", input_path,
            "-af", filter_str,
            "-t", str(target_duration),
            "-y",
            output_path,
        ]
        subprocess.run(cmd, check=True, capture_output=True)
    else:
        # Too long even after max stretch - trim to time window
        print(f"Warning: Segment too long ({actual_duration:.2f}s > {target_duration:.2f}s), trimming")
        cmd = [
            "ffmpeg",
            "-i", input_path,
            "-t", str(target_duration),
            "-acodec", "copy",
            "-y",
            output_path,
        ]
        subprocess.run(cmd, check=True, capture_output=True)


def _concatenate_with_gaps(segment_files: List[tuple], output_path: str):
    """
    Concatenate segments with gap silence inserted between them.
    
    v1 整改：在 concat 前插入 gap 静音段（seg.start - prev.end）。
    
    Args:
        segment_files: List of (file_path, start_time, end_time) tuples, sorted by start_time
        output_path: Output audio file path
    """
    if not segment_files:
        raise ValueError("No segments to concatenate")
    
    concat_list = []
    prev_end = 0.0
    
    for file_path, seg_start, seg_end in segment_files:
        # Insert gap silence if needed (including first segment's leading silence)
        gap = seg_start - prev_end
        if gap > 0.01:  # Only insert if gap > 10ms
            gap_file = Path(file_path).parent / f"gap_{len(concat_list)}.wav"
            _create_silent_audio(str(gap_file), gap)
            concat_list.append(str(gap_file))
        
        # Add segment
        concat_list.append(file_path)
        prev_end = seg_end
    
    # v1 整改：确保总时长正确（在最后补静音到最后一个 segment 的 end）
    # 但这里不需要，因为 concat 会自动处理总时长
    
    # Create concat file list
    concat_file = Path(output_path).parent / "concat_list.txt"
    with open(concat_file, "w") as f:
        for file in concat_list:
            f.write(f"file '{file}'\n")
    
    # Concatenate using ffmpeg
    cmd = [
        "ffmpeg",
        "-f", "concat",
        "-safe", "0",
        "-i", str(concat_file),
        "-c", "copy",
        "-y",
        output_path,
    ]
    subprocess.run(cmd, check=True, capture_output=True)
    
    # Clean up
    concat_file.unlink()
    # Clean up gap files
    for file in concat_list:
        if "gap_" in file:
            Path(file).unlink(missing_ok=True)
