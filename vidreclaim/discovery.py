from __future__ import annotations

import os
from pathlib import Path
from typing import Iterator

from .model import Source


VIDEO_EXTENSIONS = {
    ".3gp", ".asf", ".avi", ".divx", ".f4v", ".flv", ".m2t", ".m2ts",
    ".m4v", ".mkv", ".mov", ".mp4", ".mpeg", ".mpg", ".mts", ".ogm",
    ".rm", ".rmvb", ".ts", ".vob", ".webm", ".wmv",
}
IGNORED_DIRS = {
    ".git", ".reclaim-originals", ".vidreclaim", "VidReclaim Output",
    "__pycache__",
}


def discover(root: Path) -> Iterator[Source]:
    root = root.expanduser().resolve()
    if root.is_file():
        if root.suffix.lower() in VIDEO_EXTENSIONS:
            yield Source(root)
        return

    for current, dirs, files in os.walk(root):
        current_path = Path(current)
        lowered = {name.lower(): name for name in dirs}
        if current_path.name.lower() == "video_ts":
            yield Source(current_path, kind="dvd", display_name=current_path.parent.name)
            dirs[:] = []
            continue
        if "video_ts" in lowered:
            dvd_path = current_path / lowered["video_ts"]
            yield Source(dvd_path, kind="dvd", display_name=current_path.name)
            dirs.remove(lowered["video_ts"])

        dirs[:] = [
            name for name in dirs
            if name not in IGNORED_DIRS and not name.startswith(".vidreclaim-")
        ]
        for name in files:
            path = current_path / name
            if path.suffix.lower() in VIDEO_EXTENSIONS:
                yield Source(path)
