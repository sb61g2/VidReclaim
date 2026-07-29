from __future__ import annotations

import json
from pathlib import Path
from typing import Any

from .model import MediaInfo, Source
from .util import CommandError, parse_fraction, run


def _integer(value: Any, default: int = 0) -> int:
    try:
        return int(value)
    except (TypeError, ValueError):
        return default


def _number(value: Any, default: float = 0.0) -> float:
    try:
        return float(value)
    except (TypeError, ValueError):
        return default


def probe_file(source: Source) -> MediaInfo:
    result = run([
        "ffprobe", "-v", "error", "-show_format", "-show_streams",
        "-of", "json", str(source.path),
    ])
    try:
        data = json.loads(result.stdout or "{}")
    except json.JSONDecodeError as error:
        raise CommandError(f"ffprobe returned invalid JSON for {source.path}") from error
    streams = data.get("streams") or []
    videos = [stream for stream in streams if stream.get("codec_type") == "video"]
    if not videos:
        raise CommandError(f"No video stream in {source.path}")
    video = max(
        videos,
        key=lambda stream: _integer(stream.get("width")) * _integer(stream.get("height")),
    )
    audio = [stream for stream in streams if stream.get("codec_type") == "audio"]
    subtitles = [stream for stream in streams if stream.get("codec_type") == "subtitle"]
    format_data = data.get("format") or {}
    duration = _number(format_data.get("duration")) or _number(video.get("duration"))
    if duration <= 0:
        raise CommandError(f"Could not determine duration of {source.path}")
    size_bytes = _integer(format_data.get("size"), source.path.stat().st_size)
    bit_rate = _integer(format_data.get("bit_rate"))
    if not bit_rate:
        bit_rate = round(size_bytes * 8 / duration)
    video_bit_rate = _integer(video.get("bit_rate"))
    audio_bit_rate = sum(_integer(stream.get("bit_rate")) for stream in audio)
    if not video_bit_rate:
        video_bit_rate = max(1, bit_rate - audio_bit_rate)
    nonvideo_bit_rate = max(audio_bit_rate, bit_rate - video_bit_rate, 0)
    pix_fmt = str(video.get("pix_fmt") or "")
    bits = _integer(video.get("bits_per_raw_sample"))
    if not bits:
        bits = 10 if any(token in pix_fmt for token in ("10", "p010")) else 8
    transfer = str(video.get("color_transfer") or "").lower()
    side_data = json.dumps(video.get("side_data_list") or []).lower()
    hdr = transfer in {"smpte2084", "arib-std-b67"} or "mastering display" in side_data
    fps = (
        parse_fraction(video.get("avg_frame_rate"))
        or parse_fraction(video.get("r_frame_rate"))
        or 30.0
    )
    return MediaInfo(
        source=source,
        size_bytes=size_bytes,
        duration=duration,
        bit_rate=bit_rate,
        video_bit_rate=video_bit_rate,
        nonvideo_bit_rate=nonvideo_bit_rate,
        codec=str(video.get("codec_name") or "unknown").lower(),
        profile=str(video.get("profile") or ""),
        width=_integer(video.get("width")),
        height=_integer(video.get("height")),
        fps=fps,
        pix_fmt=pix_fmt,
        bit_depth=bits,
        field_order=str(video.get("field_order") or "unknown").lower(),
        audio_streams=len(audio),
        subtitle_streams=len(subtitles),
        hdr=hdr,
        video_stream_index=_integer(video.get("index")),
    )


def probe_output(path: Path) -> MediaInfo:
    return probe_file(Source(path))
