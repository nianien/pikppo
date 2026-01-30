"""
TTS Processor 模块（唯一公共入口）

公共 API：
- run(): 唯一对外入口（分配声线并合成语音）

内部模块（不直接导入）：
- impl.py: 核心业务逻辑（待重构）
- assign_voices.py: 声线分配实现
- azure.py: Azure TTS 实现
- synthesize.py: 向后兼容接口
- duration_align.py: 时长对齐（内部使用）
"""
from .processor import run

__all__ = ["run"]
