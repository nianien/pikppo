"""
CLI entry point for dubora pipeline

Commands:
  vsd run 家里家外 5 --to parse        # Submit task to DB
  vsd run 家里家外 4-70 --to burn      # Batch submit
  vsd worker                           # Long-running task executor
  vsd bless 家里家外 5 parse           # Accept manual edits
  vsd phases                           # List phases
  vsd ide                              # Web server (with worker thread)
"""
import argparse
import re
import sys
import threading
from importlib.metadata import version
from pathlib import Path
from typing import List

from dubora.config.settings import PipelineConfig, load_env_file
from dubora.pipeline.phases import ALL_PHASES, GATE_AFTER, build_phases
from dubora.pipeline.core.manifest import DbManifest
from dubora.pipeline.core.store import PipelineStore
from dubora.pipeline.core.worker import PipelineWorker, submit_pipeline
from dubora.utils.logger import info, warning, error, success

DEFAULT_DB = "data/dubora.db"


def expand_episode_range(ep_arg: str) -> List[str]:
    """
    解析集数参数：'5' → ['5'], '4-70' → ['4','5',...,'70']
    """
    m = re.match(r'^(\d+)-(\d+)$', ep_arg)
    if m:
        start, end = int(m.group(1)), int(m.group(2))
        return [str(i) for i in range(start, end + 1)]
    return [ep_arg]


def get_store(db_path: str = DEFAULT_DB) -> PipelineStore:
    p = Path(db_path)
    if not p.exists():
        error(f"Pipeline DB not found: {p.resolve()}")
        sys.exit(1)
    return PipelineStore(p)


def resolve_episodes(store: PipelineStore, drama_name: str, ep_arg: str) -> list[dict]:
    """Look up episodes from DB by drama name + episode range."""
    drama = store.get_drama_by_name(drama_name)
    if drama is None:
        error(f"Drama not found in DB: {drama_name}")
        sys.exit(1)

    ep_names = expand_episode_range(ep_arg)
    episodes = []
    for name in ep_names:
        ep = store.get_episode_by_names(drama_name, name)
        if ep is None:
            warning(f"Episode not found in DB: {drama_name} ep {name}")
        else:
            episodes.append(ep)

    if not episodes:
        error("No matching episodes found in DB")
        sys.exit(1)

    return episodes


# ── 主入口 ──────────────────────────────────────────────────

def main():
    """Main CLI entry point"""
    phase_names = [phase.name for phase in ALL_PHASES]

    parser = argparse.ArgumentParser(
        description="Video dubbing pipeline",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=f"""
Phases: {' -> '.join(phase_names)}

Examples:
  vsd run 家里家外 5 --to parse            # Submit single episode
  vsd run 家里家外 4-70 --to burn          # Batch submit
  vsd run 家里家外 1-10 --from mt --to tts # Force re-run range
  vsd worker                               # Start task executor
  vsd bless 家里家外 5 parse               # Accept manual edits
        """
    )
    parser.add_argument(
        "-V", "--version", action="version",
        version=f"%(prog)s {version('dubora')}",
    )
    parser.add_argument(
        "--db", type=str, default=DEFAULT_DB,
        help=f"Pipeline DB path (default: {DEFAULT_DB})",
    )

    subparsers = parser.add_subparsers(dest="command", help="Command")

    # run command
    run_parser = subparsers.add_parser("run", help="Submit pipeline tasks to DB")
    run_parser.add_argument("drama", type=str, help="Drama name")
    run_parser.add_argument("episodes", type=str, help="Episode number or range (e.g. 5 or 4-70)")
    run_parser.add_argument(
        "--to", type=str, choices=phase_names,
        help="Target phase to run up to (omit for auto-advance)",
    )
    run_parser.add_argument(
        "--from", type=str, dest="from_phase", choices=phase_names,
        help="Force refresh from this phase (inclusive)",
    )

    # worker command
    subparsers.add_parser("worker", help="Start long-running task executor")

    # bless command
    bless_parser = subparsers.add_parser(
        "bless", help="Accept manual edits: re-fingerprint a phase's output artifacts",
    )
    bless_parser.add_argument("drama", type=str, help="Drama name")
    bless_parser.add_argument("episodes", type=str, help="Episode number or range (e.g. 5 or 4-70)")
    bless_parser.add_argument("phase", type=str, choices=phase_names, help="Phase whose outputs to re-fingerprint")

    # phases command
    subparsers.add_parser("phases", help="List available phases")

    # ide command
    ide_parser = subparsers.add_parser("ide", help="Launch web server")
    ide_parser.add_argument("--port", type=int, default=8765, help="Server port (default: 8765)")
    ide_parser.add_argument("--videos", type=str, default="./videos", help="Videos directory (default: ./videos)")
    ide_parser.add_argument("--dev", action="store_true", help="Development mode")
    ide_parser.add_argument("--no-worker", action="store_true", help="Disable built-in worker thread")

    args = parser.parse_args()

    if not args.command:
        parser.print_help()
        sys.exit(1)

    if args.command == "run" and getattr(args, "from_phase", None) and getattr(args, "to", None):
        from_idx = phase_names.index(args.from_phase)
        to_idx = phase_names.index(args.to)
        if from_idx > to_idx:
            parser.error(f"--from ({args.from_phase}) must be before --to ({args.to})")

    load_env_file()

    if args.command == "phases":
        _cmd_phases()
        return

    if args.command == "ide":
        _cmd_ide(args)
        return

    if args.command == "worker":
        _cmd_worker(args)
        return

    # ── run / bless ──
    store = get_store(args.db)
    episodes = resolve_episodes(store, args.drama, args.episodes)
    is_batch = len(episodes) > 1
    if is_batch:
        info(f"Batch mode: {len(episodes)} episodes")

    failed = []

    if args.command == "run":
        config = PipelineConfig()
        phases = build_phases(config)
        for i, ep in enumerate(episodes):
            if is_batch:
                info(f"--- [{i+1}/{len(episodes)}] ep {ep['name']} ---")
            try:
                submit_pipeline(
                    store, ep["id"], phases, GATE_AFTER,
                    from_phase=args.from_phase, to_phase=args.to,
                )
                success(f"[ep {ep['name']}] Submitted")
            except Exception as e:
                error(f"[ep {ep['name']}] Submit failed: {e}")
                failed.append(ep["name"])

    elif args.command == "bless":
        for i, ep in enumerate(episodes):
            if is_batch:
                info(f"--- [{i+1}/{len(episodes)}] ep {ep['name']} ---")
            if not _bless_one(store, ep, args.phase):
                failed.append(ep["name"])

    if is_batch:
        ok_count = len(episodes) - len(failed)
        info(f"Batch complete: {ok_count}/{len(episodes)} succeeded")
        if failed:
            error(f"Failed: {', '.join(failed)}")
            sys.exit(1)


# ── Commands ──────────────────────────────────────────────

def _cmd_phases():
    from dubora.pipeline.phases import STAGES, GATE_AFTER
    phase_map = {p.name: p for p in ALL_PHASES}
    gate_count = len(GATE_AFTER)
    print(f"\nPipeline ({len(ALL_PHASES)} phases, {gate_count} gates):\n")
    print(f"  {'Stage':<8}{'Phase':<9}{'Version':<9}Gate")
    print(f"  {'──────':<8}{'───────':<9}{'───────':<9}────")
    for stage in STAGES:
        stage_label = stage["label"]
        for i, pname in enumerate(stage["phases"]):
            phase = phase_map[pname]
            label = stage_label if i == 0 else ""
            gate = GATE_AFTER.get(pname)
            gate_str = f"\u2190 {gate['label']}" if gate else ""
            print(f"  {label:<8}{phase.name:<9}{phase.version:<9}{gate_str}")
    print()


def _cmd_worker(args):
    store = get_store(args.db)
    config = PipelineConfig()
    phases = build_phases(config)
    worker = PipelineWorker(store, phases, GATE_AFTER)
    info("Worker started, polling for tasks... (Ctrl+C to stop)")
    try:
        worker.run_forever()
    except KeyboardInterrupt:
        info("Worker stopped")


def _bless_one(store: PipelineStore, episode: dict, phase_name: str):
    from dubora.pipeline.core.worker import _get_workdir
    video_path = Path(episode["path"])
    workdir = _get_workdir(video_path)
    episode_id = episode["id"]

    manifest = DbManifest(store, episode_id, workdir)
    phase_data = manifest.get_phase_data(phase_name)
    if phase_data is None:
        error(f"[ep {episode['name']}] Phase '{phase_name}' has no record in DB")
        return False

    phase_artifacts = phase_data.get("artifacts", {})
    if not phase_artifacts:
        error(f"[ep {episode['name']}] Phase '{phase_name}' has no output artifacts")
        return False

    from dubora.pipeline.core.fingerprints import hash_path

    updated = 0
    for key, artifact_data in phase_artifacts.items():
        relpath = artifact_data.get("relpath")
        if not relpath:
            continue
        artifact_path = workdir / relpath
        if not artifact_path.exists():
            error(f"  {key}: file not found ({artifact_path})")
            continue

        old_fp = artifact_data.get("fingerprint", "")
        new_fp = hash_path(artifact_path)
        if old_fp == new_fp:
            continue

        store.upsert_artifact(episode_id, key, relpath, artifact_data.get("kind", "bin"), new_fp)
        updated += 1
        info(f"  {key}: {old_fp[:16]}... -> {new_fp[:16]}...")

    if updated:
        success(f"[ep {episode['name']}] Blessed {updated} artifact(s) for phase '{phase_name}'")
    else:
        info(f"[ep {episode['name']}] All artifacts for phase '{phase_name}' are unchanged")
    return True


def _cmd_ide(args):
    try:
        import uvicorn
        from dubora.web.server import create_app
    except ImportError:
        error("IDE dependencies not installed. Run: make install-web")
        sys.exit(1)

    videos_dir = args.videos
    static_dir = None
    if not args.dev:
        import dubora
        pkg_dir = Path(dubora.__file__).parent
        web_dir = None
        for candidate in [
            Path("web"),
            pkg_dir.parent.parent.parent / "web",
        ]:
            if (candidate / "package.json").is_file():
                web_dir = candidate.resolve()
                break

        dist_dir = web_dir / "dist" if web_dir else None
        needs_build = False
        if dist_dir and dist_dir.is_dir():
            watch_dirs = [web_dir / "src", web_dir / "public"]
            watch_files = [f for d in watch_dirs if d.is_dir() for f in d.rglob("*") if f.is_file()]
            index_html = web_dir / "index.html"
            if index_html.is_file():
                watch_files.append(index_html)
            if watch_files:
                src_mtime = max(f.stat().st_mtime for f in watch_files)
                dist_mtime = max(f.stat().st_mtime for f in dist_dir.rglob("*") if f.is_file())
                if src_mtime > dist_mtime:
                    needs_build = True
                    info("Frontend source changed, rebuilding...")
            static_dir = str(dist_dir)
        elif web_dir:
            needs_build = True
            info("No frontend build found, building...")

        if needs_build and web_dir:
            import subprocess
            result = subprocess.run(
                ["npm", "run", "build"],
                cwd=str(web_dir),
                capture_output=True,
                text=True,
            )
            if result.returncode != 0:
                build_output = (result.stdout or "") + (result.stderr or "")
                error(f"Frontend build failed:\n{build_output}")
                sys.exit(1)
            static_dir = str(web_dir / "dist")
            info("Frontend build complete")

    app = create_app(videos_dir=videos_dir, static_dir=static_dir)

    # Start worker thread unless --no-worker
    if not args.no_worker:
        db_path = Path(DEFAULT_DB)
        if db_path.exists():
            store = PipelineStore(db_path)
            config = PipelineConfig()
            phases = build_phases(config)
            worker = PipelineWorker(store, phases, GATE_AFTER)
            stop_event = threading.Event()
            worker_thread = threading.Thread(
                target=worker.run_forever, args=(stop_event,), daemon=True,
            )
            worker_thread.start()
            info("Worker thread started")
        else:
            warning(f"Pipeline DB not found: {db_path}, worker disabled")

    info(f"Starting on http://localhost:{args.port}")
    info(f"Videos directory: {Path(videos_dir).resolve()}")
    if args.dev:
        info("Dev mode: use 'cd web && npm run dev' for frontend")
    elif static_dir:
        info(f"Serving frontend from: {static_dir}")

    uvicorn.run(app, host="0.0.0.0", port=args.port, log_level="info")


if __name__ == "__main__":
    main()
