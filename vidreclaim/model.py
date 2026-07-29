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

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> "MediaInfo":
        source_data = data["source"]
        return cls(
            source=Source(
                Path(source_data["path"]),
                kind=source_data.get("kind", "file"),
                dvd_title=source_data.get("dvd_title"),
                display_name=source_data.get("display_name"),
            ),
            size_bytes=int(data["size_bytes"]),
            duration=float(data["duration"]),
            bit_rate=int(data["bit_rate"]),
            video_bit_rate=int(data["video_bit_rate"]),
            nonvideo_bit_rate=int(data["nonvideo_bit_rate"]),
            codec=str(data["codec"]),
            profile=str(data.get("profile", "")),
            width=int(data["width"]),
            height=int(data["height"]),
            fps=float(data["fps"]),
            pix_fmt=str(data.get("pix_fmt", "")),
            bit_depth=int(data.get("bit_depth", 8)),
            field_order=str(data.get("field_order", "unknown")),
            audio_streams=int(data.get("audio_streams", 0)),
            subtitle_streams=int(data.get("subtitle_streams", 0)),
            hdr=bool(data.get("hdr", False)),
            video_stream_index=int(data.get("video_stream_index", 0)),
        )


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

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> "Candidate":
        return cls(**data)


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

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> "Plan":
        candidate_data = data.get("candidate")
        return cls(
            media=MediaInfo.from_dict(data["media"]),
            status=data["status"],
            reason=data["reason"],
            candidate=(
                Candidate.from_dict(candidate_data) if candidate_data else None
            ),
            candidates=[
                Candidate.from_dict(candidate)
                for candidate in data.get("candidates", [])
            ],
            sample_offsets=[
                float(offset) for offset in data.get("sample_offsets", [])
            ],
            output=Path(data["output"]) if data.get("output") else None,
        )
