"""
CLI entry point for pikppo pipeline (Pipeline Framework v1)
"""
import argparse
import sys
from pathlib import Path

from pikppo.config.settings import PipelineConfig, load_env_file
from pikppo.pipeline.phases import ALL_PHASES
from pikppo.utils.logger import info, error


def main():
    """Main CLI entry point"""
    phase_names = [phase.name for phase in ALL_PHASES]
    
    parser = argparse.ArgumentParser(
        description="Video dubbing pipeline with phase-based execution (Framework v1)",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=f"""
Phases: {' -> '.join(phase_names)}

Examples:
  vsd run video.mp4 --to asr     # Run up to ASR phase
  vsd run video.mp4 --to burn    # Run complete pipeline
  vsd run video.mp4 --from tts --to burn  # Force refresh from TTS to burn
        """
    )

    subparsers = parser.add_subparsers(dest="command", help="Command")

    # run command
    run_parser = subparsers.add_parser("run", help="Run pipeline phases")
    run_parser.add_argument("video", type=str, help="Input video file path")
    run_parser.add_argument(
        "--to",
        type=str,
        required=True,
        choices=phase_names,
        help="Target phase to run up to"
    )
    run_parser.add_argument(
        "--from",
        type=str,
        dest="from_phase",
        choices=phase_names,
        help="Force refresh from this phase (inclusive)"
    )
    run_parser.add_argument(
        "--config",
        type=str,
        help="Path to config file (optional)"
    )

    # phases command
    subparsers.add_parser("phases", help="List available phases")

    args = parser.parse_args()

    if not args.command:
        parser.print_help()
        sys.exit(1)

    # Load environment variables
    load_env_file()

    if args.command == "phases":
        info("Available phases:")
        for phase in ALL_PHASES:
            info(f"  - {phase.name} (v{phase.version}): requires={phase.requires()}, provides={phase.provides()}")
        return

    if args.command == "run":
        video_path = Path(args.video)
        if not video_path.exists():
            error(f"Video file not found: {video_path}")
            sys.exit(1)

        # Load config
        config = PipelineConfig()
        if args.config:
            # TODO: Load from config file if needed
            pass

        try:
            # TODO: Use new PhaseRunner from pipeline.core.runner
            # For now, show a message that the new framework is ready
            error("New Pipeline Framework v1 is ready, but CLI integration is pending.")
            error("Please use the PhaseRunner API directly for now.")
            info("\nNew framework structure:")
            info("  - pipeline/core/     : Framework layer (Phase, Manifest, Runner)")
            info("  - pipeline/phases/   : Phase implementations")
            info("  - pipeline/_shared/ : Shared utilities")
            sys.exit(1)
            
            # Future implementation:
            # from pikppo.pipeline.core.runner import PhaseRunner
            # from pikppo.pipeline.core.manifest import Manifest
            # runner = PhaseRunner(manifest, workspace)
            # runner.run_pipeline(...)
        except Exception as e:
            error(f"Pipeline failed: {e}")
            sys.exit(1)


if __name__ == "__main__":
    main()
