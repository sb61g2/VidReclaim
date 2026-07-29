from __future__ import annotations

import json
import math
import re
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Literal

from .discovery import discover
from .model import PROFILES, MediaInfo, Profile, Source
from .planner import base_crf, estimated_encode_fps
from .probe import probe_file, probe_output
from .progress import ProgressReporter
from .runner import _stream_command
from .util import CommandError, duration_text, human_bytes, run


Canvas = Literal["first", "largest", "1080p", "4k"]
MixedDynamicRange = Literal["split", "sdr"]


@dataclass(frozen=True)
class StitchSettings:
    encoder: Literal["x265", "videotoolbox"] = "x265"
    preset: str = "medium"
    profile: Profile = PROFILES["balanced"]
    canvas: Canvas = "first"
    nice: int = 10
    mixed_dynamic_range: MixedDynamicRange = "split"


@dataclass(frozen=True)
class StitchEstimate:
    clip_count: int
    source_bytes: int
    projected_output_bytes: int
    total_duration_seconds: float
    projected_encode_seconds: float
    width: int
    height: int
    fps: float

    def to_dict(self) -> dict[str, int | float]:
        return {
            "clip_count": self.clip_count,
            "source_bytes": self.source_bytes,
            "projected_output_bytes": self.projected_output_bytes,
            "total_duration_seconds": self.total_duration_seconds,
            "projected_encode_seconds": self.projected_encode_seconds,
            "width": self.width,
            "height": self.height,
            "fps": self.fps,
        }


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


def estimate_stitch(
    media: list[MediaInfo],
    settings: StitchSettings,
) -> StitchEstimate:
    width, height = canvas_dimensions(media, settings.canvas)
    fps = min(60.0, max(1.0, media[0].fps))
    duration = sum(item.duration for item in media)
    source_bytes = sum(item.size_bytes for item in media)
    base_bpp = {
        "conservative": 0.066,
        "balanced": 0.052,
        "compact": 0.042,
    }[settings.profile.name]
    encoder_size_factor = 1.25 if settings.encoder == "videotoolbox" else {
        "ultrafast": 1.18,
        "superfast": 1.14,
        "veryfast": 1.11,
        "faster": 1.07,
        "fast": 1.03,
        "medium": 1.0,
        "slow": 0.94,
    }.get(settings.preset, 1.0)
    resolution_factor = 1.45 if height <= 576 else (1.15 if height <= 720 else 1.0)
    video_rate = round(
        width * height * max(fps, 23.976)
        * base_bpp * resolution_factor * encoder_size_factor
    )
    projected_output_bytes = math.ceil(
        (video_rate + 192_000) * duration / 8 * 1.02
    )
    encode_fps = estimated_encode_fps(
        width,
        height,
        encoder=settings.encoder,
        preset=settings.preset,
    )
    projected_encode_seconds = duration * fps / max(encode_fps, 1.0)
    return StitchEstimate(
        clip_count=len(media),
        source_bytes=source_bytes,
        projected_output_bytes=projected_output_bytes,
        total_duration_seconds=duration,
        projected_encode_seconds=projected_encode_seconds,
        width=width,
        height=height,
        fps=fps,
    )


def _print_stitch_estimate(estimate: StitchEstimate) -> None:
    print(
        "COMBINE_ESTIMATE " + json.dumps(
            estimate.to_dict(),
            separators=(",", ":"),
            sort_keys=True,
        ),
        flush=True,
    )
    difference = estimate.source_bytes - estimate.projected_output_bytes
    change = (
        f"about {human_bytes(difference)} smaller"
        if difference >= 0
        else f"about {human_bytes(abs(difference))} larger"
    )
    print(
        f"Combine estimate: {estimate.clip_count} clips · "
        f"{duration_text(estimate.total_duration_seconds)} total runtime · "
        f"{human_bytes(estimate.source_bytes)} source → "
        f"{human_bytes(estimate.projected_output_bytes)} output ({change}) · "
        f"{duration_text(estimate.projected_encode_seconds)} encode time",
        flush=True,
    )


def _print_stitch_result(outputs: list[Path]) -> None:
    existing = [path for path in outputs if path.exists()]
    if not existing:
        return
    print(
        "COMBINE_RESULT " + json.dumps(
            {
                "output_bytes": sum(path.stat().st_size for path in existing),
                "output_count": len(existing),
            },
            separators=(",", ":"),
            sort_keys=True,
        ),
        flush=True,
    )


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
    tone_map_hdr: bool = False,
) -> str:
    chains: list[str] = []
    concat_inputs: list[str] = []
    for index, item in enumerate(media):
        video_filters: list[str] = []
        if item.field_order not in {"progressive", "unknown", ""}:
            video_filters.append("bwdif=mode=send_frame:parity=auto:deint=interlaced")
        if tone_map_hdr and item.hdr:
            video_filters.extend([
                "zscale=t=linear:npl=100",
                "format=gbrpf32le",
                "zscale=p=bt709",
                "tonemap=hable:desat=1",
                "zscale=t=bt709:m=bt709:r=tv",
            ])
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


def _supports_hdr_tonemap() -> bool:
    result = run(
        ["ffmpeg", "-hide_banner", "-filters"],
        check=False,
        capture=True,
    )
    filters = (result.stdout or "") + (result.stderr or "")
    return " zscale " in filters and " tonemap " in filters


def _stitch_prepared(
    paths: list[Path],
    media: list[MediaInfo],
    output: Path,
    *,
    settings: StitchSettings,
    tone_map_hdr: bool = False,
) -> Path:
    if output.exists():
        raise CommandError(f"Refusing to overwrite existing output: {output}")
    width, height = canvas_dimensions(media, settings.canvas)
    fps = min(60.0, max(1.0, media[0].fps))
    ten_bit = (
        False if tone_map_hdr
        else all(item.bit_depth > 8 or item.hdr for item in media)
    )
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
            "-filter_complex", _filter_graph(
                media,
                width,
                height,
                fps,
                pixel_format,
                tone_map_hdr=tone_map_hdr,
            ),
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


def stitch(
    inputs: list[Path],
    output: Path,
    *,
    settings: StitchSettings,
) -> list[Path]:
    output = output.expanduser().resolve()
    if not output.suffix:
        output = output.with_suffix(".mkv")
    if output.suffix.lower() not in {".mkv", ".mp4", ".m4v", ".mov"}:
        raise CommandError("Stitch output must be MKV, MP4, M4V, or MOV")
    print("Combine preflight: expanding selected files and folders…", flush=True)
    paths = expand_inputs(inputs, output)
    print(
        f"Combine preflight: found {len(paths)} clips; reading metadata…",
        flush=True,
    )
    media: list[MediaInfo] = []
    update_interval = max(1, len(paths) // 20)
    for index, path in enumerate(paths, 1):
        media.append(probe_file(Source(path)))
        if index == 1 or index == len(paths) or index % update_interval == 0:
            print(
                f"Combine metadata: {index}/{len(paths)} · {path.name}",
                flush=True,
            )
    estimate = estimate_stitch(media, settings)
    _print_stitch_estimate(estimate)
    hdr_values = {item.hdr for item in media}
    if len(hdr_values) == 1:
        outputs = [_stitch_prepared(paths, media, output, settings=settings)]
        _print_stitch_result(outputs)
        return outputs

    if settings.mixed_dynamic_range == "sdr" and _supports_hdr_tonemap():
        print(
            "Mixed HDR and SDR detected; tone-mapping HDR clips to "
            "BT.709 SDR with the Hable operator.",
            flush=True,
        )
        outputs = [
            _stitch_prepared(
                paths,
                media,
                output,
                settings=settings,
                tone_map_hdr=True,
            )
        ]
        _print_stitch_result(outputs)
        return outputs

    if settings.mixed_dynamic_range == "sdr":
        print(
            "This FFmpeg build lacks the zscale filter required for "
            "color-aware HDR-to-SDR conversion; creating separate outputs.",
            flush=True,
        )
    sdr_output = output.with_name(f"{output.stem}-sdr{output.suffix}")
    hdr_output = output.with_name(f"{output.stem}-hdr{output.suffix}")
    groups = [
        (
            "SDR",
            sdr_output,
            [
                (path, item) for path, item in zip(paths, media, strict=True)
                if not item.hdr
            ],
        ),
        (
            "HDR",
            hdr_output,
            [
                (path, item) for path, item in zip(paths, media, strict=True)
                if item.hdr
            ],
        ),
    ]
    print(
        "Mixed HDR and SDR detected; preserving color by creating separate "
        f"outputs: {sdr_output.name} and {hdr_output.name}.",
        flush=True,
    )
    outputs: list[Path] = []
    for label, group_output, group in groups:
        group_paths = [path for path, _ in group]
        group_media = [item for _, item in group]
        print(f"Stitching {label} clips…", flush=True)
        outputs.append(
            _stitch_prepared(
                group_paths,
                group_media,
                group_output,
                settings=settings,
            )
        )
    _print_stitch_result(outputs)
    return outputs
