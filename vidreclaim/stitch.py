from __future__ import annotations

import re
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Literal

from .discovery import discover
from .model import PROFILES, MediaInfo, Profile, Source
from .planner import base_crf
from .probe import probe_file, probe_output
from .progress import ProgressReporter
from .runner import _stream_command
from .util import CommandError, human_bytes


Canvas = Literal["first", "largest", "1080p", "4k"]


@dataclass(frozen=True)
class StitchSettings:
    encoder: Literal["x265", "videotoolbox"] = "x265"
    preset: str = "medium"
    profile: Profile = PROFILES["balanced"]
    canvas: Canvas = "first"
    nice: int = 10


def natural_key(path: Path) -> list[object]:
    return [
        int(part) if part.isdigit() else part.casefold()
        for part in re.split(r"(\d+)", path.name)
    ]


def expand_inputs(inputs: list[Path], output: Path) -> list[Path]:
    expanded: list[Path] = []
    resolved_output = output.expanduser().resolve()
    for item in inputs:
        resolved = item.expanduser().resolve()
        if resolved.is_file():
            expanded.append(resolved)
            continue
        if not resolved.is_dir():
            raise CommandError(f"Stitch input does not exist: {item}")
        found = sorted(
            (
                source.path for source in discover(resolved)
                if source.kind == "file" and source.path.resolve() != resolved_output
            ),
            key=natural_key,
        )
        expanded.extend(found)
    # Avoid accidentally repeating a file when a directory and the file itself
    # are both passed while preserving the user's first-seen ordering.
    unique: list[Path] = []
    seen: set[Path] = set()
    for path in expanded:
        if path not in seen:
            seen.add(path)
            unique.append(path)
    if len(unique) < 2:
        raise CommandError("Stitching needs at least two video files")
    return unique


def canvas_dimensions(media: list[MediaInfo], canvas: Canvas) -> tuple[int, int]:
    if canvas == "1080p":
        return 1920, 1080
    if canvas == "4k":
        return 3840, 2160
    chosen = (
        media[0]
        if canvas == "first"
        else max(media, key=lambda item: item.width * item.height)
    )
    return max(2, chosen.width // 2 * 2), max(2, chosen.height // 2 * 2)


def _escape_ffmetadata(value: str) -> str:
    return (
        value.replace("\\", "\\\\")
        .replace("=", "\\=")
        .replace(";", "\\;")
        .replace("#", "\\#")
        .replace("\n", " ")
    )


def _chapter_metadata(media: list[MediaInfo]) -> str:
    lines = [";FFMETADATA1", "title=VidReclaim stitched video"]
    cursor_ms = 0
    for index, item in enumerate(media, 1):
        end_ms = cursor_ms + max(1, round(item.duration * 1000))
        lines.extend([
            "[CHAPTER]",
            "TIMEBASE=1/1000",
            f"START={cursor_ms}",
            f"END={end_ms}",
            f"title={_escape_ffmetadata(item.source.path.stem or f'Clip {index}')}",
        ])
        cursor_ms = end_ms
    return "\n".join(lines) + "\n"


def _filter_graph(
    media: list[MediaInfo],
    width: int,
    height: int,
    fps: float,
    pixel_format: str,
) -> str:
    chains: list[str] = []
    concat_inputs: list[str] = []
    for index, item in enumerate(media):
        video_filters: list[str] = []
        if item.field_order not in {"progressive", "unknown", ""}:
            video_filters.append("bwdif=mode=send_frame:parity=auto:deint=interlaced")
        video_filters.extend([
            f"scale={width}:{height}:force_original_aspect_ratio=decrease:flags=lanczos",
            f"pad={width}:{height}:(ow-iw)/2:(oh-ih)/2:color=black",
            "setsar=1",
            f"fps={fps:.6f}",
            f"format={pixel_format}",
            f"trim=duration={item.duration:.6f}",
            "setpts=PTS-STARTPTS",
        ])
        chains.append(
            f"[{index}:{item.video_stream_index}]"
            + ",".join(video_filters)
            + f"[v{index}]"
        )
        if item.audio_streams:
            chains.append(
                f"[{index}:a:0]"
                "aresample=48000,"
                "aformat=sample_fmts=fltp:sample_rates=48000:channel_layouts=stereo,"
                f"apad,atrim=duration={item.duration:.6f},asetpts=PTS-STARTPTS"
                f"[a{index}]"
            )
        else:
            chains.append(
                f"anullsrc=r=48000:cl=stereo:d={item.duration:.6f},"
                f"asetpts=PTS-STARTPTS[a{index}]"
            )
        concat_inputs.append(f"[v{index}][a{index}]")
    chains.append(
        "".join(concat_inputs)
        + f"concat=n={len(media)}:v=1:a=1[outv][outa]"
    )
    return ";".join(chains)


def _video_encoder_args(
    settings: StitchSettings,
    *,
    height: int,
    ten_bit: bool,
) -> list[str]:
    pixel_format = "yuv420p10le" if ten_bit else "yuv420p"
    if settings.encoder == "videotoolbox":
        quality = {
            "conservative": 75,
            "balanced": 65,
            "compact": 55,
        }[settings.profile.name]
        return [
            "-c:v", "hevc_videotoolbox",
            "-profile:v", "main10" if ten_bit else "main",
            "-pix_fmt", pixel_format,
            "-q:v", str(quality),
            "-prio_speed", "0", "-power_efficient", "1", "-spatial_aq", "1",
            "-tag:v", "hvc1",
        ]
    quality = base_crf(height) + settings.profile.crf_offset
    return [
        "-c:v", "libx265", "-preset", settings.preset, "-crf", str(quality),
        "-pix_fmt", pixel_format, "-tag:v", "hvc1",
        "-x265-params", "log-level=error",
    ]


def stitch(
    inputs: list[Path],
    output: Path,
    *,
    settings: StitchSettings,
) -> Path:
    output = output.expanduser().resolve()
    if not output.suffix:
        output = output.with_suffix(".mkv")
    if output.suffix.lower() not in {".mkv", ".mp4", ".m4v", ".mov"}:
        raise CommandError("Stitch output must be MKV, MP4, M4V, or MOV")
    if output.exists():
        raise CommandError(f"Refusing to overwrite existing output: {output}")
    paths = expand_inputs(inputs, output)
    media = [probe_file(Source(path)) for path in paths]
    hdr_values = {item.hdr for item in media}
    if len(hdr_values) > 1:
        raise CommandError(
            "Mixing HDR and SDR clips needs an explicit tone-mapping decision; "
            "convert them to a common color space first"
        )
    width, height = canvas_dimensions(media, settings.canvas)
    fps = min(60.0, max(1.0, media[0].fps))
    ten_bit = all(item.bit_depth > 8 or item.hdr for item in media)
    pixel_format = "yuv420p10le" if ten_bit else "yuv420p"
    total_duration = sum(item.duration for item in media)
    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = output.with_name(f".{output.stem}.part{output.suffix}")
    if temporary.exists():
        raise CommandError(f"Stale partial stitch exists: {temporary}")

    with tempfile.TemporaryDirectory(prefix="vidreclaim-stitch-") as temp:
        metadata = Path(temp) / "chapters.ffmetadata"
        metadata.write_text(_chapter_metadata(media), encoding="utf-8")
        metadata_input = len(media)
        args = ["ffmpeg", "-hide_banner", "-loglevel", "warning", "-nostats", "-y"]
        for path in paths:
            args.extend(["-i", str(path)])
        args.extend([
            "-f", "ffmetadata", "-i", str(metadata),
            "-filter_complex", _filter_graph(media, width, height, fps, pixel_format),
            "-map", "[outv]", "-map", "[outa]",
            *_video_encoder_args(settings, height=height, ten_bit=ten_bit),
            "-c:a", "aac", "-b:a", "192k",
            "-map_metadata", str(metadata_input),
            "-map_chapters", str(metadata_input),
        ])
        if output.suffix.lower() in {".mp4", ".m4v", ".mov"}:
            args.extend(["-movflags", "+faststart"])
        args.extend(["-progress", "pipe:1", str(temporary)])

        reporter = ProgressReporter(
            [(output.name, total_duration)],
            progress_path=output.with_suffix(output.suffix + ".progress.json"),
        )
        reporter.start_job(0, output.name, total_duration)
        latest_speed: float | None = None

        def parse_line(line: str) -> None:
            nonlocal latest_speed
            if line.startswith("speed="):
                match = re.search(r"([0-9.]+)x", line)
                latest_speed = float(match.group(1)) if match else None
            elif line.startswith("out_time_us="):
                try:
                    seconds = int(line.split("=", 1)[1]) / 1_000_000
                except ValueError:
                    return
                reporter.update(seconds / max(total_duration, 0.001), speed=latest_speed)

        try:
            _stream_command(args, nice=settings.nice, on_line=parse_line)
            reporter.update(1.0)
            reporter.set_phase("verifying")
            encoded = probe_output(temporary)
            tolerance = max(3.0, total_duration * 0.02)
            if abs(encoded.duration - total_duration) > tolerance:
                raise CommandError(
                    f"stitched duration mismatch: expected {total_duration:.1f}s, "
                    f"got {encoded.duration:.1f}s"
                )
            if encoded.audio_streams < 1:
                raise CommandError("stitched output is missing its audio track")
            temporary.replace(output)
            reporter.finish_job()
        except BaseException:
            reporter.fail_job()
            raise
    print(
        f"Stitched {len(paths)} clips into {output} "
        f"({width}x{height}, {fps:.3f} fps, {human_bytes(output.stat().st_size)})"
    )
    return output
