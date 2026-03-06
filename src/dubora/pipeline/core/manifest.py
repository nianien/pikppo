"""
Manifest IO + registry + 状态管理
"""
import json
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List, Optional

from dubora.pipeline.core.types import Artifact, ErrorInfo, GateStatus, Status
from dubora.pipeline.core.atomic import atomic_write


class Manifest:
    """Manifest 管理器。"""
    
    SCHEMA_VERSION = "1.0"
    
    def __init__(self, manifest_path: Path):
        self.manifest_path = manifest_path
        self.data: Dict[str, Any] = {
            "schema_version": self.SCHEMA_VERSION,
            "job": {},
            "artifacts": {},
            "phases": {},
            "gates": {},
        }
        self._load()
    
    def _load(self) -> None:
        """从文件加载 manifest。"""
        if self.manifest_path.exists():
            with open(self.manifest_path, "r", encoding="utf-8") as f:
                self.data = json.load(f)
            # 兼容旧版 manifest（无 gates 段）
            if "gates" not in self.data:
                self.data["gates"] = {}
        else:
            # 初始化新 manifest
            self.data = {
                "schema_version": self.SCHEMA_VERSION,
                "job": {},
                "artifacts": {},
                "phases": {},
                "gates": {},
            }
    
    def save(self) -> None:
        """保存 manifest 到文件（原子写入）。"""
        content = json.dumps(self.data, indent=2, ensure_ascii=False)
        atomic_write(content, self.manifest_path)
    
    def set_job(self, job_id: str, workspace: str) -> None:
        """设置 job 信息。"""
        self.data["job"] = {
            "job_id": job_id,
            "workspace": workspace,
        }
    
    def get_artifact(self, key: str, required_by: Optional[str] = None) -> Artifact:
        """
        获取 artifact（找不到就报错并提示 requires 缺失）。
        
        Args:
            key: artifact key
            required_by: 请求该 artifact 的 phase 名称（用于错误提示）
        
        Returns:
            Artifact 对象
        
        Raises:
            ValueError: 如果 artifact 不存在
        """
        artifact_data = self.data["artifacts"].get(key)
        if artifact_data is None:
            error_msg = f"Required artifact '{key}' not found in manifest"
            if required_by:
                error_msg += f" (required by phase '{required_by}')"
            error_msg += f". Available artifacts: {list(self.data['artifacts'].keys())}"
            raise ValueError(error_msg)
        
        # 兼容旧版本：旧 manifest 使用 "path" 字段，新版本使用 "relpath"
        relpath = artifact_data.get("relpath")
        if relpath is None and "path" in artifact_data:
            relpath = artifact_data["path"]
            # 尝试就地升级内存中的结构，后续 save() 会写回新的字段名
            artifact_data["relpath"] = relpath
            artifact_data.pop("path", None)

        return Artifact(
            key=artifact_data["key"],
            relpath=relpath,
            kind=artifact_data["kind"],
            fingerprint=artifact_data["fingerprint"],
            meta=artifact_data.get("meta", {}),
        )
    
    def register_artifact(self, artifact: Artifact) -> None:
        """注册 artifact 到 registry。"""
        self.data["artifacts"][artifact.key] = {
            "key": artifact.key,
            "relpath": artifact.relpath,
            "kind": artifact.kind,
            "fingerprint": artifact.fingerprint,
            "meta": artifact.meta,
        }
    
    def get_phase_status(self, phase_name: str) -> Optional[Status]:
        """获取 phase 状态。"""
        phase_data = self.data["phases"].get(phase_name)
        if phase_data is None:
            return None
        return phase_data.get("status")
    
    def update_phase(
        self,
        phase_name: str,
        *,
        version: str,
        status: Status,
        started_at: Optional[str] = None,
        finished_at: Optional[str] = None,
        attempt: int = 1,
        requires: Optional[List[str]] = None,
        provides: Optional[List[str]] = None,
        inputs_fingerprint: Optional[str] = None,
        config_fingerprint: Optional[str] = None,
        artifacts: Optional[Dict[str, Artifact]] = None,
        metrics: Optional[Dict[str, Any]] = None,
        warnings: Optional[List[str]] = None,
        error: Optional[ErrorInfo] = None,
        skipped: Optional[bool] = None,
    ) -> None:
        """更新 phase 记录。"""
        if phase_name not in self.data["phases"]:
            self.data["phases"][phase_name] = {}
        
        phase_data = self.data["phases"][phase_name]
        phase_data["name"] = phase_name
        phase_data["version"] = version
        phase_data["status"] = status
        
        if started_at:
            phase_data["started_at"] = started_at
        if finished_at:
            phase_data["finished_at"] = finished_at
        if attempt:
            phase_data["attempt"] = attempt
        if requires is not None:
            phase_data["requires"] = requires
        if provides is not None:
            phase_data["provides"] = provides
        if inputs_fingerprint:
            phase_data["inputs_fingerprint"] = inputs_fingerprint
        if config_fingerprint:
            phase_data["config_fingerprint"] = config_fingerprint
        if artifacts:
            # 将 artifacts 转换为字典格式
            phase_data["artifacts"] = {
                key: {
                    "key": artifact.key,
                    "relpath": artifact.relpath,
                    "kind": artifact.kind,
                    "fingerprint": artifact.fingerprint,
                    "meta": artifact.meta,
                }
                for key, artifact in artifacts.items()
            }
        if metrics:
            phase_data["metrics"] = metrics
        if warnings:
            phase_data["warnings"] = warnings
        if error:
            phase_data["error"] = {
                "type": error.type,
                "message": error.message,
                "traceback": error.traceback,
            }
        if skipped is not None:
            phase_data["skipped"] = skipped
    
    def get_phase_data(self, phase_name: str) -> Optional[Dict[str, Any]]:
        """获取 phase 数据。"""
        return self.data["phases"].get(phase_name)

    # ── Gate 方法 ──────────────────────────────────────────────

    def get_gate_status(self, gate_key: str) -> Optional[GateStatus]:
        """获取 gate 状态。"""
        gate_data = self.data["gates"].get(gate_key)
        if gate_data is None:
            return None
        return gate_data.get("status")

    def update_gate(
        self,
        gate_key: str,
        *,
        status: GateStatus,
        started_at: Optional[str] = None,
        finished_at: Optional[str] = None,
    ) -> None:
        """更新 gate 记录。"""
        if gate_key not in self.data["gates"]:
            self.data["gates"][gate_key] = {}

        gate_data = self.data["gates"][gate_key]
        gate_data["key"] = gate_key
        gate_data["status"] = status

        if started_at:
            gate_data["started_at"] = started_at
        if finished_at:
            gate_data["finished_at"] = finished_at
    
    def get_all_artifacts(self) -> Dict[str, Artifact]:
        """获取所有 artifacts。"""
        return {
            key: self.get_artifact(key)
            for key in self.data["artifacts"].keys()
        }
    
    def _resolve_artifact_path(self, key: str, workspace: Path) -> Path:
        return resolve_artifact_path(key, workspace)


# ── Module-level functions ─────────────────────────────────────

def resolve_artifact_path(key: str, workspace: Path) -> Path:
    """
    根据 artifact key 解析最终文件路径。

    Shared by Manifest and DbManifest.

    Args:
        key: artifact key（如 "subs.subtitle_model"）
        workspace: workspace 根目录

    Returns:
        最终文件路径（绝对路径）
    """
    parts = key.split(".", 1)
    if len(parts) == 2:
        domain, obj = parts
    else:
        domain = "misc"
        obj = key

    # 路径映射规则（workspace-relative）
    # 按资产生命周期分层：
    #   input/   — 不可变，创建后不修改
    #   state/   — SSOT，人工可编辑
    #   derived/ — 可重算的中间产物
    #   output/  — 最终交付物
    path_map = {
        "extract": {
            "audio": "input/{episode_stem}.wav",
            "vocals": "input/{episode_stem}-vocals.wav",
            "accompaniment": "input/{episode_stem}-accompaniment.wav",
        },
        "asr": {
            "asr_result": "input/asr-result.json",
            "asr_model": "state/dub.json",
        },
        "subs": {
            "subtitle_model": "state/subtitle.model.json",
            "subtitle_align": "derived/subtitle.align.json",
            "zh_srt": "output/zh.srt",
            "en_srt": "output/en.srt",
        },
        "mt": {
            "mt_input": "derived/mt/input.jsonl",
            "mt_output": "derived/mt/output.jsonl",
        },
        "tts": {
            "audio": "derived/{episode_stem}-tts.wav",
            "voice_assignment": "derived/voice-assignment.json",
            "sentence": "derived/tts/sentence.json",
            "segments_dir": "derived/tts/segments",
            "segments_index": "derived/tts/segments.json",
            "report": "derived/tts/report.json",
        },
        "voiceprint": {
            "speaker_map": "derived/voiceprint/speaker_map.json",
            "reference_clips": "derived/voiceprint/refs",
        },
        "dub": {
            "dub_manifest": "state/dub.json",
        },
        "mix": {
            "audio": "derived/{episode_stem}-mix.wav",
        },
        "burn": {
            "video": "output/{episode_stem}-dubbed.mp4",
        },
    }

    if domain in path_map and obj in path_map[domain]:
        path_template = path_map[domain][obj]
    else:
        path_template = f"{domain}/{obj}"

    episode_stem = workspace.name
    path_str = path_template.format(episode_stem=episode_stem)

    return workspace / path_str


def now_iso() -> str:
    """返回当前时间的 ISO 格式字符串。"""
    return datetime.now(timezone.utc).isoformat()


# ── DbManifest ─────────────────────────────────────────────────

class DbManifest:
    """DB-backed Manifest: episode-level, phase data from tasks table."""

    def __init__(self, store, episode_id: int, workspace: Path):
        self.store = store
        self.episode_id = episode_id
        self.workspace = workspace
        self._current_task_id: Optional[int] = None

    def set_current_task(self, task_id: int) -> None:
        """Set the task that update_phase writes to."""
        self._current_task_id = task_id

    def save(self) -> None:
        """DB operations are immediate; no-op for compatibility."""
        pass

    def set_job(self, job_id: str, workspace: str) -> None:
        pass  # no-op, episode-based now

    def get_artifact(self, key: str, required_by: Optional[str] = None) -> Artifact:
        row = self.store.get_artifact(self.episode_id, key)
        if row is None:
            error_msg = f"Required artifact '{key}' not found in manifest"
            if required_by:
                error_msg += f" (required by phase '{required_by}')"
            raise ValueError(error_msg)
        return Artifact(
            key=row["key"],
            relpath=row["relpath"],
            kind=row["kind"],
            fingerprint=row["fingerprint"],
        )

    def register_artifact(self, artifact: Artifact) -> None:
        self.store.upsert_artifact(
            self.episode_id,
            artifact.key,
            artifact.relpath,
            artifact.kind,
            artifact.fingerprint,
        )

    def get_all_artifacts(self) -> Dict[str, Artifact]:
        rows = self.store.get_all_artifacts(self.episode_id)
        return {
            r["key"]: Artifact(
                key=r["key"],
                relpath=r["relpath"],
                kind=r["kind"],
                fingerprint=r["fingerprint"],
            )
            for r in rows
        }

    def get_phase_status(self, phase_name: str) -> Optional[Status]:
        task = self.store.get_latest_succeeded_task(self.episode_id, phase_name)
        return task["status"] if task else None

    def get_phase_data(self, phase_name: str) -> Optional[Dict[str, Any]]:
        """Get phase data from the latest succeeded task."""
        task = self.store.get_latest_succeeded_task(self.episode_id, phase_name)
        if task is None:
            return None
        ctx = json.loads(task["context"] or "{}")
        # Build artifacts sub-dict from provides list in context
        provides = ctx.get("provides", [])
        phase_artifacts = {}
        for key in provides:
            art = self.store.get_artifact(self.episode_id, key)
            if art:
                phase_artifacts[key] = art
        return {
            "name": phase_name,
            "version": ctx.get("version"),
            "status": task["status"],
            "config_fingerprint": ctx.get("config_fingerprint"),
            "started_at": task.get("claimed_at"),
            "finished_at": task.get("finished_at"),
            "error": task.get("error"),
            "skipped": ctx.get("skipped", False),
            "metrics": ctx.get("metrics", {}),
            "artifacts": phase_artifacts,
        }

    def update_phase(
        self,
        phase_name: str,
        *,
        version: str,
        status: Status,
        started_at: Optional[str] = None,
        finished_at: Optional[str] = None,
        attempt: int = 1,
        requires: Optional[List[str]] = None,
        provides: Optional[List[str]] = None,
        inputs_fingerprint: Optional[str] = None,
        config_fingerprint: Optional[str] = None,
        artifacts: Optional[Dict[str, Artifact]] = None,
        metrics: Optional[Dict[str, Any]] = None,
        warnings: Optional[List[str]] = None,
        error: Optional[ErrorInfo] = None,
        skipped: Optional[bool] = None,
    ) -> None:
        # Write metadata to the current task's context
        if self._current_task_id is not None:
            updates: Dict[str, Any] = {"version": version}
            if requires is not None:
                updates["requires"] = requires
            if provides is not None:
                updates["provides"] = provides
            if config_fingerprint:
                updates["config_fingerprint"] = config_fingerprint
            if metrics:
                updates["metrics"] = metrics
            if skipped is not None:
                updates["skipped"] = skipped
            if error:
                updates["error_detail"] = {
                    "type": error.type,
                    "message": error.message,
                    "traceback": error.traceback,
                }
            self.store.update_task_context(self._current_task_id, updates)

        # Register artifacts to the episode-level artifacts table
        if artifacts:
            for artifact in artifacts.values():
                self.register_artifact(artifact)

    def get_gate_status(self, gate_key: str) -> Optional[GateStatus]:
        task = self.store.get_gate_task(self.episode_id, gate_key)
        if task is None:
            return None
        # Map task status to gate status
        if task["status"] == "succeeded":
            return "passed"
        if task["status"] == "pending":
            return "awaiting"
        return "pending"

    def update_gate(
        self,
        gate_key: str,
        *,
        status: GateStatus,
        started_at: Optional[str] = None,
        finished_at: Optional[str] = None,
    ) -> None:
        pass  # Gates are now tasks, managed by reactor

    def _resolve_artifact_path(self, key: str, workspace: Path) -> Path:
        return resolve_artifact_path(key, workspace)
