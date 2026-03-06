"""
PhaseRunner: 执行协议 + should_run 决策
"""
import traceback
from pathlib import Path
from typing import Any, Dict, Optional

from dubora.pipeline.core.types import Artifact, ErrorInfo, RunContext, ResolvedOutputs
from dubora.pipeline.core.phase import Phase
from dubora.pipeline.core.manifest import Manifest, now_iso
from dubora.pipeline.core.fingerprints import (
    compute_config_fingerprint,
    hash_path,
)
from dubora.utils.logger import info, warning, error


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
        config: Optional[Dict[str, Any]] = None,
    ) -> tuple[bool, Optional[str]]:
        """
        判断 phase 是否需要运行。

        检查顺序：
        1. force 标记
        2. manifest 中是否有记录
        3. phase.version 是否变化
        4. 输入一致性校验（逐个检查 required artifact 文件内容是否与全局注册表一致）
        5. config fingerprint 是否变化（配置参数变了）
        6. 输出文件是否存在
        7. status 是否为 succeeded

        Returns:
            (should_run, reason) 元组
        """
        if force:
            return True, "forced"

        phase_data = self.manifest.get_phase_data(phase.name)

        # 1. manifest 中没有该 phase 记录
        if phase_data is None:
            return True, "not in manifest"

        # 2. phase.version 变化
        if phase_data.get("version") != phase.version:
            return True, f"version changed: {phase_data.get('version')} -> {phase.version}"

        # 3. 检查输入文件（requires）是否存在
        required_keys = phase.requires()
        for key in required_keys:
            try:
                artifact = self.manifest.get_artifact(key)
            except ValueError:
                return True, f"required input artifact '{key}' not found in manifest"

            artifact_path = self.workspace / artifact.relpath
            if not artifact_path.exists():
                return True, f"required input artifact '{key}' file not found: {artifact_path}"

        # 4. 输入一致性校验：逐个检查 required artifact 的文件内容是否与全局注册表一致
        for key in required_keys:
            try:
                artifact = self.manifest.get_artifact(key)
                artifact_path = self.workspace / artifact.relpath
                current_fp = hash_path(artifact_path)
                if current_fp != artifact.fingerprint:
                    return True, f"input '{key}' content changed (file differs from registered fingerprint)"
            except Exception:
                pass  # fingerprint 计算失败不阻塞，退化到后续检查

        # 5. config fingerprint 变化（配置参数变了 → 需要重跑）
        stored_config_fp = phase_data.get("config_fingerprint")
        if stored_config_fp and config is not None:
            try:
                current_config_fp = compute_config_fingerprint(phase.name, config)
                if stored_config_fp != current_config_fp:
                    return True, "config fingerprint changed"
            except Exception:
                pass

        # 6. 检查输出文件是否存在（不比较 fingerprint，允许人工原地编辑）
        phase_artifacts = phase_data.get("artifacts", {})
        if not phase_artifacts:
            return True, "no artifacts found in phase data"

        for key, artifact_data in phase_artifacts.items():
            relpath = artifact_data.get("relpath")
            if not relpath:
                return True, f"output artifact '{key}' has no relpath in phase data"

            artifact_path = self.workspace / relpath
            if not artifact_path.exists():
                return True, f"output artifact '{key}' file not found: {artifact_path}"

        # 7. 如果 status 不是 "succeeded"，也需要重新运行
        if phase_data.get("status") != "succeeded":
            return True, f"status is {phase_data.get('status')} (expected 'succeeded')"

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
            artifact = self.manifest.get_artifact(key, required_by=phase.name)
            artifacts[key] = artifact
        
        return artifacts
    
    def allocate_outputs(
        self,
        phase: Phase,
    ) -> ResolvedOutputs:
        """
        为 phase 分配输出路径（Runner 负责路径分配）。
        
        Args:
            phase: Phase 实例
        
        Returns:
            ResolvedOutputs，包含 artifact_key -> absolute Path 映射
        """
        provided_keys = phase.provides()
        paths = {}
        
        for key in provided_keys:
            # 使用 manifest 的路径解析逻辑
            absolute_path = self.manifest._resolve_artifact_path(key, self.workspace)
            # 确保父目录存在
            absolute_path.parent.mkdir(parents=True, exist_ok=True)
            paths[key] = absolute_path
        
        return ResolvedOutputs(paths=paths)
    
    def _guess_artifact_kind(self, path: Path) -> str:
        """
        根据文件路径猜测 artifact kind。

        Args:
            path: 文件路径

        Returns:
            artifact kind（"json", "srt", "wav", "mp4", "dir" 等）
        """
        if path.is_dir():
            return "dir"
        suffix = path.suffix.lower()
        kind_map = {
            ".json": "json",
            ".srt": "srt",
            ".wav": "wav",
            ".mp4": "mp4",
            ".mp3": "mp3",
        }
        return kind_map.get(suffix, "bin")
    
    # 旧的 publish_artifacts 方法已由 run_phase 内逻辑取代，保留空壳以防外部调用。
    # 新约定：Runner 是唯一提交者，Phase/Processor 只写文件，Runner 直接构造 Artifact 并注册到 manifest。
    def publish_artifacts(
        self,
        artifacts: Dict[str, Artifact],
    ) -> Dict[str, Artifact]:
        """
        兼容旧接口的空实现。

        新实现中不再使用该方法，Artifact 的构造和注册在 run_phase 中完成。
        """
        for artifact in artifacts.values():
            self.manifest.register_artifact(artifact)
        return artifacts
    
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
        should_run, reason = self.should_run(phase, force=force, config=ctx.config)
        
        if not should_run:
            info(f"Phase '{phase.name}' skipped: {reason}")
            # 如果 phase 已经是 succeeded，保持 succeeded 状态，不要改成 skipped
            # 否则下次检查时会因为 status != "succeeded" 而重新执行
            phase_data = self.manifest.get_phase_data(phase.name)
            current_status = phase_data.get("status") if phase_data else None
            skip_status = "skipped" if current_status != "succeeded" else "succeeded"
            
            self.manifest.update_phase(
                phase.name,
                version=phase.version,
                status=skip_status,
                finished_at=now_iso(),
                skipped=True,  # 标记为跳过
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
        
        # 计算 config fingerprint
        try:
            config_fp = compute_config_fingerprint(phase.name, ctx.config)
        except Exception as e:
            warning(f"Failed to compute config fingerprint for phase '{phase.name}': {e}")
            config_fp = None

        # 标记为 running
        self.manifest.update_phase(
            phase.name,
            version=phase.version,
            status="running",
            started_at=now_iso(),
            requires=phase.requires(),
            provides=phase.provides(),
            config_fingerprint=config_fp,
            skipped=False,  # 标记为执行（非跳过）
        )
        self.manifest.save()
        
        # 分配输出路径（Runner 负责路径分配）
        outputs = self.allocate_outputs(phase)
        
        # 执行 phase
        try:
            info(f"Running phase '{phase.name}'...")
            result = phase.run(ctx, inputs, outputs)
            
            if result.status == "succeeded":
                # 1) 验证所有声明的 outputs 是否都已写入文件
                published_artifacts: Dict[str, Artifact] = {}
                for key in result.outputs:
                    if key not in outputs.paths:
                        raise ValueError(
                            f"Phase '{phase.name}' declared output '{key}' "
                            "which is not in phase.provides() / allocated outputs"
                        )
                    abs_path = outputs.paths[key]
                    if not abs_path.exists():
                        raise FileNotFoundError(
                            f"Phase '{phase.name}' did not write output file: {abs_path} "
                            f"(artifact key: {key})"
                        )
                    
                    relpath = str(abs_path.relative_to(self.workspace))
                    
                    # 2) 确定 artifact kind
                    kind = self._guess_artifact_kind(abs_path)
                    
                    # 3) 计算 fingerprint（支持文件和目录）
                    from dubora.pipeline.core.fingerprints import hash_path
                    fingerprint = hash_path(abs_path)
                    
                    artifact = Artifact(
                        key=key,
                        relpath=relpath,
                        kind=kind,
                        fingerprint=fingerprint,
                    )
                    # 4) 注册到 manifest
                    self.manifest.register_artifact(artifact)
                    published_artifacts[key] = artifact
                
                # 更新 manifest（写入 phase 级别的 artifacts/metrics 等）
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
            # 异常处理：打印完整的错误信息和 traceback
            error(f"Phase '{phase.name}' raised exception: {e}")
            error(f"Traceback:\n{traceback.format_exc()}")
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
    
    # run_pipeline() and _auto_advance() removed — orchestration is now
    # handled by PipelineEngine (pipeline/core/engine.py).