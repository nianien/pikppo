"""
Pipeline core types: Artifact, PhaseResult, RunContext, etc.
"""
from __future__ import annotations
from dataclasses import dataclass, field
from typing import Any, Dict, List, Literal, Optional

Status = Literal["pending", "running", "succeeded", "failed", "skipped"]


@dataclass(frozen=True)
class Artifact:
    """可被其他 Phase 消费的产物。"""
    key: str                 # e.g. "subs.zh_segments"
    path: str                # workspace-relative path
    kind: str                # "json"|"srt"|"wav"|"mp4"
    fingerprint: str         # e.g. "sha256:..."
    meta: Dict[str, Any] = field(default_factory=dict)


@dataclass
class ErrorInfo:
    """错误信息。"""
    type: str
    message: str
    traceback: Optional[str] = None


@dataclass
class PhaseResult:
    """Phase 执行结果。"""
    status: Literal["succeeded", "failed"]
    artifacts: Dict[str, Artifact] = field(default_factory=dict)
    metrics: Dict[str, Any] = field(default_factory=dict)
    warnings: List[str] = field(default_factory=list)
    error: Optional[ErrorInfo] = None


@dataclass
class RunContext:
    """运行上下文。"""
    job_id: str
    workspace: str
    config: Dict[str, Any]   # global + phases config
