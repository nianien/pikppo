"""
Pipeline phases registration.
"""
from .demux import DemuxPhase
from .asr import ASRPhase
from .mt import MTPhase
from .tts import TTSPhase
from .mix import MixPhase
from .burn import BurnPhase

# 顺序即依赖顺序（线性链）
ALL_PHASES = [
    DemuxPhase(),
    ASRPhase(),
    MTPhase(),
    TTSPhase(),
    MixPhase(),
    BurnPhase(),
]
