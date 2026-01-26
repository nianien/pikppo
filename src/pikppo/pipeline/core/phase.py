"""
Phase 接口定义：统一 Phase 契约
"""
from __future__ import annotations
from abc import ABC, abstractmethod
from typing import Dict, List

from pikppo.pipeline.core.types import RunContext, PhaseResult, Artifact


class Phase(ABC):
    """Phase 抽象基类。"""
    
    name: str
    version: str  # 逻辑/契约变更必须 bump，用于 invalidation

    @abstractmethod
    def requires(self) -> List[str]:
        """
        返回该 Phase 需要的 artifact keys（从 manifest.artifacts 获取）。
        
        Returns:
            artifact keys 列表，例如 ["subs.zh_segments"]
        """
        pass

    @abstractmethod
    def provides(self) -> List[str]:
        """
        返回该 Phase 将生成的 artifact keys。
        
        Returns:
            artifact keys 列表，例如 ["translate.context", "subs.en_segments"]
        """
        pass

    @abstractmethod
    def run(self, ctx: RunContext, inputs: Dict[str, Artifact]) -> PhaseResult:
        """
        执行 Phase 逻辑。
        
        Args:
            ctx: 运行上下文
            inputs: 已解析的 artifacts（key -> Artifact）
        
        Returns:
            PhaseResult，包含生成的 artifacts（path 可以是临时路径，runner 会统一 publish）
        """
        pass
