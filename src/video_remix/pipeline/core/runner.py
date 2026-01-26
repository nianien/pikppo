"""
PhaseRunner: 执行协议 + should_run 决策
"""
import traceback
from pathlib import Path
from typing import Dict, List, Optional

from video_remix.pipeline.core.types import Artifact, ErrorInfo, RunContext, Status
from video_remix.pipeline.core.phase import Phase
from video_remix.pipeline.core.manifest import Manifest, now_iso
from video_remix.pipeline.core.fingerprints import (
    compute_inputs_fingerprint,
    compute_config_fingerprint,
    hash_file,
    hash_json,
)
from video_remix.pipeline.core.atomic import atomic_copy
from video_remix.utils.logger import info, warning, error


class PhaseRunner:
    """Phase 执行器。"""
    
    def __init__(self, manifest: Manifest, workspace: Path):
        self.manifest = manifest
        self.workspace = workspace
    
    def should_run(
        self,
        phase: Phase,
        *,
        force: bool = False,
    ) -> tuple[bool, Optional[str]]:
        """
        判断 phase 是否需要运行。
        
        Returns:
            (should_run, reason) 元组
        """
        if force:
            return True, "forced"
        
        phase_data = self.manifest.get_phase_data(phase.name)
        
        # 1. manifest 中没有该 phase 记录
        if phase_data is None:
            return True, "not in manifest"
        
        # 2. phase.status != succeeded
        if phase_data.get("status") != "succeeded":
            return True, f"status is {phase_data.get('status')}"
        
        # 3. phase.version 变化
        if phase_data.get("version") != phase.version:
            return True, f"version changed: {phase_data.get('version')} -> {phase.version}"
        
        # 4. inputs_fingerprint 变化
        required_keys = phase.requires()
        artifacts = self.manifest.get_all_artifacts()
        
        try:
            current_inputs_fp = compute_inputs_fingerprint(required_keys, artifacts)
            stored_inputs_fp = phase_data.get("inputs_fingerprint")
            if stored_inputs_fp != current_inputs_fp:
                return True, f"inputs_fingerprint changed: {stored_inputs_fp} -> {current_inputs_fp}"
        except ValueError as e:
            # 缺少必需的 artifact
            return True, f"missing required artifact: {e}"
        
        # 5. config_fingerprint 变化
        # 需要从 manifest 中获取 config（这里简化处理，实际应该从 RunContext 获取）
        # 暂时跳过，因为 RunContext 不在 should_run 参数中
        
        # 6. provides 的输出 artifact 不存在或 fingerprint 不匹配
        provides_keys = phase.provides()
        for key in provides_keys:
            artifact = self.manifest.get_artifact(key)
            if artifact is None:
                return True, f"output artifact '{key}' not found"
            
            # 检查文件是否存在
            artifact_path = self.workspace / artifact.path
            if not artifact_path.exists():
                return True, f"output artifact '{key}' file not found: {artifact_path}"
            
            # 检查 fingerprint 是否匹配
            current_fp = hash_file(artifact_path)
            if artifact.fingerprint != current_fp:
                return True, f"output artifact '{key}' fingerprint mismatch: {artifact.fingerprint} != {current_fp}"
        
        # 所有检查通过，可以 skip
        return False, "all checks passed"
    
    def resolve_inputs(
        self,
        phase: Phase,
    ) -> Dict[str, Artifact]:
        """
        解析 phase 需要的 inputs。
        
        Returns:
            key -> Artifact 字典
        """
        required_keys = phase.requires()
        artifacts = {}
        
        for key in required_keys:
            artifact = self.manifest.get_artifact(key)
            if artifact is None:
                raise ValueError(f"Required artifact '{key}' not found in manifest")
            artifacts[key] = artifact
        
        return artifacts
    
    def publish_artifacts(
        self,
        artifacts: Dict[str, Artifact],
    ) -> Dict[str, Artifact]:
        """
        发布 artifacts（从临时路径移动到最终路径，并计算 fingerprint）。
        
        Args:
            artifacts: Phase 返回的 artifacts（path 可能是临时路径）
        
        Returns:
            更新后的 artifacts（包含最终路径和 fingerprint）
        """
        published = {}
        
        for key, artifact in artifacts.items():
            source_path = self.workspace / artifact.path
            
            if not source_path.exists():
                raise FileNotFoundError(f"Artifact source file not found: {source_path}")
            
            # 确定最终路径（如果已经是最终路径，就不移动）
            # 这里简化处理：假设 artifact.path 已经是最终路径
            final_path = source_path
            
            # 计算 fingerprint
            if artifact.kind == "json":
                import json
                content = json.loads(final_path.read_text(encoding="utf-8"))
                fingerprint = hash_json(content)
            else:
                fingerprint = hash_file(final_path)
            
            # 更新 artifact
            published_artifact = Artifact(
                key=artifact.key,
                path=artifact.path,  # 保持相对路径
                kind=artifact.kind,
                fingerprint=fingerprint,
                meta=artifact.meta,
            )
            
            published[key] = published_artifact
            
            # 注册到 manifest
            self.manifest.register_artifact(published_artifact)
        
        return published
    
    def run_phase(
        self,
        phase: Phase,
        ctx: RunContext,
        *,
        force: bool = False,
    ) -> bool:
        """
        运行 phase。
        
        Returns:
            是否成功
        """
        # 检查是否需要运行
        should_run, reason = self.should_run(phase, force=force)
        
        if not should_run:
            info(f"Phase '{phase.name}' skipped: {reason}")
            self.manifest.update_phase(
                phase.name,
                version=phase.version,
                status="skipped",
                finished_at=now_iso(),
            )
            self.manifest.save()
            return True
        
        # 解析 inputs
        try:
            inputs = self.resolve_inputs(phase)
        except ValueError as e:
            error(f"Phase '{phase.name}' failed to resolve inputs: {e}")
            self.manifest.update_phase(
                phase.name,
                version=phase.version,
                status="failed",
                finished_at=now_iso(),
                error=ErrorInfo(
                    type="InputResolutionError",
                    message=str(e),
                ),
            )
            self.manifest.save()
            return False
        
        # 计算 fingerprints
        try:
            artifacts = self.manifest.get_all_artifacts()
            inputs_fp = compute_inputs_fingerprint(phase.requires(), artifacts)
            config_fp = compute_config_fingerprint(phase.name, ctx.config)
        except Exception as e:
            warning(f"Failed to compute fingerprints for phase '{phase.name}': {e}")
            inputs_fp = None
            config_fp = None
        
        # 标记为 running
        self.manifest.update_phase(
            phase.name,
            version=phase.version,
            status="running",
            started_at=now_iso(),
            requires=phase.requires(),
            provides=phase.provides(),
            inputs_fingerprint=inputs_fp,
            config_fingerprint=config_fp,
        )
        self.manifest.save()
        
        # 执行 phase
        try:
            info(f"Running phase '{phase.name}'...")
            result = phase.run(ctx, inputs)
            
            if result.status == "succeeded":
                # 发布 artifacts
                published_artifacts = self.publish_artifacts(result.artifacts)
                
                # 更新 manifest
                self.manifest.update_phase(
                    phase.name,
                    version=phase.version,
                    status="succeeded",
                    finished_at=now_iso(),
                    artifacts=published_artifacts,
                    metrics=result.metrics,
                    warnings=result.warnings,
                )
                self.manifest.save()
                
                info(f"Phase '{phase.name}' succeeded")
                return True
            else:
                # 失败
                self.manifest.update_phase(
                    phase.name,
                    version=phase.version,
                    status="failed",
                    finished_at=now_iso(),
                    error=result.error,
                    warnings=result.warnings,
                )
                self.manifest.save()
                
                error(f"Phase '{phase.name}' failed: {result.error.message if result.error else 'unknown error'}")
                return False
                
        except Exception as e:
            # 异常处理
            error(f"Phase '{phase.name}' raised exception: {e}")
            self.manifest.update_phase(
                phase.name,
                version=phase.version,
                status="failed",
                finished_at=now_iso(),
                error=ErrorInfo(
                    type=type(e).__name__,
                    message=str(e),
                    traceback=traceback.format_exc(),
                ),
            )
            self.manifest.save()
            return False
