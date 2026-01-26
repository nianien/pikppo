"""
ASR Pipeline 模块

职责：
- ASR 转录（transcribe）：audio_url + preset → utterances

注意：
- Pipeline 只负责编排，不包含模型实现细节
- 所有模型实现在 models 中
- 字幕生成功能在 pipeline._shared.subtitle 模块中
- URL/Path 解析直接使用 storage 层
"""
from .transcribe import transcribe

__all__ = [
    "transcribe",
]
