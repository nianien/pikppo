"""
Doubao ASR 模块

提供豆包大模型 ASR 的完整功能：
- API 客户端（client）
- 预设配置（presets）
- 数据解析（parser）
- 后处理算法（postprocess）
- 格式转换（formats）
"""
from .client import DoubaoASRClient, guess_audio_format
from .presets import get_preset, get_presets
from .request_types import RequestConfig, AudioConfig, DoubaoASRRequest, UserInfo, CorpusConfig
from .postprofiles import POSTPROFILES
from .parser import parse_utterances, normalize_text
from .postprocess import speaker_aware_postprocess
from .types import Utterance, Segment, SrtCue
from .formats import ms_to_srt_time, to_srt, write_srt

__all__ = [
    "DoubaoASRClient",
    "guess_audio_format",
    "get_preset",
    "get_presets",
    "POSTPROFILES",
    "RequestConfig",
    "AudioConfig",
    "DoubaoASRRequest",
    "UserInfo",
    "CorpusConfig",
    "parse_utterances",
    "normalize_text",
    "speaker_aware_postprocess",
    "Utterance",
    "Segment",
    "SrtCue",
    "ms_to_srt_time",
    "to_srt",
    "write_srt",
]
