"""
CLI entry point for video_remix pipeline
"""
import argparse
import sys
from pathlib import Path

from video_remix.config.settings import PipelineConfig, load_env_file
from video_remix.pipeline.phase_runner import run_pipeline, PHASES
from video_remix.utils.logger import info, error


def main():
    """Main CLI entry point"""
    parser = argparse.ArgumentParser(
        description="Video dubbing pipeline with phase-based execution",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=f"""
Phases: {' -> '.join(PHASES)}

Examples:
  vsd run video.mp4 --to asr-zh     # Run up to ASR phase
  vsd run video.mp4 --to burn       # Run complete pipeline
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
        choices=PHASES,
        help="Target phase to run up to"
    )
    run_parser.add_argument(
        "--from",
        type=str,
        dest="from_phase",
        choices=PHASES,
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
        info(f"Available phases: {' -> '.join(PHASES)}")
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
            # Run phases
            outputs = run_pipeline(
                video_path=str(video_path),
                to_phase=args.to,
                from_phase=args.from_phase,
                config=config,
            )

            info("Pipeline completed successfully")
            for key, path in outputs.items():
                info(f"{key}: {path}")
        except Exception as e:
            error(f"Pipeline failed: {e}")
            sys.exit(1)


if __name__ == "__main__":
    main()
