"""
混音：TTS + accompaniment/ducking
"""
import subprocess
from pathlib import Path
from typing import Optional

from pikppo.utils.logger import info


def mix_audio(
    tts_path: str,
    accompaniment_path: Optional[str],
    vocals_path: Optional[str],
    video_path: str,
    output_path: str,
    *,
    mute_original: bool = False,
    mix_mode: str = "ducking",  # ducking | simple
    tts_volume: float = 1.0,
    accompaniment_volume: float = 0.8,
    vocals_volume: float = 0.15,
    duck_threshold: float = 0.05,
    duck_ratio: float = 10.0,
    duck_attack_ms: float = 20.0,
    duck_release_ms: float = 400.0,
    target_lufs: float = -16.0,
    true_peak: float = -1.0,
) -> None:
    """
    混音：将 TTS 音频和伴奏混合，输出到视频。
    
    Args:
        tts_path: TTS 音频文件路径
        accompaniment_path: 伴奏音频文件路径（可选）
        vocals_path: 原声人声（sep.vocals，优先用于压制；可选）
        video_path: 原始视频文件路径
        output_path: 输出视频文件路径
        mix_mode: 混音模式：ducking（侧链压制原声，推荐）或 simple（固定压低原声）
        tts_volume: TTS 音量增益（线性）
        accompaniment_volume: 伴奏音量增益（线性）
        vocals_volume: 原声人声音量增益（线性，ducking 前的基准）
        duck_threshold: 侧链阈值（0~1 振幅，越小越激进）
        duck_ratio: 压缩比（越大压制越明显）
        duck_attack_ms: attack（毫秒）
        duck_release_ms: release（毫秒）
        target_lufs: 目标响度（LUFS）
        true_peak: 真峰值限制（dB）
    """
    tts_file = Path(tts_path)
    video_file = Path(video_path)
    output_file = Path(output_path)
    accomp_file = Path(accompaniment_path) if accompaniment_path else None
    vocals_file = Path(vocals_path) if vocals_path else None
    
    if not tts_file.exists():
        raise FileNotFoundError(f"TTS audio not found: {tts_path}")
    if not video_file.exists():
        raise FileNotFoundError(f"Video file not found: {video_path}")
    
    output_file.parent.mkdir(parents=True, exist_ok=True)
    
    # Inputs:
    # 0: video (for video stream + optional audio fallback)
    # 1: tts
    # 2: accompaniment (optional)
    # 3: vocals (optional)
    inputs = [str(video_file), str(tts_file)]
    if accomp_file and accomp_file.exists():
        inputs.append(str(accomp_file))
    if vocals_file and vocals_file.exists():
        inputs.append(str(vocals_file))

    has_accomp = accomp_file is not None and accomp_file.exists()
    has_vocals = vocals_file is not None and vocals_file.exists()

    # Labels
    # [tts_sc]  sidechain key for ducking（仅在需要 ducking 时存在）
    # [tts_mix] actual TTS audio to be mixed
    # [bg]      from accompaniment if available, else from video audio
    # [orig]    original speech to duck: prefer vocals, else video audio
    # 重要：同一个 labeled stream 不能被消费两次，只在需要 ducking 时 asplit。
    if not mute_original and mix_mode == "ducking":
        tts_chain = f"[1:a]volume={tts_volume},asplit=2[tts_sc][tts_mix]"
    else:
        # 不做 ducking 或完全 mute 原声时，不需要 sidechain 分支
        tts_chain = f"[1:a]volume={tts_volume}[tts_mix]"

    if has_accomp:
        bg_chain = f"[2:a]volume={accompaniment_volume}[bg]"
    else:
        # 没有伴奏时，只能用视频原音做 bg（可能包含对白）
        bg_chain = "[0:a]anull[bg]"

    filter_parts = [tts_chain, bg_chain]

    if not mute_original:
        # 构建原声链
        if has_vocals:
            # vocals input index depends on whether accompaniment exists
            vocals_input_idx = 3 if has_accomp else 2
            orig_chain = f"[{vocals_input_idx}:a]volume={vocals_volume}[orig]"
        else:
            # 没有 sep.vocals，只能用视频原声做 orig
            orig_chain = f"[0:a]volume={vocals_volume}[orig]"

        filter_parts.append(orig_chain)

        # Ducking / mixing
        if mix_mode == "ducking":
            # Sidechain duck original speech under TTS（以 tts_sc 为侧链键控）。
            duck = (
                f"[orig][tts_sc]"
                f"sidechaincompress="
                f"threshold={duck_threshold}:"
                f"ratio={duck_ratio}:"
                f"attack={duck_attack_ms}:"
                f"release={duck_release_ms}:"
                f"detection=peak:"
                f"link=maximum"
                f"[orig_duck]"
            )
        else:
            # Simple fallback: keep original speech always low (no sidechain)
            duck = "[orig]anull[orig_duck]"

        # Mix: bg + orig_duck + tts_mix
        # If bg is from video audio and orig is also from video audio, this will double-count.
        # 我们接受这种退化情况（未分离出 vocals/accompaniment 时）。
        mix = "[bg][orig_duck][tts_mix]amix=inputs=3:duration=longest:weights=1 1 3[mix]"
        filter_parts.extend([duck, mix])
    else:
        # 完全不要中文人声：只保留 bg（优先伴奏）+ TTS
        # 如果有伴奏，bg 基本是纯 BGM；没有伴奏时，bg 仍然可能带对白，这是无法避免的退化情况。
        mix = "[bg][tts_mix]amix=inputs=2:duration=longest:weights=1 3[mix]"
        filter_parts.append(mix)

    # Loudness normalization (one-pass)
    norm = f"[mix]loudnorm=I={target_lufs}:TP={true_peak}:LRA=11:linear=true[final]"
    filter_parts.append(norm)

    filter_complex = ";".join(filter_parts)
    
    cmd = [
        "ffmpeg",
        "-i", inputs[0],
        "-i", inputs[1],
    ]
    
    if len(inputs) > 2:
        cmd.extend(["-i", inputs[2]])
    if len(inputs) > 3:
        cmd.extend(["-i", inputs[3]])
    
    cmd.extend([
        "-filter_complex", filter_complex,
        "-map", "0:v:0",
        "-map", "[final]",
        "-c:v", "copy",
        "-c:a", "aac",
        "-y",
        str(output_file),
    ])
    
    info(
        "Mixing audio:"
        f" mute_original={mute_original}, mode={mix_mode}, has_accomp={has_accomp}, has_vocals={has_vocals},"
        f" duck(thr={duck_threshold}, ratio={duck_ratio}, attack={duck_attack_ms}, release={duck_release_ms})"
    )
    try:
        subprocess.run(
            cmd,
            check=True,
            capture_output=True,
            text=True,
        )
        info(f"Mix completed: {output_file.name}")
    except subprocess.CalledProcessError as e:
        raise RuntimeError(
            f"FFmpeg mix failed: {e.stderr or e.stdout or 'Unknown error'}"
        ) from e
