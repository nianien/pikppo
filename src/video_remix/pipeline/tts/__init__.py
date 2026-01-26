"""
TTS / Dubbing Pipeline 模块

职责：
- Azure TTS
- TTS 合成
- 声音分配
- 时长对齐
- 音频混合
"""
from .azure import synthesize_tts
from .synthesize import synthesize_subtitle_to_audio as synthesize_dubbing
from .assign_voices import assign_voices
from .mix_audio import mix_audio

__all__ = [
    "synthesize_tts",
    "synthesize_dubbing",
    "assign_voices",
    "mix_audio",
]
