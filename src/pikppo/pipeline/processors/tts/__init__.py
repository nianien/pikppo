"""
TTS Processor 模块（唯一公共入口）

公共 API：
- run(): 旧版入口（分配声线并合成语音，输出拼接后的音频）
- run_per_segment(): 新版入口（Timeline-First Architecture，输出 per-segment WAVs）

内部模块（不直接导入）：
- impl.py: 核心业务逻辑（待重构）
- assign_voices.py: 声线分配实现
- azure.py: Azure TTS 实现
- synthesize.py: 向后兼容接口
- duration_align.py: 时长对齐（内部使用）
"""
from .processor import run, run_per_segment

__all__ = ["run", "run_per_segment"]
