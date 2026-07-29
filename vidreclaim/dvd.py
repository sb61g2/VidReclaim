from __future__ import annotations

import json
import shutil
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable

from .model import MediaInfo, Source
from .util import CommandError, parse_fraction, run


@dataclass(frozen=True)
class DvdTitle:
    index: int
    duration: float
    width: int
    height: int
    fps: float
    audio_streams: int
    subtitle_streams: int
    raw: dict[str, Any]


def select_main_titles(
    titles: Iterable[DvdTitle],
    *,
    min_title_seconds: float = 10 * 60,
    cluster_ratio: float = 0.65,
) -> list[DvdTitle]:
    """Keep a movie feature or a cluster of similarly sized TV episodes.

    DVD menus and trailers are normally short. A movie's feature usually
    dominates the runtime, while episodic titles form a group with similar
    durations. Ambiguous long extras are deliberately surfaced in the plan.
    """
    candidates = [title for title in titles if title.duration >= min_title_seconds]
    if not candidates:
        return sorted(titles, key=lambda title: title.duration, reverse=True)[:1]
    if not candidates:
        return []
    longest = max(title.duration for title in candidates)
    cutoff = max(min_title_seconds, longest * cluster_ratio)
    return sorted(
        (title for title in candidates if title.duration >= cutoff),
        key=lambda title: title.index,
    )


def _extract_json(text: str, marker: str = "JSON Title Set:") -> dict[str, Any]:
    marker_at = text.rfind(marker)
    payload = text[marker_at + len(marker):] if marker_at >= 0 else text
    brace = payload.find("{")
    if brace < 0:
        raise CommandError("HandBrakeCLI did not return a JSON title set")
    decoder = json.JSONDecoder()
    try:
        value, _ = decoder.raw_decode(payload[brace:])
    except json.JSONDecodeError as error:
        raise CommandError(f"Could not parse HandBrakeCLI scan JSON: {error}") from error
    if not isinstance(value, dict):
        raise CommandError("HandBrakeCLI title set was not a JSON object")
    return value


def _seconds(value: Any) -> float:
    if isinstance(value, (int, float)):
        return float(value)
    if not isinstance(value, dict):
        return 0.0
    return (
        float(value.get("Hours", 0)) * 3600
        + float(value.get("Minutes", 0)) * 60
        + float(value.get("Seconds", 0))
        + float(value.get("Ticks", 0)) / 90_000
    )


def scan_dvd_titles(video_ts: Path) -> list[DvdTitle]:
    executable = shutil.which("HandBrakeCLI")
    if not executable:
        raise CommandError(
            "VIDEO_TS found but HandBrakeCLI is not installed. "
            "Install it with: brew install handbrake"
        )
    result = run([
        executable, "--input", str(video_ts), "--title", "0", "--scan", "--json",
    ])
    data = _extract_json((result.stdout or "") + "\n" + (result.stderr or ""))
    output: list[DvdTitle] = []
    for item in data.get("TitleList", []):
        geometry = item.get("Geometry") or {}
        frame_rate = item.get("FrameRate") or {}
        fps = parse_fraction(
            f"{frame_rate.get('Num', 0)}/{frame_rate.get('Den', 1)}"
        )
        output.append(DvdTitle(
            index=int(item.get("Index", 0)),
            duration=_seconds(item.get("Duration")),
            width=int(geometry.get("Width", 720)),
            height=int(geometry.get("Height", 480)),
            fps=fps or 29.97,
            audio_streams=len(item.get("AudioList") or []),
            subtitle_streams=len(item.get("SubtitleList") or []),
            raw=item,
        ))
    return [title for title in output if title.index > 0 and title.duration > 0]


def probe_dvd(
    source: Source,
    *,
    keep_extras: bool = False,
    min_title_seconds: float = 10 * 60,
) -> tuple[list[MediaInfo], list[DvdTitle]]:
    all_titles = scan_dvd_titles(source.path)
    selected = (
        all_titles
        if keep_extras
        else select_main_titles(all_titles, min_title_seconds=min_title_seconds)
    )
    if not selected:
        raise CommandError(f"No usable titles found in {source.path}")

    total_bytes = sum(
        path.stat().st_size
        for path in source.path.iterdir()
        if path.is_file() and path.suffix.lower() in {".vob", ".ifo", ".bup"}
    )
    selected_seconds = sum(title.duration for title in selected)
    media: list[MediaInfo] = []
    for title in selected:
        share = max(1, round(total_bytes * title.duration / selected_seconds))
        source_for_title = Source(
            source.path,
            kind="dvd",
            dvd_title=title.index,
            display_name=f"{source.display_name or source.path.parent.name} title {title.index}",
        )
        bit_rate = round(share * 8 / title.duration)
        media.append(MediaInfo(
            source=source_for_title,
            size_bytes=share,
            duration=title.duration,
            bit_rate=bit_rate,
            video_bit_rate=max(1, bit_rate - title.audio_streams * 384_000),
            nonvideo_bit_rate=title.audio_streams * 384_000,
            codec="mpeg2video",
            profile="DVD",
            width=title.width,
            height=title.height,
            fps=title.fps,
            pix_fmt="yuv420p",
            bit_depth=8,
            field_order="unknown",
            audio_streams=title.audio_streams,
            subtitle_streams=title.subtitle_streams,
        ))
    return media, all_titles


def handbrake_input_args(source: Source) -> list[str]:
    if source.dvd_title is None:
        raise ValueError("DVD source has no title")
    return ["--input", str(source.path), "--title", str(source.dvd_title)]
