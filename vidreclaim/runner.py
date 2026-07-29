from __future__ import annotations

import json
import os
import re
import selectors
import signal
import shutil
import subprocess
from collections import deque
from dataclasses import dataclass
from pathlib import Path
from typing import Callable

from .dvd import handbrake_input_args
from .model import Plan, Profile
from .planner import Encoder, ffmpeg_video_args
from .probe import probe_output
from .util import CommandError, run


ProgressCallback = Callable[[float, float | None], None]
ControlCallback = Callable[[], str]


class EncodeControl(CommandError):
    def __init__(self, action: str) -> None:
        self.action = action
        super().__init__(f"encode {action} by user")


def _stream_command(
    args: list[str],
    *,
    nice: int,
    on_line: Callable[[str], None],
    control: ControlCallback | None = None,
) -> None:
    command = list(args)
    if nice and os.uname().sysname == "Darwin":
        command = ["/usr/bin/nice", "-n", str(nice), *command]
    tail: deque[str] = deque(maxlen=120)
    process = subprocess.Popen(
        command, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        bufsize=1, start_new_session=True,
    )
    assert process.stdout is not None
    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ)
    stopped = False

    def end_process(sig: signal.Signals) -> None:
        try:
            if stopped:
                os.killpg(process.pid, signal.SIGCONT)
            os.killpg(process.pid, sig)
        except ProcessLookupError:
            return

    try:
        while process.poll() is None:
            action = control() if control else "run"
            if action in {"cancel", "skip"}:
                end_process(signal.SIGTERM)
                try:
                    process.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    end_process(signal.SIGKILL)
                    process.wait()
                raise EncodeControl(action)
            if action == "pause" and not stopped:
                os.killpg(process.pid, signal.SIGSTOP)
                stopped = True
            elif action != "pause" and stopped:
                os.killpg(process.pid, signal.SIGCONT)
                stopped = False

            for key, _ in selector.select(timeout=0.35):
                line = key.fileobj.readline()
                if line:
                    tail.append(line.rstrip())
                    on_line(line)
        return_code = process.wait()
    except BaseException:
        # The GUI interrupts the Python coordinator. Propagate that interrupt
        # to the isolated encoder process group so ffmpeg/HandBrake cannot be
        # orphaned in the background.
        try:
            end_process(signal.SIGINT)
            process.wait(timeout=3)
        except (ProcessLookupError, subprocess.TimeoutExpired):
            try:
                end_process(signal.SIGTERM)
            except ProcessLookupError:
                pass
            try:
                process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                process.wait()
        raise
    finally:
        selector.close()
        process.stdout.close()
    if return_code:
        raise CommandError(
            f"{command[0]} failed ({return_code}):\n" + "\n".join(tail)
        )


@dataclass
class EncodeResult:
    plan: Plan
    output: Path
    output_bytes: int
    actual_savings_pct: float
    verified: bool


def output_path(root: Path, plan: Plan, output_root: Path) -> Path:
    source = plan.media.source
    resolved_root = root.resolve()
    if source.kind == "dvd":
        disc = source.path.parent
        try:
            relative_parent = disc.relative_to(resolved_root)
        except ValueError:
            relative_parent = Path(disc.name)
        title = source.dvd_title or 1
        return output_root / relative_parent / f"{disc.name}.title-{title:02d}.mkv"
    if resolved_root.is_file():
        relative = Path(source.path.name)
    else:
        try:
            relative = source.path.relative_to(resolved_root)
        except ValueError:
            relative = Path(source.path.name)
    return (output_root / relative).with_suffix(".mkv")


def _encode_file(
    plan: Plan,
    temporary: Path,
    *,
    encoder: Encoder,
    preset: str,
    profile: Profile,
    nice: int,
    progress: ProgressCallback | None,
    control: ControlCallback | None,
) -> None:
    assert plan.candidate is not None
    media = plan.media
    args = [
        "ffmpeg", "-hide_banner", "-loglevel", "warning", "-nostats", "-y",
        "-i", str(media.source.path),
        "-map", f"0:{media.video_stream_index}",
        "-map", "0:a?", "-map", "0:s?", "-map", "0:t?",
        *ffmpeg_video_args(
            media, plan.candidate, encoder=encoder, preset=preset, profile=profile,
        ),
        "-c:a", "copy", "-c:s", "copy", "-c:t", "copy",
        "-map_metadata", "0", "-map_chapters", "0",
        "-max_interleave_delta", "0",
        "-progress", "pipe:1", str(temporary),
    ]
    latest_speed: float | None = None

    def parse_line(line: str) -> None:
        nonlocal latest_speed
        if line.startswith("speed="):
            match = re.search(r"([0-9.]+)x", line)
            latest_speed = float(match.group(1)) if match else None
        elif line.startswith("out_time_us=") and progress:
            try:
                seconds = int(line.split("=", 1)[1]) / 1_000_000
            except ValueError:
                return
            progress(seconds / max(plan.media.duration, 0.001), latest_speed)

    _stream_command(args, nice=nice, on_line=parse_line, control=control)


def _encode_dvd(
    plan: Plan,
    temporary: Path,
    *,
    preset: str,
    profile: Profile,
    nice: int,
    progress: ProgressCallback | None,
    control: ControlCallback | None,
) -> None:
    media = plan.media
    encoder = "x265_10bit" if media.bit_depth > 8 or media.hdr else "x265"
    quality = plan.candidate.crf if plan.candidate else 20
    args = [
        "HandBrakeCLI", "--json", *handbrake_input_args(media.source),
        "--output", str(temporary), "--format", "av_mkv",
        "--encoder", encoder, "--encoder-preset", preset,
        "--quality", str(quality), "--markers",
        "--all-audio", "--aencoder", "copy",
        "--audio-copy-mask", "aac,ac3,eac3,truehd,dts,dtshd,mp2,mp3,flac,opus",
        "--audio-fallback", "av_aac",
        "--all-subtitles", "--subtitle-burned", "none",
        "--comb-detect", "--decomb",
    ]
    collecting = False
    block: list[str] = []
    depth = 0

    def parse_line(line: str) -> None:
        nonlocal collecting, block, depth
        if line.startswith("Progress: {"):
            collecting = True
            block = [line.split("Progress:", 1)[1].lstrip()]
            depth = block[0].count("{") - block[0].count("}")
            return
        if not collecting:
            return
        block.append(line)
        depth += line.count("{") - line.count("}")
        if depth > 0:
            return
        collecting = False
        try:
            data = json.loads("".join(block))
            working = data.get("Working") or {}
            fraction = float(working.get("Progress", 0))
            rate = float(working.get("RateAvg", 0))
            speed = rate / media.fps if rate > 0 and media.fps > 0 else None
            if progress and data.get("State") == "WORKING":
                progress(fraction, speed)
        except (json.JSONDecodeError, TypeError, ValueError):
            return

    _stream_command(args, nice=nice, on_line=parse_line, control=control)


def verify_output(plan: Plan, output: Path, *, deep: bool = False) -> None:
    source = plan.media
    encoded = probe_output(output)
    tolerance = max(5.0, source.duration * 0.02)
    if abs(encoded.duration - source.duration) > tolerance:
        raise CommandError(
            f"duration mismatch: source {source.duration:.1f}s, "
            f"output {encoded.duration:.1f}s"
        )
    if encoded.width <= 0 or encoded.height <= 0:
        raise CommandError("encoded file has no usable video stream")
    if source.audio_streams and encoded.audio_streams < source.audio_streams:
        raise CommandError(
            f"audio stream loss: source {source.audio_streams}, "
            f"output {encoded.audio_streams}"
        )
    if source.source.kind == "file" and encoded.subtitle_streams < source.subtitle_streams:
        raise CommandError(
            f"subtitle stream loss: source {source.subtitle_streams}, "
            f"output {encoded.subtitle_streams}"
        )

    if deep:
        commands = [[
            "ffmpeg", "-hide_banner", "-loglevel", "error", "-xerror",
            "-i", str(output), "-map", "0:v:0", "-f", "null", "-",
        ]]
    else:
        offsets = [0.0, max(0.0, encoded.duration / 2 - 2), max(0.0, encoded.duration - 5)]
        commands = [[
            "ffmpeg", "-hide_banner", "-loglevel", "error", "-xerror",
            "-ss", f"{offset:.3f}", "-i", str(output), "-t", "5",
            "-map", "0:v:0", "-f", "null", "-",
        ] for offset in offsets]
    for command in commands:
        run(command)


def encode(
    root: Path,
    plan: Plan,
    *,
    output_root: Path,
    encoder: Encoder,
    preset: str,
    profile: Profile,
    nice: int = 10,
    deep_verify: bool = False,
    min_savings_pct: float | None = None,
    progress: ProgressCallback | None = None,
    control: ControlCallback | None = None,
) -> EncodeResult:
    if plan.status != "encode" or plan.candidate is None:
        raise ValueError("Only an encode plan can be run")
    destination = output_path(root, plan, output_root)
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = destination.with_name(f".{destination.stem}.part.mkv")
    if destination.exists():
        raise CommandError(f"Refusing to overwrite existing output: {destination}")
    if temporary.exists():
        raise CommandError(f"Stale partial output exists: {temporary}")

    try:
        if plan.media.source.kind == "dvd":
            _encode_dvd(
                plan, temporary, preset=preset, profile=profile, nice=nice,
                progress=progress, control=control,
            )
        else:
            _encode_file(
                plan, temporary, encoder=encoder, preset=preset,
                profile=profile, nice=nice, progress=progress,
                control=control,
            )
        if progress:
            progress(1.0, None)
        verify_output(plan, temporary, deep=deep_verify)
        output_bytes = temporary.stat().st_size
        savings = (plan.media.size_bytes - output_bytes) / plan.media.size_bytes * 100
        required = profile.min_savings_pct if min_savings_pct is None else min_savings_pct
        if savings < required:
            raise CommandError(
                f"actual savings {savings:.1f}% did not meet {required:.1f}% threshold"
            )
        temporary.replace(destination)
    except EncodeControl:
        temporary.unlink(missing_ok=True)
        raise
    except BaseException:
        # Keep the partial file for diagnosis; it is never mistaken for a
        # completed result and a later run will call attention to it.
        raise
    plan.output = destination
    return EncodeResult(plan, destination, output_bytes, savings, True)


def archive_and_replace_file(
    root: Path,
    result: EncodeResult,
    *,
    archive_root: Path,
) -> tuple[Path, Path]:
    """Atomically swap a regular file and retain the original on-volume."""
    source = result.plan.media.source.path
    if result.plan.media.source.kind != "file":
        raise CommandError("DVD replacement is handled per disc, not per title")
    resolved_root = root.resolve()
    try:
        relative = source.relative_to(resolved_root)
    except ValueError:
        relative = Path(source.name)
    archived = archive_root / relative
    final = source.with_suffix(".mkv")
    if final != source and final.exists():
        raise CommandError(f"Replacement path already exists: {final}")
    archived.parent.mkdir(parents=True, exist_ok=True)
    if archived.exists():
        raise CommandError(f"Archive path already exists: {archived}")
    source.replace(archived)
    try:
        result.output.replace(final)
    except BaseException:
        archived.replace(source)
        raise
    return archived, final


def archive_dvd(
    root: Path,
    video_ts: Path,
    *,
    archive_root: Path,
) -> Path:
    try:
        relative = video_ts.relative_to(root.resolve())
    except ValueError:
        relative = Path(video_ts.parent.name) / video_ts.name
    archived = archive_root / relative
    archived.parent.mkdir(parents=True, exist_ok=True)
    if archived.exists():
        raise CommandError(f"Archive path already exists: {archived}")
    video_ts.replace(archived)
    return archived


def delete_verified_file_source(result: EncodeResult) -> Path:
    source = result.plan.media.source.path
    if result.plan.media.source.kind != "file" or not source.is_file():
        raise CommandError(f"Refusing to delete unexpected source target: {source}")
    source.unlink()
    return source


def delete_verified_dvd_source(video_ts: Path) -> Path:
    resolved = video_ts.resolve()
    if (
        not resolved.is_dir()
        or resolved.name.lower() != "video_ts"
        or resolved.parent == resolved
    ):
        raise CommandError(f"Refusing to delete unexpected DVD target: {resolved}")
    shutil.rmtree(resolved)
    return resolved
