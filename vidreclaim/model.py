from __future__ import annotations

from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Any, Literal


SourceKind = Literal["file", "dvd"]


@dataclass(frozen=True)
class Source:
    path: Path
    kind: SourceKind = "file"
    dvd_title: int | None = None
    display_name: str | None = None

    @property
    def key(self) -> str:
        suffix = f"#title={self.dvd_title}" if self.dvd_title is not None else ""
        return f"{self.path.resolve()}{suffix}"


@dataclass
class MediaInfo:
    source: Source
    size_bytes: int
    duration: float
    bit_rate: int
    video_bit_rate: int
    nonvideo_bit_rate: int
    codec: str
    profile: str
    width: int
    height: int
    fps: float
    pix_fmt: str
    bit_depth: int
    field_order: str
    audio_streams: int
    subtitle_streams: int
    hdr: bool = False
    video_stream_index: int = 0

    @property
    def megapixels(self) -> float:
        return self.width * self.height / 1_000_000

    @property
    def bpp_per_frame(self) -> float:
        pixels_per_second = self.width * self.height * self.fps
        return self.video_bit_rate / pixels_per_second if pixels_per_second else 0.0


@dataclass(frozen=True)
class Profile:
    name: str
    crf_offset: int
    min_xpsnr_native: float
    min_xpsnr_scaled: float
    min_savings_pct: float


PROFILES: dict[str, Profile] = {
    "conservative": Profile("conservative", -2, 38.0, 36.0, 15.0),
    "balanced": Profile("balanced", 0, 35.0, 33.0, 20.0),
    "compact": Profile("compact", 2, 32.0, 30.0, 25.0),
}


@dataclass
class Candidate:
    width: int
    height: int
    crf: int
    sample_bytes: int = 0
    sample_seconds: float = 0.0
    sample_wall_seconds: float = 0.0
    xpsnr: float | None = None
    projected_bytes: int = 0
    projected_encode_seconds: float = 0.0
    savings_pct: float = 0.0
    accepted: bool = False
    reason: str = ""

    @property
    def resolution(self) -> str:
        return f"{self.width}x{self.height}"


@dataclass
class Plan:
    media: MediaInfo
    status: Literal["encode", "skip", "error"]
    reason: str
    candidate: Candidate | None = None
    candidates: list[Candidate] = field(default_factory=list)
    sample_offsets: list[float] = field(default_factory=list)
    output: Path | None = None

    def to_dict(self) -> dict[str, Any]:
        data = asdict(self)
        data["media"]["source"]["path"] = str(self.media.source.path)
        if self.output is not None:
            data["output"] = str(self.output)
        return data
