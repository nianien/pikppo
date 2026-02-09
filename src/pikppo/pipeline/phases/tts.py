"""
TTS Phase: 语音合成（Timeline-First Architecture）

输入: dub_manifest.json (from Align phase)
输出:
  - tts.segments_dir: Per-segment WAV files
  - tts.report: TTS synthesis report (JSON)
  - tts.voice_assignment: Speaker -> voice mapping

不再生成拼接后的 tts.audio，拼接在 Mix phase 进行。
"""
import json
import shutil
from pathlib import Path
from typing import Dict

from pikppo.pipeline.core.phase import Phase
from pikppo.pipeline.core.types import Artifact, ErrorInfo, PhaseResult, RunContext, ResolvedOutputs
from pikppo.pipeline.processors.tts import run_per_segment as tts_run_per_segment
from pikppo.models.voice_pool import DEFAULT_VOICE_POOL
from pikppo.schema.dub_manifest import dub_manifest_from_dict
from pikppo.schema.tts_report import tts_report_to_dict
from pikppo.utils.logger import info, warning


class TTSPhase(Phase):
    """语音合成 Phase。"""
    
    name = "tts"
    version = "1.0.0"
    
    def requires(self) -> list[str]:
        """需要 dub.dub_manifest（SSOT for dubbing）和 demux.audio（可选，用于声线分配）。"""
        return ["dub.dub_manifest", "demux.audio"]

    def provides(self) -> list[str]:
        """生成 per-segment WAVs, tts_report, voice_assignment。"""
        return ["tts.segments_dir", "tts.report", "tts.voice_assignment"]
    
    def run(
        self,
        ctx: RunContext,
        inputs: Dict[str, Artifact],
        outputs: ResolvedOutputs,
    ) -> PhaseResult:
        """
        执行 TTS Phase (Timeline-First Architecture)。

        流程：
        1. 读取 dub_manifest.json (SSOT for dubbing)
        2. 分配声线
        3. TTS per-segment 合成 (不拼接)
        4. 生成 tts_report.json
        """
        # 获取输入 (dub_manifest.json)
        dub_manifest_artifact = inputs.get("dub.dub_manifest")
        if not dub_manifest_artifact:
            return PhaseResult(
                status="failed",
                error=ErrorInfo(
                    type="ValueError",
                    message="dub.dub_manifest artifact not found. Make sure align phase completed successfully.",
                ),
            )

        dub_manifest_path = Path(ctx.workspace) / dub_manifest_artifact.relpath
        if not dub_manifest_path.exists():
            return PhaseResult(
                status="failed",
                error=ErrorInfo(
                    type="FileNotFoundError",
                    message=f"Dub manifest file not found: {dub_manifest_path}",
                ),
            )

        audio_artifact = inputs.get("demux.audio")
        audio_path = None
        if audio_artifact:
            audio_path = Path(ctx.workspace) / audio_artifact.relpath

        workspace_path = Path(ctx.workspace)

        # 获取配置
        phase_config = ctx.config.get("phases", {}).get("tts", {})

        # TTS 引擎选择（默认 azure）
        engine = phase_config.get("engine", ctx.config.get("tts_engine", "azure"))
        info(f"TTS engine: {engine}")

        # Azure 配置
        azure_key = phase_config.get("azure_key", ctx.config.get("azure_tts_key"))
        azure_region = phase_config.get("azure_region", ctx.config.get("azure_tts_region"))
        azure_language = phase_config.get("azure_language", ctx.config.get("azure_tts_language", "en-US"))

        # VolcEngine 配置（支持从环境变量读取）
        import os
        volcengine_app_id = (
            phase_config.get("volcengine_app_id") or
            ctx.config.get("volcengine_app_id") or
            os.environ.get("DOUBAO_APPID") or
            os.environ.get("VOLC_APP_ID")
        )
        volcengine_access_key = (
            phase_config.get("volcengine_access_key") or
            ctx.config.get("volcengine_access_key") or
            os.environ.get("DOUBAO_ACCESS_TOKEN") or
            os.environ.get("VOLC_ACCESS_KEY")
        )
        volcengine_resource_id = phase_config.get("volcengine_resource_id", ctx.config.get("volcengine_resource_id", "seed-tts-1.0"))
        volcengine_format = phase_config.get("volcengine_format", ctx.config.get("volcengine_format", "pcm"))
        volcengine_sample_rate = phase_config.get("volcengine_sample_rate", ctx.config.get("volcengine_sample_rate", 24000))

        # 通用配置
        max_workers = phase_config.get("max_workers", ctx.config.get("tts_max_workers", 4))
        voice_pool_path = phase_config.get("voice_pool_path", ctx.config.get("voice_pool_path"))

        # 验证引擎配置
        if engine == "azure":
            if not azure_key or not azure_region:
                return PhaseResult(
                    status="failed",
                    error=ErrorInfo(
                        type="ValueError",
                        message="Azure TTS credentials not set (azure_key and azure_region required)",
                    ),
                )
        elif engine == "volcengine":
            if not volcengine_app_id or not volcengine_access_key:
                return PhaseResult(
                    status="failed",
                    error=ErrorInfo(
                        type="ValueError",
                        message="VolcEngine TTS credentials not set (volcengine_app_id and volcengine_access_key required). "
                                "You can set them via environment variables: DOUBAO_APPID and DOUBAO_ACCESS_TOKEN, "
                                "or in config: phases.tts.volcengine_app_id and phases.tts.volcengine_access_key",
                    ),
                )
        else:
            return PhaseResult(
                status="failed",
                error=ErrorInfo(
                    type="ValueError",
                    message=f"Unknown TTS engine: {engine}. Supported engines: 'azure', 'volcengine'",
                ),
            )

        try:
            # 读取 dub_manifest.json
            with open(dub_manifest_path, "r", encoding="utf-8") as f:
                manifest_data = json.load(f)

            dub_manifest = dub_manifest_from_dict(manifest_data)
            info(f"Loaded dub manifest: {len(dub_manifest.utterances)} utterances, audio_duration_ms={dub_manifest.audio_duration_ms}")

            if not dub_manifest.utterances:
                return PhaseResult(
                    status="failed",
                    error=ErrorInfo(
                        type="ValueError",
                        message="No utterances found in dub_manifest.json.",
                    ),
                )

            # 准备 voice pool
            if not voice_pool_path:
                cache_dir = workspace_path / ".cache"
                cache_dir.mkdir(exist_ok=True)
                pool_file = cache_dir / "voice_pool.json"
                with open(pool_file, "w", encoding="utf-8") as f:
                    json.dump(DEFAULT_VOICE_POOL, f, indent=2, ensure_ascii=False)
                voice_pool_path = str(pool_file)

            # 输出路径
            segments_dir = outputs.get("tts.segments_dir")
            segments_dir.mkdir(parents=True, exist_ok=True)

            # 调用 Processor 层 (per-segment synthesis)
            temp_dir = str(workspace_path / ".cache" / "tts")
            Path(temp_dir).mkdir(parents=True, exist_ok=True)

            # 根据引擎选择参数
            if engine == "azure":
                result = tts_run_per_segment(
                    dub_manifest=dub_manifest,
                    segments_dir=str(segments_dir),
                    reference_audio_path=str(audio_path) if audio_path and audio_path.exists() else None,
                    voice_pool_path=voice_pool_path,
                    engine=engine,
                    azure_key=azure_key,
                    azure_region=azure_region,
                    language=azure_language,
                    max_workers=max_workers,
                    temp_dir=temp_dir,
                )
            elif engine == "volcengine":
                result = tts_run_per_segment(
                    dub_manifest=dub_manifest,
                    segments_dir=str(segments_dir),
                    reference_audio_path=str(audio_path) if audio_path and audio_path.exists() else None,
                    voice_pool_path=voice_pool_path,
                    engine=engine,
                    volcengine_app_id=volcengine_app_id,
                    volcengine_access_key=volcengine_access_key,
                    volcengine_resource_id=volcengine_resource_id,
                    volcengine_format=volcengine_format,
                    volcengine_sample_rate=volcengine_sample_rate,
                    language=azure_language,
                    max_workers=max_workers,
                    temp_dir=temp_dir,
                )
            else:
                raise ValueError(f"Unknown TTS engine: {engine}")

            # 从 ProcessorResult 提取数据
            voice_assignment = result.data["voice_assignment"]
            tts_report = result.data["tts_report"]

            # Check for failures
            if not tts_report.all_succeeded:
                failed_segments = [s for s in tts_report.segments if s.error]
                error_msgs = [f"{s.utt_id}: {s.error}" for s in failed_segments[:5]]
                warning(f"TTS had {tts_report.failed_count} failures: {error_msgs}")

            # Phase 层负责文件 IO：保存 voice_assignment.json
            voice_assignment_path = outputs.get("tts.voice_assignment")
            voice_assignment_path.parent.mkdir(parents=True, exist_ok=True)
            with open(voice_assignment_path, "w", encoding="utf-8") as f:
                json.dump(voice_assignment, f, indent=2, ensure_ascii=False)

            # 保存 tts_report.json
            report_path = outputs.get("tts.report")
            report_path.parent.mkdir(parents=True, exist_ok=True)
            with open(report_path, "w", encoding="utf-8") as f:
                json.dump(tts_report_to_dict(tts_report), f, indent=2, ensure_ascii=False)
            info(f"Saved TTS report: {tts_report.total_segments} segments, {tts_report.success_count} succeeded")

            # 清理临时目录
            temp_path = Path(temp_dir)
            if temp_path.exists():
                for item in temp_path.iterdir():
                    if item.is_file():
                        item.unlink(missing_ok=True)

            info(f"TTS synthesis completed: {tts_report.success_count}/{tts_report.total_segments} segments")

            # 返回 PhaseResult
            return PhaseResult(
                status="succeeded",
                outputs=["tts.segments_dir", "tts.report", "tts.voice_assignment"],
                metrics={
                    "total_segments": tts_report.total_segments,
                    "success_count": tts_report.success_count,
                    "failed_count": tts_report.failed_count,
                    "audio_duration_ms": dub_manifest.audio_duration_ms,
                },
            )

        except Exception as e:
            import traceback
            return PhaseResult(
                status="failed",
                error=ErrorInfo(
                    type=type(e).__name__,
                    message=str(e),
                    traceback=traceback.format_exc(),
                ),
            )
