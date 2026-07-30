from __future__ import annotations

import math
import re
import tempfile
import time
from pathlib import Path
from typing import Callable, Literal

from .dvd import handbrake_input_args
from .model import Candidate, MediaInfo, Plan, Profile
from .util import CommandError, run


Encoder = Literal["x265", "videotoolbox", "nvenc"]


def base_crf(height: int) -> int:
    if height <= 576:
        return 20
    if height <= 720:
        return 21
    if height <= 1080:
        return 22
    if height <= 1440:
        return 23
    return 24


def sample_offsets(duration: float, sample_seconds: float, count: int = 3) -> list[float]:
    if duration <= sample_seconds + 1:
        return [0.0]
    usable = max(0.0, duration - sample_seconds)
    fractions = [0.15, 0.5, 0.85] if count >= 3 else [0.25, 0.75]
    raw = [min(usable, usable * fraction) for fraction in fractions[:count]]
    output: list[float] = []
    for value in raw:
        rounded = round(value, 3)
        if not output or abs(rounded - output[-1]) >= sample_seconds:
            output.append(rounded)
    return output or [0.0]


def _scaled_dimensions(width: int, height: int, max_long_edge: int) -> tuple[int, int]:
    long_edge = max(width, height)
    if long_edge <= max_long_edge:
        return width, height
    scale = max_long_edge / long_edge
    scaled_width = max(2, round(width * scale / 2) * 2)
    scaled_height = max(2, round(height * scale / 2) * 2)
    return scaled_width, scaled_height


def candidate_dimensions(media: MediaInfo) -> list[tuple[int, int]]:
    dimensions = [(media.width, media.height)]
    # Only trial a 1080-class derivative for UHD-ish sources. It must pass a
    # decoded-image comparison after being scaled back up before selection.
    if max(media.width, media.height) >= 3000:
        scaled = _scaled_dimensions(media.width, media.height, 1920)
        if scaled not in dimensions:
            dimensions.append(scaled)
    return dimensions


def estimated_encode_fps(
    width: int,
    height: int,
    *,
    encoder: Encoder,
    preset: str,
) -> float:
    """Conservative M4-oriented estimate, replaced by observed speed at runtime."""
    megapixels = max(0.25, width * height / 1_000_000)
    if encoder in {"videotoolbox", "nvenc"}:
        return 310 / (megapixels ** 0.78)
    preset_factor = {
        "ultrafast": 3.2,
        "superfast": 2.5,
        "veryfast": 1.9,
        "faster": 1.45,
        "fast": 1.2,
        "medium": 1.0,
        "slow": 0.62,
    }.get(preset, 1.0)
    return 150 * preset_factor / (megapixels ** 0.92)


def analyze_fast(
    media: MediaInfo,
    *,
    profile: Profile,
    min_savings_pct: float | None = None,
    min_reclaim_bytes: int = 100 * 1024 * 1024,
    encoder: Encoder = "x265",
    preset: str = "medium",
) -> Plan:
    """Plan from stream metadata without trial encodes.

    The real output is still verified and must clear the actual savings gate.
    This deliberately favors keeping native resolution when UHD metadata
    suggests a sharp or HDR source.
    """
    required_pct = profile.min_savings_pct if min_savings_pct is None else min_savings_pct
    if media.duration < 5:
        return Plan(media, "skip", "shorter than 5 seconds")

    dimensions = candidate_dimensions(media)
    if len(dimensions) > 1:
        modern = media.codec in {"hevc", "h265", "av1", "vp9"}
        crisp_threshold = 0.052 if modern else 0.072
        preserve_native = (
            media.hdr
            or media.bit_depth > 8
            or media.bpp_per_frame >= crisp_threshold
            or media.video_bit_rate >= 14_000_000
        )
        if preserve_native:
            dimensions = dimensions[:1]

    base_bpp = {
        "conservative": 0.066,
        "balanced": 0.052,
        "compact": 0.042,
    }[profile.name]
    encoder_size_factor = 1.25 if encoder == "videotoolbox" else {
        "ultrafast": 1.18,
        "superfast": 1.14,
        "veryfast": 1.11,
        "faster": 1.07,
        "fast": 1.03,
        "medium": 1.0,
        "slow": 0.94,
    }.get(preset, 1.0)
    candidates: list[Candidate] = []
    encode_fps = estimated_encode_fps(
        media.width,
        media.height,
        encoder=encoder,
        preset=preset,
    )
    for width, height in dimensions:
        resolution_factor = 1.45 if height <= 576 else (1.15 if height <= 720 else 1.0)
        target_video_rate = round(
            width * height * max(media.fps, 23.976)
            * base_bpp * resolution_factor * encoder_size_factor
        )
        # Avoid predicting that a constant-quality encode will inflate already
        # efficient material. Such files should simply be skipped.
        target_video_rate = min(target_video_rate, media.video_bit_rate)
        projected_rate = target_video_rate + media.nonvideo_bit_rate
        projected_bytes = math.ceil(projected_rate * media.duration / 8 * 1.02)
        savings_pct = (
            (media.size_bytes - projected_bytes) / media.size_bytes * 100
        )
        reclaim = media.size_bytes - projected_bytes
        accepted = savings_pct >= required_pct and reclaim >= min_reclaim_bytes
        failures: list[str] = []
        if savings_pct < required_pct:
            failures.append(
                f"estimated savings {savings_pct:.1f}% < {required_pct:.1f}%"
            )
        if reclaim < min_reclaim_bytes:
            failures.append("estimated absolute reclaim below threshold")
        candidate = Candidate(
            width=width,
            height=height,
            crf=base_crf(height) + profile.crf_offset,
            projected_bytes=projected_bytes,
            projected_encode_seconds=(
                media.duration * media.fps / max(encode_fps, 1.0)
            ),
            savings_pct=savings_pct,
            accepted=accepted,
            reason="Eligible" if accepted else "; ".join(failures),
        )
        candidates.append(candidate)

    accepted = [candidate for candidate in candidates if candidate.accepted]
    if not accepted:
        return Plan(
            media,
            "skip",
            "Excluded",
            candidates=candidates,
        )
    chosen = min(accepted, key=lambda candidate: candidate.projected_bytes)
    return Plan(
        media,
        "encode",
        f"~{chosen.savings_pct:.1f}% savings",
        candidate=chosen,
        candidates=candidates,
    )


def _video_filter(media: MediaInfo, width: int, height: int) -> str | None:
    filters: list[str] = []
    if media.field_order not in {"progressive", "unknown", ""}:
        filters.append("bwdif=mode=send_frame:parity=auto:deint=interlaced")
    if (width, height) != (media.width, media.height):
        filters.append(f"scale={width}:{height}:flags=lanczos")
    return ",".join(filters) if filters else None


def _encoder_args(
    media: MediaInfo,
    *,
    encoder: Encoder,
    crf: int,
    preset: str,
    profile: Profile,
) -> list[str]:
    ten_bit = media.bit_depth > 8 or media.hdr
    pixel_format = "yuv420p10le" if ten_bit else "yuv420p"
    if encoder == "videotoolbox":
        quality = {
            "conservative": 75,
            "balanced": 65,
            "compact": 55,
        }[profile.name]
        return [
            "-c:v", "hevc_videotoolbox",
            "-profile:v", "main10" if ten_bit else "main",
            "-pix_fmt", pixel_format,
            "-q:v", str(quality),
            "-prio_speed", "0",
            "-power_efficient", "1",
            "-spatial_aq", "1",
            "-tag:v", "hvc1",
        ]
    if encoder == "nvenc":
        return [
            "-c:v", "hevc_nvenc",
            "-preset", "p7",
            "-tune", "hq",
            "-profile:v", "main10" if ten_bit else "main",
            "-pix_fmt", "p010le" if ten_bit else "yuv420p",
            "-rc", "vbr",
            "-cq", str(crf),
            "-b:v", "0",
            "-multipass", "fullres",
            "-rc-lookahead", "32",
            "-spatial_aq", "1",
            "-temporal_aq", "1",
            "-tag:v", "hvc1",
        ]
    return [
        "-c:v", "libx265", "-preset", preset, "-crf", str(crf),
        "-pix_fmt", pixel_format, "-tag:v", "hvc1",
        "-x265-params", "log-level=error",
    ]


def ffmpeg_video_args(
    media: MediaInfo,
    candidate: Candidate,
    *,
    encoder: Encoder,
    preset: str,
    profile: Profile,
) -> list[str]:
    args: list[str] = []
    video_filter = _video_filter(media, candidate.width, candidate.height)
    if video_filter:
        args.extend(["-vf", video_filter])
    args.extend(_encoder_args(
        media, encoder=encoder, crf=candidate.crf, preset=preset, profile=profile,
    ))
    return args


def _encode_file_sample(
    media: MediaInfo,
    candidate: Candidate,
    offset: float,
    seconds: float,
    output: Path,
    *,
    encoder: Encoder,
    preset: str,
    profile: Profile,
    nice: int,
) -> float:
    pixel_format = "yuv420p10le" if media.bit_depth > 8 or media.hdr else "yuv420p"
    filters: list[str] = ["setpts=PTS-STARTPTS"]
    if media.field_order not in {"progressive", "unknown", ""}:
        filters.append("bwdif=mode=send_frame:parity=auto:deint=interlaced")
    if (candidate.width, candidate.height) == (media.width, media.height):
        filters.append("split=2[for_encode][reference]")
        first_graph = f"[0:{media.video_stream_index}]{','.join(filters)}"
    else:
        filters.append("split=2[to_scale][reference]")
        first_graph = (
            f"[0:{media.video_stream_index}]{','.join(filters)};"
            f"[to_scale]scale={candidate.width}:{candidate.height}:flags=lanczos"
            f"[for_encode]"
        )
    comparison_graph = (
        f"[dec:0]setpts=PTS-STARTPTS,"
        f"scale={media.width}:{media.height}:flags=lanczos,"
        f"format={pixel_format}[distorted];"
        f"[reference]format={pixel_format}[original];"
        f"[distorted][original]xpsnr=stats_file=-[metric]"
    )
    args = [
        "ffmpeg", "-hide_banner", "-loglevel", "info", "-y",
        "-ss", f"{offset:.3f}", "-t", f"{seconds:.3f}",
        "-i", str(media.source.path),
        "-filter_complex", first_graph,
        "-map", "[for_encode]", "-an", "-sn", "-dn",
        *_encoder_args(
            media, encoder=encoder, crf=candidate.crf,
            preset=preset, profile=profile,
        ),
        "-map_metadata", "-1", "-f", "matroska", str(output),
        "-dec", "0:0",
        "-filter_complex", comparison_graph,
        "-map", "[metric]", "-an", "-f", "null", "-",
    ]
    result = run(args, nice=nice)
    text = (result.stderr or "") + "\n" + (result.stdout or "")
    matches = _XPSNR.findall(text)
    if not matches:
        raise CommandError(f"Could not measure XPSNR for sample of {media.source.path}")
    return float(matches[-1])


def _encode_dvd_sample(
    media: MediaInfo,
    offset: float,
    seconds: float,
    output: Path,
    *,
    preset: str,
    profile: Profile,
    nice: int,
) -> None:
    # HandBrake is used because it understands DVD cells, angles, IFO
    # metadata, and timestamp discontinuities that ffmpeg's VOB demuxer does
    # not reconstruct on its own.
    encoder = "x265_10bit" if media.bit_depth > 8 or media.hdr else "x265"
    args = [
        "HandBrakeCLI", *handbrake_input_args(media.source),
        "--output", str(output), "--format", "av_mkv",
        "--start-at", f"seconds:{round(offset)}",
        "--stop-at", f"seconds:{max(1, round(seconds))}",
        "--encoder", encoder, "--encoder-preset", preset,
        "--quality", str(base_crf(media.height) + profile.crf_offset),
        "--audio", "none", "--subtitle", "none", "--markers",
        "--comb-detect", "--decomb",
    ]
    run(args, nice=nice)


_XPSNR = re.compile(r"XPSNR average.*?\by:\s*([0-9.]+)", re.IGNORECASE)


def analyze(
    media: MediaInfo,
    *,
    profile: Profile,
    min_savings_pct: float | None = None,
    min_reclaim_bytes: int = 100 * 1024 * 1024,
    sample_seconds: float = 10.0,
    sample_count: int = 3,
    encoder: Encoder = "x265",
    preset: str = "medium",
    nice: int = 10,
    work_dir: Path | None = None,
    sample_progress: Callable[[int, int, str], None] | None = None,
) -> Plan:
    required_pct = profile.min_savings_pct if min_savings_pct is None else min_savings_pct
    if media.duration < 5:
        return Plan(media, "skip", "shorter than 5 seconds")
    offsets = sample_offsets(media.duration, sample_seconds, sample_count)
    candidates = [
        Candidate(width, height, base_crf(height) + profile.crf_offset)
        for width, height in candidate_dimensions(media)
    ]

    if work_dir is None:
        temporary_context = tempfile.TemporaryDirectory(prefix="vidreclaim-")
        sample_root = Path(temporary_context.name)
    else:
        temporary_context = None
        sample_root = work_dir
        sample_root.mkdir(parents=True, exist_ok=True)

    try:
        total_samples = len(candidates) * len(offsets)
        completed_samples = 0
        for candidate_index, candidate in enumerate(candidates):
            scores: list[float] = []
            encoded_seconds = 0.0
            sample_wall_seconds = 0.0
            sample_bytes = 0
            for offset_index, offset in enumerate(offsets):
                actual_seconds = min(sample_seconds, media.duration - offset)
                sample_path = sample_root / (
                    f"candidate-{candidate_index}-sample-{offset_index}.mkv"
                )
                sample_started = time.monotonic()
                if media.source.kind == "dvd":
                    _encode_dvd_sample(
                        media, offset, actual_seconds, sample_path,
                        preset=preset, profile=profile, nice=nice,
                    )
                else:
                    scores.append(_encode_file_sample(
                        media, candidate, offset, actual_seconds, sample_path,
                        encoder=encoder, preset=preset, profile=profile, nice=nice,
                    ))
                sample_wall_seconds += time.monotonic() - sample_started
                sample_bytes += sample_path.stat().st_size
                encoded_seconds += actual_seconds
                completed_samples += 1
                if sample_progress:
                    sample_progress(
                        completed_samples, total_samples,
                        f"{candidate.resolution} at {offset:.1f}s",
                    )

            candidate.sample_bytes = sample_bytes
            candidate.sample_seconds = encoded_seconds
            candidate.sample_wall_seconds = sample_wall_seconds
            candidate.xpsnr = sum(scores) / len(scores) if scores else None
            sampled_speed = encoded_seconds / max(sample_wall_seconds, 0.001)
            candidate.projected_encode_seconds = (
                media.duration / max(sampled_speed, 0.001)
            )
            sampled_video_rate = sample_bytes * 8 / max(encoded_seconds, 0.001)
            # DVD samples are video-only; regular samples are also video-only.
            projected_rate = sampled_video_rate + media.nonvideo_bit_rate
            candidate.projected_bytes = math.ceil(
                projected_rate * media.duration / 8 * 1.02
            )
            candidate.savings_pct = (
                (media.size_bytes - candidate.projected_bytes)
                / media.size_bytes * 100
            )
            required_score = (
                profile.min_xpsnr_native
                if (candidate.width, candidate.height) == (media.width, media.height)
                else profile.min_xpsnr_scaled
            )
            score_ok = candidate.xpsnr is None or candidate.xpsnr >= required_score
            pct_ok = candidate.savings_pct >= required_pct
            bytes_ok = media.size_bytes - candidate.projected_bytes >= min_reclaim_bytes
            candidate.accepted = score_ok and pct_ok and bytes_ok
            failures: list[str] = []
            if not score_ok:
                failures.append(
                    f"XPSNR {candidate.xpsnr:.1f} < {required_score:.1f}"
                )
            if not pct_ok:
                failures.append(
                    f"savings {candidate.savings_pct:.1f}% < {required_pct:.1f}%"
                )
            if not bytes_ok:
                failures.append("absolute reclaim below threshold")
            candidate.reason = "accepted" if candidate.accepted else "; ".join(failures)
    finally:
        if temporary_context is not None:
            temporary_context.cleanup()

    accepted = [candidate for candidate in candidates if candidate.accepted]
    if not accepted:
        details = ", ".join(
            f"{candidate.resolution}: {candidate.reason}" for candidate in candidates
        )
        return Plan(
            media, "skip", f"no candidate cleared thresholds ({details})",
            candidates=candidates, sample_offsets=offsets,
        )
    chosen = min(accepted, key=lambda candidate: candidate.projected_bytes)
    return Plan(
        media, "encode",
        f"projected reclaim {chosen.savings_pct:.1f}%",
        candidate=chosen, candidates=candidates, sample_offsets=offsets,
    )
