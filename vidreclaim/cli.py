from __future__ import annotations

import argparse
import shutil
import sys
import time
from pathlib import Path
from typing import Any

from . import __version__
from .discovery import discover
from .dvd import probe_dvd
from .model import PROFILES, MediaInfo, Plan
from .planner import analyze, analyze_fast
from .progress import ProgressReporter
from .probe import probe_file
from .queueing import (
    control_session,
    create_session,
    new_session_path,
    run_session,
)
from .review import review_in_browser
from .runner import (
    archive_and_replace_file,
    archive_dvd,
    delete_verified_dvd_source,
    delete_verified_file_source,
    encode,
    output_path,
)
from .stitch import StitchSettings, stitch
from .space import (
    largest_nodes,
    open_space_report,
    scan_space,
    write_space_json,
    write_space_report,
)
from .util import CommandError, atomic_write_json, duration_text, human_bytes, run


def _add_analysis_options(parser: argparse.ArgumentParser) -> None:
    parser.add_argument(
        "--profile", choices=PROFILES, default="balanced",
        help="quality/savings tradeoff (default: balanced)",
    )
    parser.add_argument(
        "--min-savings", type=float,
        help="minimum percentage saved; profile default if omitted",
    )
    parser.add_argument(
        "--min-reclaim-mb", type=float, default=100,
        help="minimum absolute estimated reclaim per item (default: 100)",
    )
    parser.add_argument(
        "--sample-seconds", type=float, default=10,
        help="seconds per sample (default: 10)",
    )
    parser.add_argument(
        "--samples", type=int, choices=(1, 2, 3), default=3,
        help="samples spread across each item (default: 3)",
    )
    parser.add_argument(
        "--encoder", choices=("x265", "videotoolbox"), default="x265",
        help="x265 saves more space; VideoToolbox is much faster",
    )
    parser.add_argument(
        "--preset", default="medium",
        choices=("ultrafast", "superfast", "veryfast", "faster", "fast", "medium", "slow"),
        help="x265 speed/efficiency preset (default: medium)",
    )
    parser.add_argument(
        "--nice", type=int, default=10,
        help="macOS process niceness, 0-20 (default: 10)",
    )
    parser.add_argument(
        "--keep-dvd-extras", action="store_true",
        help="retain all DVD titles instead of main content only",
    )
    parser.add_argument(
        "--dvd-min-title-minutes", type=float, default=10,
        help="minimum DVD main-content title length (default: 10)",
    )
    parser.add_argument(
        "--thorough-analysis", action="store_true",
        help=(
            "trial-encode samples and measure XPSNR; slower and normally "
            "unnecessary (automatically enabled by --review)"
        ),
    )
    parser.add_argument(
        "--scan-workers", type=int, default=6,
        help="parallel metadata probes for queue scans (default: 6)",
    )


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="vidreclaim",
        description="Sample-driven video space reclamation for macOS.",
    )
    parser.add_argument("--version", action="version", version=__version__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    doctor = subparsers.add_parser("doctor", help="check local dependencies")
    doctor.set_defaults(handler=command_doctor)

    stitch_parser = subparsers.add_parser(
        "stitch", help="join mixed video clips into one normalized video",
    )
    stitch_parser.add_argument("output", type=Path)
    stitch_parser.add_argument(
        "inputs", type=Path, nargs="+",
        help="two or more files, or folders expanded in natural filename order",
    )
    stitch_parser.add_argument(
        "--canvas", choices=("first", "largest", "1080p", "4k"), default="first",
        help="output canvas (default: first clip)",
    )
    stitch_parser.add_argument(
        "--profile", choices=PROFILES, default="balanced",
        help="output quality profile (default: balanced)",
    )
    stitch_parser.add_argument(
        "--encoder", choices=("x265", "videotoolbox"), default="x265",
        help="x265 saves more space; VideoToolbox is much faster",
    )
    stitch_parser.add_argument(
        "--preset", default="medium",
        choices=("ultrafast", "superfast", "veryfast", "faster", "fast", "medium", "slow"),
        help="x265 speed/efficiency preset (default: medium)",
    )
    stitch_parser.add_argument(
        "--nice", type=int, default=10,
        help="macOS process niceness, 0-20 (default: 10)",
    )
    stitch_parser.set_defaults(handler=command_stitch)

    space_parser = subparsers.add_parser(
        "space", help="scan disk usage and open an interactive treemap",
    )
    space_parser.add_argument("paths", type=Path, nargs="+")
    space_parser.add_argument(
        "--output", type=Path,
        help="HTML report path (default: a temporary report)",
    )
    space_parser.add_argument(
        "--json-output", type=Path,
        help="write the complete scan tree as structured JSON",
    )
    space_parser.add_argument(
        "--logical-size", action="store_true",
        help="use logical sizes instead of allocated disk blocks",
    )
    space_parser.add_argument(
        "--cross-filesystems", action="store_true",
        help="cross into other mounted filesystems beneath a scan root",
    )
    space_parser.add_argument(
        "--no-open", action="store_true",
        help="write the report without opening a browser",
    )
    space_parser.set_defaults(handler=command_space)

    queue_start = subparsers.add_parser(
        "queue-start",
        help="create a persistent, controllable queue and run it",
    )
    queue_start.add_argument("root", type=Path)
    queue_start.add_argument("--session", type=Path)
    queue_start.add_argument(
        "--include-path",
        type=Path,
        action="append",
        default=[],
        help="limit discovery to this file or directory; may be repeated",
    )
    _add_analysis_options(queue_start)
    queue_start.add_argument("--output-dir", type=Path)
    queue_start.add_argument("--replace", action="store_true")
    queue_start.add_argument("--delete-source-as-you-go", action="store_true")
    queue_start.add_argument("--yes", action="store_true")
    queue_start.add_argument("--review", action="store_true")
    queue_start.add_argument("--deep-verify", action="store_true")
    queue_start.add_argument(
        "--plan-only",
        action="store_true",
        help="prepare the persistent queue but wait for queue-resume to encode",
    )
    queue_start.set_defaults(handler=command_queue_start)

    queue_resume = subparsers.add_parser(
        "queue-resume",
        help="resume a persistent queue after quit, interruption, or reboot",
    )
    queue_resume.add_argument("session", type=Path)
    queue_resume.set_defaults(handler=command_queue_resume)

    queue_control = subparsers.add_parser(
        "queue-control",
        help="pause, resume, cancel, skip, or reorder queue items",
    )
    queue_control.add_argument("session", type=Path)
    queue_control.add_argument(
        "action",
        choices=(
            "pause", "resume", "cancel", "skip", "move-up", "move-down",
            "include", "exclude", "only",
            "clear-completed", "clear-cancelled", "clear-finished", "clear-all",
        ),
    )
    queue_control.add_argument("--item", action="append", default=[])
    queue_control.add_argument(
        "--folder",
        help="apply the action to this relative folder and its descendants",
    )
    queue_control.set_defaults(handler=command_queue_control)

    for name, help_text in (
        ("plan", "scan, sample, and write a no-change encode plan"),
        ("run", "plan and encode qualifying items"),
    ):
        subparser = subparsers.add_parser(name, help=help_text)
        subparser.add_argument("root", type=Path)
        _add_analysis_options(subparser)
        subparser.add_argument(
            "--output-dir", type=Path,
            help="staging output directory (default: ROOT/.vidreclaim/output)",
        )
        subparser.add_argument(
            "--manifest", type=Path,
            help="plan/result JSON path (default: ROOT/.vidreclaim/plan.json)",
        )
        if name == "run":
            source_group = subparser.add_mutually_exclusive_group()
            source_group.add_argument(
                "--replace", action="store_true",
                help="swap verified outputs in place and archive originals",
            )
            source_group.add_argument(
                "--delete-source-as-you-go", action="store_true",
                help="irreversibly delete each source after its output verifies",
            )
            subparser.add_argument(
                "--yes", action="store_true",
                help="confirm irreversible source deletion for automation",
            )
            subparser.add_argument(
                "--review", action="store_true",
                help="open a local before/after screenshot review before encoding",
            )
            subparser.add_argument(
                "--deep-verify", action="store_true",
                help="decode every output frame instead of spot checks",
            )
        subparser.set_defaults(handler=command_plan if name == "plan" else command_run)
    return parser


def command_doctor(_: argparse.Namespace) -> int:
    required = {"ffmpeg": shutil.which("ffmpeg"), "ffprobe": shutil.which("ffprobe")}
    optional = {"HandBrakeCLI": shutil.which("HandBrakeCLI")}
    failed = False
    for name, path in required.items():
        print(f"{name:14} {'OK ' + path if path else 'MISSING'}")
        failed |= path is None
    for name, path in optional.items():
        detail = f"OK {path}" if path else "optional; required for VIDEO_TS"
        print(f"{name:14} {detail}")
    if required["ffmpeg"]:
        encoders = run(["ffmpeg", "-hide_banner", "-encoders"], check=False)
        text = (encoders.stdout or "") + (encoders.stderr or "")
        for encoder in ("libx265", "hevc_videotoolbox"):
            available = encoder in text
            print(f"{encoder:14} {'OK' if available else 'MISSING'}")
            failed |= not available
    return 1 if failed else 0


def command_stitch(args: argparse.Namespace) -> int:
    try:
        stitch(
            args.inputs,
            args.output,
            settings=StitchSettings(
                encoder=args.encoder,
                preset=args.preset,
                profile=PROFILES[args.profile],
                canvas=args.canvas,
                nice=args.nice,
            ),
        )
        return 0
    except (CommandError, OSError) as error:
        print(f"Stitch ERROR: {error}", file=sys.stderr)
        return 1


def command_space(args: argparse.Namespace) -> int:
    import tempfile

    try:
        root, stats = scan_space(
            args.paths,
            allocated=not args.logical_size,
            cross_filesystems=args.cross_filesystems,
        )
        print("\nLargest items:")
        for node in largest_nodes(root, 20):
            print(f"  {human_bytes(node.size):>10}  {node.path}")
        output = (
            args.output
            if args.output
            else Path(tempfile.gettempdir()) / "vidreclaim-space-report.html"
        )
        report = write_space_report(
            root, output, allocated=not args.logical_size,
        )
        if args.json_output:
            write_space_json(
                root, args.json_output, allocated=not args.logical_size,
            )
        print(
            f"\nReport: {report}\n"
            f"Scanned {stats.files:,} files, {stats.directories:,} folders, "
            f"{human_bytes(root.size)}."
        )
        if not args.no_open:
            open_space_report(report)
        return 0
    except (CommandError, OSError) as error:
        print(f"Space scan ERROR: {error}", file=sys.stderr)
        return 1


def _queue_settings(args: argparse.Namespace, root: Path) -> dict[str, Any]:
    state_base = root.parent if root.is_file() else root
    output_root = (
        args.output_dir.expanduser().resolve()
        if args.output_dir else state_base / ".vidreclaim" / "output"
    )
    return {
        "profile": args.profile,
        "min_savings_pct": args.min_savings,
        "min_reclaim_mb": args.min_reclaim_mb,
        "sample_seconds": args.sample_seconds,
        "samples": args.samples,
        "encoder": args.encoder,
        "preset": args.preset,
        "nice": args.nice,
        "keep_dvd_extras": args.keep_dvd_extras,
        "dvd_min_title_minutes": args.dvd_min_title_minutes,
        "thorough_analysis": bool(args.thorough_analysis or args.review),
        "scan_workers": args.scan_workers,
        "visual_review": args.review,
        "deep_verify": args.deep_verify,
        "replace": args.replace,
        "delete_source_as_you_go": args.delete_source_as_you_go,
        "plan_only": args.plan_only,
        "output_dir": str(output_root),
        "include_paths": [
            str(path.expanduser().resolve()) for path in args.include_path
        ],
    }


def command_queue_start(args: argparse.Namespace) -> int:
    root = args.root.expanduser().resolve()
    if args.delete_source_as_you_go and not args.yes:
        print(
            "--delete-source-as-you-go is irreversible and requires --yes.",
            file=sys.stderr,
        )
        return 2
    session = (args.session or new_session_path()).expanduser().resolve()
    try:
        create_session(
            session,
            root=root,
            settings=_queue_settings(args, root),
        )
        print(f"Queue session: {session}", flush=True)
        return run_session(session)
    except (CommandError, OSError) as error:
        print(f"Queue ERROR: {error}", file=sys.stderr)
        return 1


def command_queue_resume(args: argparse.Namespace) -> int:
    try:
        print(f"Queue session: {args.session.expanduser().resolve()}", flush=True)
        return run_session(args.session)
    except (CommandError, OSError) as error:
        print(f"Queue resume ERROR: {error}", file=sys.stderr)
        return 1


def command_queue_control(args: argparse.Namespace) -> int:
    try:
        data = control_session(
            args.session,
            action=args.action,
            item_ids=args.item,
            folder=args.folder,
        )
        print(
            f"Queue control: {args.action}; session is {data['status']}",
            flush=True,
        )
        return 0
    except (CommandError, OSError) as error:
        print(f"Queue control ERROR: {error}", file=sys.stderr)
        return 1


def _paths(args: argparse.Namespace) -> tuple[Path, Path, Path]:
    root = args.root.expanduser().resolve()
    state_base = root.parent if root.is_file() else root
    output_root = (
        args.output_dir.expanduser().resolve()
        if args.output_dir else state_base / ".vidreclaim" / "output"
    )
    manifest = (
        args.manifest.expanduser().resolve()
        if args.manifest else state_base / ".vidreclaim" / "plan.json"
    )
    return root, output_root, manifest


def _collect_media(args: argparse.Namespace, root: Path) -> tuple[list[MediaInfo], list[dict[str, Any]]]:
    media: list[MediaInfo] = []
    dvd_reports: list[dict[str, Any]] = []
    for source in discover(root):
        try:
            if source.kind == "dvd":
                selected, all_titles = probe_dvd(
                    source,
                    keep_extras=args.keep_dvd_extras,
                    min_title_seconds=args.dvd_min_title_minutes * 60,
                )
                media.extend(selected)
                chosen = {item.source.dvd_title for item in selected}
                dvd_reports.append({
                    "path": str(source.path),
                    "main_content_only": not args.keep_dvd_extras,
                    "selected_titles": sorted(chosen),
                    "excluded_titles": [
                        title.index for title in all_titles if title.index not in chosen
                    ],
                    "titles": [
                        {"index": title.index, "duration": title.duration}
                        for title in all_titles
                    ],
                })
                selected_text = ", ".join(
                    f"{item.source.dvd_title} ({duration_text(item.duration)})"
                    for item in selected
                )
                excluded = [title.index for title in all_titles if title.index not in chosen]
                print(
                    f"DVD {source.path}: main content title(s) {selected_text}; "
                    f"excluded {excluded or 'none'}"
                )
            else:
                media.append(probe_file(source))
        except CommandError as error:
            print(f"ERROR {source.path}: {error}", file=sys.stderr)
    return media, dvd_reports


def _make_plans(
    args: argparse.Namespace,
    root: Path,
    output_root: Path,
    *,
    review_session_dir: Path | None = None,
) -> tuple[list[Plan], list[dict[str, Any]]]:
    profile = PROFILES[args.profile]
    media_items, dvd_reports = _collect_media(args, root)
    plans: list[Plan] = []
    for index, media in enumerate(media_items, 1):
        label = media.source.display_name or media.source.path.name
        print(
            f"[{index}/{len(media_items)}] analyzing {label} "
            f"({duration_text(media.duration)}, {media.codec}, "
            f"{media.width}x{media.height}, {human_bytes(media.size_bytes)})"
        )
        try:
            def report_sample(done: int, total: int, detail: str) -> None:
                print(f"  sample {done}/{total}: {detail}", flush=True)

            common = {
                "profile": profile,
                "min_savings_pct": args.min_savings,
                "min_reclaim_bytes": round(args.min_reclaim_mb * 1024 * 1024),
                "encoder": args.encoder,
                "preset": args.preset,
            }
            if args.thorough_analysis or review_session_dir is not None:
                plan = analyze(
                    media,
                    **common,
                    sample_seconds=args.sample_seconds,
                    sample_count=args.samples,
                    nice=args.nice,
                    work_dir=(
                        review_session_dir / "clips" / str(index - 1)
                        if review_session_dir is not None else None
                    ),
                    sample_progress=report_sample,
                )
            else:
                plan = analyze_fast(media, **common)
        except (CommandError, OSError) as error:
            plan = Plan(media, "error", str(error))
        if plan.status == "encode":
            plan.output = output_path(root, plan, output_root)
            candidate = plan.candidate
            assert candidate is not None
            score = f", XPSNR {candidate.xpsnr:.1f}" if candidate.xpsnr else ""
            quality_label = (
                f"CRF {candidate.crf}" if args.encoder == "x265"
                else f"VideoToolbox {args.profile} quality"
            )
            print(
                f"  ENCODE -> {candidate.resolution}, {quality_label}, "
                f"~{human_bytes(candidate.projected_bytes)}, "
                f"{candidate.savings_pct:.1f}% saved, "
                f"~{duration_text(candidate.projected_encode_seconds)} encode time"
                f"{score}"
            )
        else:
            print(f"  {plan.status.upper()}: {plan.reason}")
        plans.append(plan)
    return plans, dvd_reports


def _manifest_data(
    args: argparse.Namespace,
    root: Path,
    plans: list[Plan],
    dvd_reports: list[dict[str, Any]],
    results: list[dict[str, Any]] | None = None,
) -> dict[str, Any]:
    return {
        "schema": 1,
        "created_at_unix": time.time(),
        "root": str(root),
        "settings": {
            "profile": args.profile,
            "min_savings_pct": args.min_savings,
            "min_reclaim_mb": args.min_reclaim_mb,
            "sample_seconds": args.sample_seconds,
            "samples": args.samples,
            "encoder": args.encoder,
            "preset": args.preset,
            "nice": args.nice,
            "keep_dvd_extras": args.keep_dvd_extras,
            "dvd_min_title_minutes": args.dvd_min_title_minutes,
        },
        "dvd_selection": dvd_reports,
        "plans": [plan.to_dict() for plan in plans],
        "results": results or [],
    }


def command_plan(args: argparse.Namespace) -> int:
    root, output_root, manifest = _paths(args)
    if not root.exists():
        print(f"Root does not exist: {root}", file=sys.stderr)
        return 2
    plans, dvd_reports = _make_plans(args, root, output_root)
    atomic_write_json(manifest, _manifest_data(args, root, plans, dvd_reports))
    scheduled = [plan for plan in plans if plan.status == "encode"]
    projected = sum(
        plan.media.size_bytes - plan.candidate.projected_bytes
        for plan in scheduled if plan.candidate
    )
    projected_seconds = sum(
        plan.candidate.projected_encode_seconds
        for plan in scheduled if plan.candidate
    )
    print(
        f"\nPlan: {len(scheduled)} encode, "
        f"{len(plans) - len(scheduled)} skip/error, "
        f"~{human_bytes(projected)} reclaim, "
        f"~{duration_text(projected_seconds)} total encode time"
    )
    print(f"Manifest: {manifest}")
    return 1 if any(plan.status == "error" for plan in plans) else 0


def command_run(args: argparse.Namespace) -> int:
    root, output_root, manifest = _paths(args)
    if not root.exists():
        print(f"Root does not exist: {root}", file=sys.stderr)
        return 2
    if args.delete_source_as_you_go and not args.yes:
        print(
            "--delete-source-as-you-go is irreversible and requires --yes. "
            "Use --replace instead to keep a recoverable archive.",
            file=sys.stderr,
        )
        return 2
    state_base = root.parent if root.is_file() else root
    review_session = (
        state_base / ".vidreclaim" / f"review-{int(time.time())}"
        if args.review else None
    )
    plans, dvd_reports = _make_plans(
        args, root, output_root, review_session_dir=review_session,
    )
    if args.review and review_session is not None:
        print("\nPreparing side-by-side review screenshots…")
        try:
            approved = review_in_browser(
                plans, session_dir=review_session,
                decisions_path=state_base / ".vidreclaim" / "review-decisions.json",
                sample_seconds=args.sample_seconds,
            )
        except (CommandError, OSError) as error:
            print(f"Review ERROR: {error}", file=sys.stderr)
            return 1
        for plan_index, plan in enumerate(plans):
            if plan.status == "encode" and plan_index not in approved:
                plan.status = "skip"
                plan.reason = "skipped in visual review"
        print(
            f"Visual review approved "
            f"{sum(plan.status == 'encode' for plan in plans)} job(s)."
        )
    profile = PROFILES[args.profile]
    result_records: list[dict[str, Any]] = []
    successful_dvds: dict[Path, list[Path]] = {}
    dvd_expected: dict[Path, int] = {}
    for plan in plans:
        if plan.status == "encode" and plan.media.source.kind == "dvd":
            dvd_expected[plan.media.source.path] = dvd_expected.get(plan.media.source.path, 0) + 1

    scheduled = [item for item in plans if item.status == "encode"]
    reporter = ProgressReporter(
        [
            (plan.media.source.display_name or plan.media.source.path.name, plan.media.duration)
            for plan in scheduled
        ],
        progress_path=state_base / ".vidreclaim" / "progress.json",
        initial_eta_seconds=sum(
            plan.candidate.projected_encode_seconds
            for plan in scheduled if plan.candidate
        ),
    )
    for index, plan in enumerate(scheduled, 1):
        label = plan.media.source.display_name or plan.media.source.path.name
        print(f"\nEncoding {index}: {label}")
        reporter.start_job(index - 1, label, plan.media.duration)
        try:
            if args.delete_source_as_you_go and plan.candidate is not None:
                output_root.mkdir(parents=True, exist_ok=True)
                free = shutil.disk_usage(output_root).free
                required = round(plan.candidate.projected_bytes * 1.15)
                if free < required:
                    raise CommandError(
                        f"only {human_bytes(free)} free; this output needs about "
                        f"{human_bytes(required)} including safety margin"
                    )

            def update_progress(fraction: float, speed: float | None) -> None:
                reporter.update(fraction, speed=speed)
                if fraction >= 1:
                    reporter.set_phase("verifying")

            result = encode(
                root, plan, output_root=output_root, encoder=args.encoder,
                preset=args.preset, profile=profile, nice=args.nice,
                deep_verify=args.deep_verify, min_savings_pct=args.min_savings,
                progress=update_progress,
            )
            record: dict[str, Any] = {
                "source": plan.media.source.key,
                "status": "complete",
                "output": str(result.output),
                "output_bytes": result.output_bytes,
                "actual_savings_pct": result.actual_savings_pct,
            }
            print(
                f"  verified {result.output} "
                f"({result.actual_savings_pct:.1f}% smaller)"
            )
            if args.replace and plan.media.source.kind == "file":
                reporter.set_phase("archiving source")
                archived, final = archive_and_replace_file(
                    root, result,
                    archive_root=state_base / ".reclaim-originals",
                )
                record.update({"archived": str(archived), "final": str(final)})
                print(f"  replaced; original archived at {archived}")
            elif args.delete_source_as_you_go and plan.media.source.kind == "file":
                reporter.set_phase("deleting source")
                deleted = delete_verified_file_source(result)
                record["deleted_source"] = str(deleted)
                print(f"  deleted verified source: {deleted}")
            elif plan.media.source.kind == "dvd":
                successful_dvds.setdefault(plan.media.source.path, []).append(result.output)
            result_records.append(record)
            reporter.finish_job()
        except (CommandError, OSError) as error:
            print(f"  ERROR: {error}", file=sys.stderr)
            result_records.append({
                "source": plan.media.source.key,
                "status": "error",
                "error": str(error),
            })
            reporter.fail_job()
        atomic_write_json(
            manifest, _manifest_data(args, root, plans, dvd_reports, result_records),
        )

    source_handling_errors = 0
    if args.replace or args.delete_source_as_you_go:
        for video_ts, outputs in successful_dvds.items():
            if len(outputs) != dvd_expected.get(video_ts, 0):
                print(f"DVD not archived because not all titles succeeded: {video_ts}")
                continue
            try:
                if args.delete_source_as_you_go:
                    deleted = delete_verified_dvd_source(video_ts)
                    for record in result_records:
                        if str(record.get("source", "")).startswith(
                            str(video_ts.resolve()) + "#title="
                        ):
                            record["deleted_dvd_source"] = str(deleted)
                    print(
                        f"Deleted DVD source {deleted}; "
                        f"{len(outputs)} verified main-content output(s) retained"
                    )
                else:
                    archived = archive_dvd(
                        root, video_ts,
                        archive_root=state_base / ".reclaim-originals",
                    )
                    for record in result_records:
                        if str(record.get("source", "")).startswith(
                            str(video_ts.resolve()) + "#title="
                        ):
                            record["archived_dvd_source"] = str(archived)
                    print(
                        f"DVD source archived at {archived}; "
                        f"{len(outputs)} main-content output(s) retained"
                    )
            except CommandError as error:
                print(f"DVD archive ERROR: {error}", file=sys.stderr)
                source_handling_errors += 1

    atomic_write_json(
        manifest, _manifest_data(args, root, plans, dvd_reports, result_records),
    )

    completed = sum(record["status"] == "complete" for record in result_records)
    errors = (
        sum(record["status"] == "error" for record in result_records)
        + source_handling_errors
    )
    print(f"\nFinished: {completed} complete, {errors} errors. Manifest: {manifest}")
    if args.replace:
        print(
            "Originals remain recoverable under .reclaim-originals; "
            "review outputs before deleting that archive."
        )
    elif args.delete_source_as_you_go:
        print("Source deletion mode was enabled; successfully deleted sources are not recoverable.")
    return 1 if errors else 0


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    if not 0 <= getattr(args, "nice", 10) <= 20:
        parser.error("--nice must be between 0 and 20")
    try:
        return int(args.handler(args))
    except KeyboardInterrupt:
        print("\nInterrupted; originals were not touched.", file=sys.stderr)
        return 130


if __name__ == "__main__":
    raise SystemExit(main())
