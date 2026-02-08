"""
Pipeline phases registration.
"""
from .demux import DemuxPhase
from .sep import SepPhase
from .asr import ASRPhase
from .sub import SubtitlePhase
from .mt import MTPhase
from .align import AlignPhase
from .tts import TTSPhase
from .mix import MixPhase
from .burn import BurnPhase

# 顺序即依赖顺序（线性链）
ALL_PHASES = [
    DemuxPhase(),        # 从视频提取音频
    SepPhase(),          # 人声分离（Demucs，已锁）
    ASRPhase(),          # ASR 识别（只做识别，输出原始响应）
    SubtitlePhase(),     # 字幕后处理（从 ASR raw 生成字幕）
    MTPhase(),           # 机器翻译（只调模型，输出英文整段文本）
    AlignPhase(),        # 时间对齐与重断句（不调模型，生成 en.srt）
    TTSPhase(),          # 语音合成
    MixPhase(),          # 混音
    BurnPhase(),         # 烧录字幕
]
