from __future__ import annotations

import sys
import time
from pathlib import Path
from typing import Any

from .util import atomic_write_json, duration_text


class ProgressReporter:
    """TTY-friendly and machine-readable weighted batch progress."""

    def __init__(
        self,
        jobs: list[tuple[str, float]],
        *,
        progress_path: Path,
        initial_eta_seconds: float | None = None,
    ) -> None:
        self.jobs = jobs
        self.total_weight = sum(duration for _, duration in jobs) or 1.0
        self.progress_path = progress_path
        self.initial_eta_seconds = initial_eta_seconds
        self.started_at = time.monotonic()
        self.completed_weight = 0.0
        self.current_index = -1
        self.current_name = ""
        self.current_duration = 0.0
        self.current_fraction = 0.0
        self.phase = "starting"
        self.speed: float | None = None
        self.last_terminal_update = 0.0
        self.last_file_update = 0.0
        self.last_non_tty_bucket = -1

    def start_job(self, index: int, name: str, duration: float) -> None:
        self.current_index = index
        self.current_name = name
        self.current_duration = duration
        self.current_fraction = 0.0
        self.phase = "encoding"
        self.speed = None
        self._emit(force=True)

    def update(
        self,
        fraction: float,
        *,
        phase: str = "encoding",
        speed: float | None = None,
    ) -> None:
        self.current_fraction = max(self.current_fraction, min(1.0, fraction))
        self.phase = phase
        if speed is not None and speed > 0:
            self.speed = speed
        self._emit()

    def set_phase(self, phase: str) -> None:
        self.phase = phase
        self._emit(force=True)

    def finish_job(self) -> None:
        self.current_fraction = 1.0
        self.phase = "complete"
        self._emit(force=True)
        self.completed_weight += self.current_duration
        self.current_duration = 0.0

    def fail_job(self) -> None:
        self.phase = "error"
        self._emit(force=True)
        # A failed job is complete from the batch scheduler's perspective.
        self.completed_weight += self.current_duration
        self.current_duration = 0.0

    def snapshot(self) -> dict[str, Any]:
        elapsed = time.monotonic() - self.started_at
        weighted_done = self.completed_weight + self.current_duration * self.current_fraction
        overall = min(1.0, weighted_done / self.total_weight)
        observed_eta = (
            elapsed * (1 - overall) / overall if overall > 0.001 else None
        )
        planned_eta = (
            self.initial_eta_seconds * (1 - overall)
            if self.initial_eta_seconds is not None else None
        )
        if observed_eta is None:
            eta = planned_eta
        elif planned_eta is None:
            eta = observed_eta
        else:
            observed_weight = min(1.0, overall / 0.20)
            eta = (
                planned_eta * (1 - observed_weight)
                + observed_eta * observed_weight
            )
        return {
            "status": self.phase,
            "job_index": self.current_index + 1,
            "job_count": len(self.jobs),
            "job_name": self.current_name,
            "job_fraction": self.current_fraction,
            "overall_fraction": overall,
            "elapsed_seconds": elapsed,
            "eta_seconds": eta,
            "speed_x": self.speed,
            "updated_at_unix": time.time(),
        }

    def _emit(self, *, force: bool = False) -> None:
        now = time.monotonic()
        snapshot = self.snapshot()
        overall_pct = snapshot["overall_fraction"] * 100
        bucket = int(overall_pct // 5)
        tty_due = sys.stdout.isatty() and now - self.last_terminal_update >= 0.25
        plain_due = (
            not sys.stdout.isatty()
            and (bucket != self.last_non_tty_bucket or now - self.last_terminal_update >= 30)
        )
        if force or tty_due or plain_due:
            eta = snapshot["eta_seconds"]
            eta_text = duration_text(eta) if eta is not None else "--:--:--"
            speed_text = f" · {self.speed:.2f}×" if self.speed else ""
            text = (
                f"[{snapshot['job_index']}/{snapshot['job_count']}] "
                f"{overall_pct:5.1f}% overall · "
                f"{self.current_fraction * 100:5.1f}% {self.phase}"
                f"{speed_text} · ETA {eta_text} · {self.current_name}"
            )
            if sys.stdout.isatty():
                print(f"\r\033[K{text}", end="", flush=True)
                if self.phase in {"complete", "error"}:
                    print()
            else:
                print(text, flush=True)
            self.last_terminal_update = now
            self.last_non_tty_bucket = bucket
        if force or now - self.last_file_update >= 1:
            atomic_write_json(self.progress_path, snapshot)
            self.last_file_update = now
