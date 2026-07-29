from __future__ import annotations

import os
import sys
from pathlib import Path


def configure_bundled_tools() -> None:
    """Put media tools bundled by PyInstaller ahead of the ambient PATH."""
    candidates: list[Path] = []
    frozen_root = getattr(sys, "_MEIPASS", None)
    if frozen_root:
        root = Path(frozen_root)
        candidates.extend([root / "tools", root])
    executable_dir = Path(sys.executable).resolve().parent
    candidates.extend([
        executable_dir / "tools",
        executable_dir / "_internal" / "tools",
    ])
    bundled = [str(path) for path in candidates if path.is_dir()]
    if not bundled:
        return
    current = os.environ.get("PATH", "")
    os.environ["PATH"] = os.pathsep.join([*bundled, current])
