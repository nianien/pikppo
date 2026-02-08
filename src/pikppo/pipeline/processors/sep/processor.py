"""
Separation Processor: 人声分离（唯一对外入口）

职责：
- 接收 Phase 层的输入（audio_path）
- 调用内部实现分离人声和背景
- 返回 ProcessorResult（不负责文件 IO）

架构原则：
- processor.py 是唯一对外接口
- 内部实现放在 impl.py
- Phase 层只调用 processor.run()
"""
import subprocess
from pathlib import Path

from .._types import ProcessorResult
from .impl import separate_vocals


def _convert_to_16k_mono(input_path: str, output_path: str) -> None:
    """
    将音频转换为 16kHz 单声道 WAV 格式。
    
    Args:
        input_path: 输入音频文件路径
        output_path: 输出音频文件路径（16kHz mono WAV）
    """
    output_file = Path(output_path)
    output_file.parent.mkdir(parents=True, exist_ok=True)
    
    cmd = [
        "ffmpeg",
        "-i", str(input_path),
        "-ar", "16000",      # 采样率 16kHz
        "-ac", "1",          # 单声道
        "-acodec", "pcm_s16le",  # PCM 16-bit little-endian
        "-y",                 # 覆盖输出文件
        str(output_path),
    ]
    
    try:
        subprocess.run(cmd, check=True, capture_output=True, text=True)
    except subprocess.CalledProcessError as e:
        raise RuntimeError(
            f"Failed to convert audio to 16kHz mono: {e.stderr or e.stdout or 'Unknown error'}"
        ) from e


def run(
    audio_path: str,
    *,
    vocals_output_path: str,
    accompaniment_output_path: str,
    model: str = "htdemucs",
) -> ProcessorResult:
    """
    使用 Demucs 分离人声和背景音乐。
    
    Args:
        audio_path: 输入音频文件路径（.wav）
        vocals_output_path: 输出人声文件路径（.wav）
        accompaniment_output_path: 输出背景音乐文件路径（.wav）
        model: Demucs 模型名称，默认 "htdemucs"
    
    Returns:
        ProcessorResult:
        - data.vocals_path: 输出人声文件路径
        - data.accompaniment_path: 输出背景音乐文件路径
        - meta: 元数据（文件大小等）
    """
    # 使用临时目录进行分离（Demucs 会在其下创建子目录）
    temp_output_dir = Path(vocals_output_path).parent / ".temp_sep"
    temp_output_dir.mkdir(parents=True, exist_ok=True)
    
    # 调用内部实现
    vocals_temp_path, accompaniment_temp_path = separate_vocals(
        audio_path,
        str(temp_output_dir),
        model=model,
    )
    
    # 复制到最终输出路径
    import shutil
    import subprocess
    vocals_output = Path(vocals_output_path)
    accompaniment_output = Path(accompaniment_output_path)
    
    vocals_output.parent.mkdir(parents=True, exist_ok=True)
    accompaniment_output.parent.mkdir(parents=True, exist_ok=True)
    
    shutil.copy2(vocals_temp_path, vocals_output)
    shutil.copy2(accompaniment_temp_path, accompaniment_output)
    
    # 生成 16kHz 单声道版本（用于 ASR，如果需要）
    # vocals-16k.wav: 16kHz mono 版本的人声
    vocals_16k_output = vocals_output.parent / f"{vocals_output.stem}-16k.wav"
    _convert_to_16k_mono(str(vocals_output), str(vocals_16k_output))
    
    # raw-16k.wav: 原始音频的 16kHz mono 版本（如果输入不是 16k）
    raw_16k_output = vocals_output.parent / "raw-16k.wav"
    _convert_to_16k_mono(audio_path, str(raw_16k_output))
    
    # 验证输出文件
    if not vocals_output.exists():
        raise RuntimeError(f"Vocal separation failed: {vocals_output_path} was not created")
    
    if not accompaniment_output.exists():
        raise RuntimeError(f"Vocal separation failed: {accompaniment_output_path} was not created")
    
    vocals_size = vocals_output.stat().st_size
    accompaniment_size = accompaniment_output.stat().st_size
    
    if vocals_size == 0:
        raise RuntimeError(f"Vocal separation failed: {vocals_output_path} is empty")
    
    if accompaniment_size == 0:
        raise RuntimeError(f"Vocal separation failed: {accompaniment_output_path} is empty")
    
    return ProcessorResult(
        outputs=[],  # 由 Phase 声明 outputs，processor 只负责业务处理
        data={
            "vocals_path": str(vocals_output),
            "accompaniment_path": str(accompaniment_output),
        },
        metrics={
            "vocals_size_mb": vocals_size / 1024 / 1024,
            "accompaniment_size_mb": accompaniment_size / 1024 / 1024,
        },
    )
