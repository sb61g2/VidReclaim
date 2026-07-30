from __future__ import annotations

import fcntl
import hashlib
import json
import os
import re
import shutil
import time
import uuid
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import asdict
from pathlib import Path
from typing import Any, Callable

from .discovery import discover
from .dvd import probe_dvd
from .model import MediaInfo, Plan, PROFILES, Source
from .planner import analyze, analyze_fast
from .probe import probe_file
from .review import build_review_assets, review_in_browser
from .remote import config_from_settings
from .runner import (
    EncodeControl,
    archive_and_replace_file,
    archive_dvd,
    delete_verified_dvd_source,
    delete_verified_file_source,
    encode,
    output_path,
)
from .util import CommandError, atomic_write_json


TERMINAL_ITEM_STATES = {
    "complete", "processed", "skipped", "cancelled", "error",
}
RUNNABLE_ITEM_STATES = {"ready"}


def sessions_directory() -> Path:
    return (
        Path.home()
        / "Library"
        / "Application Support"
        / "VidReclaim"
        / "Sessions"
    )


def new_session_path() -> Path:
    stamp = time.strftime("%Y%m%d-%H%M%S")
    return sessions_directory() / f"{stamp}-{uuid.uuid4().hex[:8]}.json"


def _item_id(key: str) -> str:
    return hashlib.sha1(key.encode("utf-8")).hexdigest()[:16]


def _source_dict(source: Source) -> dict[str, Any]:
    return {
        "path": str(source.path),
        "kind": source.kind,
        "dvd_title": source.dvd_title,
        "display_name": source.display_name,
    }


def _media_dict(media: MediaInfo) -> dict[str, Any]:
    data = asdict(media)
    data["source"]["path"] = str(media.source.path)
    return data


def _pid_is_alive(pid: int | None) -> bool:
    if not pid:
        return False
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False


class SessionStore:
    """Atomic, cross-process JSON state shared by the worker and SwiftUI."""

    def __init__(self, path: Path) -> None:
        self.path = path.expanduser().resolve()
        self.lock_path = self.path.with_suffix(self.path.suffix + ".lock")

    def _locked(self, operation: Callable[[], Any]) -> Any:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        with self.lock_path.open("a+", encoding="utf-8") as lock:
            fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
            try:
                return operation()
            finally:
                fcntl.flock(lock.fileno(), fcntl.LOCK_UN)

    def read(self) -> dict[str, Any]:
        def operation() -> dict[str, Any]:
            if not self.path.exists():
                raise CommandError(f"Queue session does not exist: {self.path}")
            return json.loads(self.path.read_text(encoding="utf-8"))

        return self._locked(operation)

    def write(self, data: dict[str, Any]) -> None:
        def operation() -> None:
            data["updated_at_unix"] = time.time()
            atomic_write_json(self.path, data)

        self._locked(operation)

    def mutate(
        self,
        change: Callable[[dict[str, Any]], None],
    ) -> dict[str, Any]:
        def operation() -> dict[str, Any]:
            if not self.path.exists():
                raise CommandError(f"Queue session does not exist: {self.path}")
            data = json.loads(self.path.read_text(encoding="utf-8"))
            change(data)
            data["updated_at_unix"] = time.time()
            atomic_write_json(self.path, data)
            return data

        return self._locked(operation)


def create_session(
    path: Path,
    *,
    root: Path,
    settings: dict[str, Any],
) -> dict[str, Any]:
    root = root.expanduser().resolve()
    if not root.exists():
        raise CommandError(f"Root does not exist: {root}")
    now = time.time()
    data = {
        "schema": 4,
        "id": uuid.uuid4().hex,
        "name": root.name or str(root),
        "root": str(root),
        "session_path": str(path.expanduser().resolve()),
        "status": "new",
        "phase": "Waiting to scan",
        "created_at_unix": now,
        "updated_at_unix": now,
        "worker_pid": None,
        "settings": settings,
        "items": [],
        "overall_fraction": 0.0,
        "scan_fraction": 0.0,
        "encode_fraction": 0.0,
        "eta_seconds": None,
        "completed_count": 0,
        "error_count": 0,
        "summary": "Ready to scan",
    }
    SessionStore(path).write(data)
    return data


def _cache_path() -> Path:
    return Path.home() / "Library" / "Caches" / "VidReclaim" / "probes.json"


def _processed_catalog_path() -> Path:
    override = os.environ.get("VIDRECLAIM_CATALOG_PATH")
    if override:
        return Path(override).expanduser().resolve()
    return (
        Path.home()
        / "Library"
        / "Application Support"
        / "VidReclaim"
        / "processed-media.json"
    )


def _load_processed_catalog() -> dict[str, Any]:
    try:
        data = json.loads(
            _processed_catalog_path().read_text(encoding="utf-8"),
        )
        return data if data.get("schema") == 1 else {"schema": 1, "entries": {}}
    except (OSError, json.JSONDecodeError):
        return {"schema": 1, "entries": {}}


def _catalog_key(root: Path, source: Source) -> str:
    identity = f"{root.resolve()}|{source.key}"
    return hashlib.sha256(identity.encode("utf-8")).hexdigest()


def _processed_record(
    root: Path,
    source: Source,
    catalog: dict[str, Any],
) -> dict[str, Any] | None:
    entries = catalog.get("entries", {})
    record = entries.get(_catalog_key(root, source))
    matched_output = False
    if not record:
        output_key = catalog.get("outputs", {}).get(
            str(source.path.resolve()),
        )
        record = entries.get(output_key) if output_key else None
        matched_output = record is not None
    if not record:
        return None
    try:
        signature = _source_signature(source)
    except OSError:
        return None
    fields = (
        ("output_signature", "final_source_signature")
        if matched_output else
        ("source_signature", "final_source_signature")
    )
    valid_signatures = {
        record.get(field) for field in fields if record.get(field)
    }
    if signature not in valid_signatures:
        return None
    output = record.get("output")
    if output and not Path(output).exists():
        return None
    return record


def _save_processed_record(
    root: Path,
    source: Source,
    *,
    item: dict[str, Any],
    result: dict[str, Any],
) -> None:
    path = _processed_catalog_path()
    lock_path = path.with_suffix(path.suffix + ".lock")
    path.parent.mkdir(parents=True, exist_ok=True)
    with lock_path.open("a+", encoding="utf-8") as lock:
        fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
        try:
            catalog = _load_processed_catalog()
            final_signature = None
            try:
                final_signature = _source_signature(source)
            except OSError:
                pass
            entry_key = _catalog_key(root, source)
            output = result.get("output")
            output_signature = None
            if output:
                try:
                    output_signature = _source_signature(Source(Path(output)))
                except OSError:
                    pass
            catalog.setdefault("entries", {})[entry_key] = {
                "root": str(root.resolve()),
                "source_path": str(source.path),
                "source_kind": source.kind,
                "dvd_title": source.dvd_title,
                "source_signature": item.get("source_signature"),
                "final_source_signature": final_signature,
                "source_bytes": item.get("source_bytes"),
                "output": output,
                "output_signature": output_signature,
                "output_bytes": result.get("output_bytes"),
                "actual_savings_pct": result.get("actual_savings_pct"),
                "encode_elapsed_seconds": result.get("encode_elapsed_seconds"),
                "completed_at_unix": result.get("completed_at_unix"),
            }
            if output:
                catalog.setdefault("outputs", {})[
                    str(Path(output).resolve())
                ] = entry_key
            atomic_write_json(path, catalog)
        finally:
            fcntl.flock(lock.fileno(), fcntl.LOCK_UN)


def _mark_item_from_processed_record(
    item: dict[str, Any],
    record: dict[str, Any],
) -> None:
    item.update({
        "status": "processed",
        "selected": False,
        "processed": True,
        "progress": 1.0,
        "message": "Processed",
        "source_bytes": record.get("source_bytes") or item.get("source_bytes"),
        "output": record.get("output"),
        "output_bytes": record.get("output_bytes"),
        "actual_savings_pct": record.get("actual_savings_pct"),
        "encode_elapsed_seconds": (
            record.get("encode_elapsed_seconds") or 0.0
        ),
        "completed_at_unix": record.get("completed_at_unix"),
    })


def _load_probe_cache() -> dict[str, Any]:
    try:
        data = json.loads(_cache_path().read_text(encoding="utf-8"))
        return data if data.get("schema") == 1 else {"schema": 1, "entries": {}}
    except (OSError, json.JSONDecodeError):
        return {"schema": 1, "entries": {}}


def _source_signature(source: Source) -> str:
    stat = source.path.stat()
    return f"{source.path.resolve()}|{stat.st_size}|{stat.st_mtime_ns}"


def _probe_cached(source: Source, cache: dict[str, Any]) -> MediaInfo:
    signature = _source_signature(source)
    cached = cache.get("entries", {}).get(signature)
    if cached:
        return MediaInfo.from_dict(cached)
    return probe_file(source)


def _relative_item_location(root: Path, source: Source) -> tuple[str, str]:
    resolved_root = root.resolve()
    source_path = source.path.resolve()
    if source.kind == "dvd":
        display_path = source_path.parent
        base = resolved_root.parent if resolved_root.is_file() else resolved_root
    else:
        display_path = source_path
        base = resolved_root.parent if resolved_root.is_file() else resolved_root
    try:
        relative = display_path.relative_to(base)
    except ValueError:
        relative = Path(display_path.name)
    if source.kind == "dvd" and source.dvd_title is not None:
        relative = relative / f"Title {source.dvd_title:02d}"
    folder = relative.parent
    folder_text = "" if str(folder) == "." else folder.as_posix()
    return relative.as_posix(), folder_text


def _new_item(
    source: Source,
    order: int,
    *,
    root: Path,
    status: str = "probing",
) -> dict[str, Any]:
    relative_path, relative_folder = _relative_item_location(root, source)
    try:
        signature = _source_signature(source)
    except OSError:
        signature = None
    return {
        "id": _item_id(source.key),
        "order": order,
        "name": source.display_name or source.path.name,
        "path": str(source.path),
        "relative_path": relative_path,
        "relative_folder": relative_folder,
        "source_signature": signature,
        "source": _source_dict(source),
        "status": status,
        "selected": True,
        "processed": False,
        "requested_action": None,
        "progress": 0.0,
        "speed_x": None,
        "eta_seconds": None,
        "projected_encode_seconds": None,
        "encode_elapsed_seconds": 0.0,
        "encode_started_at_unix": None,
        "duration": None,
        "source_bytes": (
            source.path.stat().st_size if source.kind == "file" else None
        ),
        "projected_bytes": None,
        "projected_savings_pct": None,
        "output_bytes": None,
        "actual_savings_pct": None,
        "output": None,
        "message": "Reading stream metadata",
        "plan": None,
        "what_if": [],
    }


def _replace_item(
    store: SessionStore,
    item_id: str,
    replacement: dict[str, Any],
) -> None:
    def change(data: dict[str, Any]) -> None:
        for index, item in enumerate(data["items"]):
            if item["id"] == item_id:
                replacement["order"] = item["order"]
                data["items"][index] = replacement
                return

    store.mutate(change)


def _scan_progress_fraction(data: dict[str, Any]) -> float:
    items = data.get("items", [])
    if not items:
        return 0.0
    completed_states = {
        "ready", "complete", "processed", "skipped", "cancelled", "error",
    }
    progress = 0.0
    for item in items:
        status = item.get("status")
        if status in completed_states:
            progress += 1.0
        elif status == "analyzing":
            progress += 0.5 + 0.5 * min(
                1.0, max(0.0, float(item.get("progress") or 0.0)),
            )
    return min(1.0, progress / len(items))


def _update_item(store: SessionStore, item_id: str, **updates: Any) -> None:
    def change(data: dict[str, Any]) -> None:
        item = next(
            (candidate for candidate in data["items"] if candidate["id"] == item_id),
            None,
        )
        if item is not None:
            item.update(updates)
            data["scan_fraction"] = max(
                float(data.get("scan_fraction") or 0.0),
                _scan_progress_fraction(data),
            )

    store.mutate(change)


def _plan_media(
    media: MediaInfo,
    settings: dict[str, Any],
    *,
    work_dir: Path | None,
    sample_progress: Callable[[int, int, str], None] | None,
) -> Plan:
    common = {
        "profile": PROFILES[settings["profile"]],
        "min_savings_pct": settings.get("min_savings_pct"),
        "min_reclaim_bytes": round(settings["min_reclaim_mb"] * 1024 * 1024),
        "encoder": settings["encoder"],
        "preset": settings["preset"],
    }
    if not settings.get("thorough_analysis", False):
        return analyze_fast(media, **common)
    return analyze(
        media,
        **common,
        sample_seconds=settings["sample_seconds"],
        sample_count=settings["samples"],
        nice=settings["nice"],
        work_dir=work_dir,
        sample_progress=sample_progress,
    )


def _what_if_estimates(
    media: MediaInfo,
    settings: dict[str, Any],
) -> list[dict[str, Any]]:
    """Instant option comparisons from already-collected metadata."""
    variants = [
        ("x265", "veryfast", "x265 · Very Fast"),
        ("x265", "medium", "x265 · Medium"),
        ("x265", "slow", "x265 · Slow"),
        ("videotoolbox", "medium", "M4 hardware"),
    ]
    estimates: list[dict[str, Any]] = []
    for profile_name in ("conservative", "balanced", "compact"):
        for encoder, preset, encoder_label in variants:
            plan = analyze_fast(
                media,
                profile=PROFILES[profile_name],
                min_savings_pct=-1000,
                min_reclaim_bytes=-(10**18),
                encoder=encoder,
                preset=preset,
            )
            candidate = plan.candidate
            if candidate is None:
                continue
            estimates.append({
                "id": f"{profile_name}-{encoder}-{preset}",
                "profile": profile_name,
                "encoder": encoder,
                "preset": preset,
                "encoder_label": encoder_label,
                "resolution": candidate.resolution,
                "projected_bytes": candidate.projected_bytes,
                "savings_pct": candidate.savings_pct,
                "encode_seconds": candidate.projected_encode_seconds,
                "selected": (
                    profile_name == settings["profile"]
                    and encoder == settings["encoder"]
                    and (
                        encoder == "videotoolbox"
                        or preset == settings["preset"]
                    )
                ),
            })
    return estimates


def _prepare_session(store: SessionStore) -> tuple[list[Plan], list[dict[str, Any]]]:
    session = store.read()
    settings = session["settings"]
    root = Path(session["root"])
    output_root = Path(settings["output_dir"])

    def discovering(data: dict[str, Any]) -> None:
        data.update({
            "status": "scanning",
            "phase": "Scanning folders for video sources",
            "scan_fraction": 0.0,
            "worker_pid": os.getpid(),
        })

    store.mutate(discovering)
    include_paths = [
        Path(value).expanduser().resolve()
        for value in settings.get("include_paths", [])
    ]
    review_paths = [
        Path(value).expanduser().resolve()
        for value in settings.get("review_paths", [])
    ]

    def selected_for_review(path: Path) -> bool:
        resolved = path.expanduser().resolve()
        for selected in review_paths:
            if resolved == selected:
                return True
            try:
                resolved.relative_to(selected)
                return True
            except ValueError:
                continue
        return False
    if include_paths:
        sources_by_key: dict[str, Source] = {}
        for include_path in include_paths:
            try:
                include_path.relative_to(root.resolve())
            except ValueError as error:
                raise CommandError(
                    f"Selected path is outside the queue root: {include_path}",
                ) from error
            for source in discover(include_path):
                sources_by_key.setdefault(source.key, source)
        sources = list(sources_by_key.values())
    else:
        sources = list(discover(root))
    min_reclaim_bytes = round(settings["min_reclaim_mb"] * 1024 * 1024)
    processed_catalog = _load_processed_catalog()
    processed_source_keys: set[str] = set()
    items: list[dict[str, Any]] = []
    for order, source in enumerate(sources):
        item = _new_item(source, order, root=root)
        record = (
            _processed_record(root, source, processed_catalog)
            if source.kind == "file" else None
        )
        if record:
            _mark_item_from_processed_record(item, record)
            processed_source_keys.add(source.key)
        elif (
            source.kind == "file"
            and source.path.stat().st_size <= min_reclaim_bytes
        ):
            item.update({
                "status": "skipped",
                "selected": False,
                "message": "File is smaller than the minimum reclaim threshold",
            })
        items.append(item)

    def begin(data: dict[str, Any]) -> None:
        data.update({
            "status": "scanning",
            "phase": f"Reading metadata for {len(sources)} candidate items",
            "items": items,
            "scan_fraction": _scan_progress_fraction({"items": items}),
            "encode_fraction": 0.0,
            "summary": f"Found {len(sources)} candidate items",
            "worker_pid": os.getpid(),
        })

    store.mutate(begin)
    print(f"Scanned directories: found {len(sources)} candidate video source(s).")

    cache = _load_probe_cache()
    file_sources = [
        source for source in sources
        if (
            source.kind == "file"
            and source.key not in processed_source_keys
            and source.path.stat().st_size > min_reclaim_bytes
        )
    ]
    media_by_key: dict[str, MediaInfo] = {}
    workers = max(1, min(int(settings.get("scan_workers", 6)), 12))
    with ThreadPoolExecutor(max_workers=workers) as executor:
        futures = {
            executor.submit(_probe_cached, source, cache): source
            for source in file_sources
        }
        for future in as_completed(futures):
            source = futures[future]
            item_id = _item_id(source.key)
            try:
                media = future.result()
                media_by_key[source.key] = media
                cache.setdefault("entries", {})[_source_signature(source)] = _media_dict(media)
                _update_item(
                    store,
                    item_id,
                    status="analyzing",
                    message="Choosing resolution and quality",
                    duration=media.duration,
                    source_bytes=media.size_bytes,
                )
            except (CommandError, OSError) as error:
                _update_item(
                    store, item_id, status="error", message=str(error),
                )

    cache_path = _cache_path()
    cache_path.parent.mkdir(parents=True, exist_ok=True)
    atomic_write_json(cache_path, cache)

    dvd_reports: list[dict[str, Any]] = []
    dvd_media: list[MediaInfo] = []
    for source in (source for source in sources if source.kind == "dvd"):
        placeholder_id = _item_id(source.key)
        try:
            selected, all_titles = probe_dvd(
                source,
                keep_extras=settings.get("keep_dvd_extras", False),
                min_title_seconds=settings.get("dvd_min_title_minutes", 10) * 60,
            )
            chosen = {item.source.dvd_title for item in selected}
            dvd_reports.append({
                "path": str(source.path),
                "main_content_only": not settings.get("keep_dvd_extras", False),
                "selected_titles": sorted(chosen),
                "excluded_titles": [
                    title.index for title in all_titles if title.index not in chosen
                ],
            })
            unprocessed_media: list[MediaInfo] = []

            def expand_dvd(data: dict[str, Any]) -> None:
                index = next(
                    (
                        idx for idx, item in enumerate(data["items"])
                        if item["id"] == placeholder_id
                    ),
                    None,
                )
                if index is None:
                    return
                base_order = data["items"][index]["order"]
                replacements = []
                for offset, media in enumerate(selected):
                    item = _new_item(
                        media.source,
                        base_order + offset,
                        root=root,
                        status="analyzing",
                    )
                    record = _processed_record(
                        root, media.source, processed_catalog,
                    )
                    if record:
                        _mark_item_from_processed_record(item, record)
                    else:
                        unprocessed_media.append(media)
                        item.update({
                            "duration": media.duration,
                            "source_bytes": media.size_bytes,
                            "message": "Choosing resolution and quality",
                        })
                    replacements.append(item)
                data["items"][index:index + 1] = replacements
                for order, item in enumerate(data["items"]):
                    item["order"] = order
                data["scan_fraction"] = _scan_progress_fraction(data)

            store.mutate(expand_dvd)
            dvd_media.extend(unprocessed_media)
        except (CommandError, OSError) as error:
            _update_item(
                store, placeholder_id, status="error", message=str(error),
            )

    all_media = [*media_by_key.values(), *dvd_media]
    # Preserve discovery order after parallel probing.
    current = store.read()
    item_order = {item["id"]: item["order"] for item in current["items"]}
    all_media.sort(key=lambda media: item_order.get(_item_id(media.source.key), 10**9))

    plans: list[Plan] = []
    review_plan_indices: set[int] = set()
    assets_dir = store.path.with_suffix("") / "review"
    for media in all_media:
        item_id = _item_id(media.source.key)
        plan_index = len(plans)
        review_this_media = selected_for_review(media.source.path)
        media_settings = dict(settings)
        media_settings["thorough_analysis"] = bool(
            settings.get("thorough_analysis", False)
            or (
                review_this_media
                and settings.get("review_mode", "clips") == "clips"
            )
        )

        def report_sample(done: int, total: int, detail: str) -> None:
            _update_item(
                store,
                item_id,
                status="analyzing",
                progress=done / max(total, 1),
                message=f"Quality sample {done}/{total}: {detail}",
            )

        try:
            plan = _plan_media(
                media,
                media_settings,
                work_dir=(
                    assets_dir / "clips" / str(plan_index)
                    if media_settings["thorough_analysis"] else None
                ),
                sample_progress=report_sample,
            )
            if plan.status == "encode":
                plan.output = output_path(root, plan, output_root)
            plans.append(plan)
            if review_this_media:
                review_plan_indices.add(plan_index)
            candidate = plan.candidate
            item_status = (
                "ready" if plan.status == "encode"
                else ("skipped" if plan.status == "skip" else plan.status)
            )
            _update_item(
                store,
                item_id,
                status=item_status,
                selected=item_status == "ready",
                progress=0.0,
                message=plan.reason,
                projected_bytes=(
                    candidate.projected_bytes if candidate else None
                ),
                projected_savings_pct=(
                    candidate.savings_pct if candidate else None
                ),
                eta_seconds=(
                    candidate.projected_encode_seconds if candidate else None
                ),
                projected_encode_seconds=(
                    candidate.projected_encode_seconds if candidate else None
                ),
                output=str(plan.output) if plan.output else None,
                plan=plan.to_dict(),
                what_if=_what_if_estimates(media, settings),
            )
        except (CommandError, OSError) as error:
            _update_item(
                store, item_id, status="error", message=str(error),
            )

    if settings.get("visual_review", False):
        targeted_review = bool(review_paths)

        def review_phase(data: dict[str, Any]) -> None:
            data.update({
                "status": "reviewing",
                "phase": "Waiting for side-by-side review",
            })

        store.mutate(review_phase)
        review_options = {
            "session_dir": assets_dir,
            "sample_seconds": settings["sample_seconds"],
            "plan_indices": (
                review_plan_indices if targeted_review else None
            ),
            "mode": settings.get("review_mode", "clips"),
            "sample_count": settings.get("samples", 3),
            "encoder": settings["encoder"],
            "preset": settings["preset"],
            "profile_name": settings["profile"],
        }
        if settings.get("review_interface") == "native":
            cards = build_review_assets(plans, **review_options)
            for card in cards:
                plan = plans[int(card["plan_index"])]
                pairs = [
                    {
                        "before": str(assets_dir / pair["before"]),
                        "after": str(assets_dir / pair["after"]),
                        "time": pair["time"],
                    }
                    for pair in card["pairs"]
                ]
                _update_item(
                    store,
                    _item_id(plan.media.source.key),
                    review_pairs=pairs,
                    message="Side-by-side review ready",
                )
        else:
            approved = review_in_browser(
                plans,
                decisions_path=store.path.with_suffix(".review.json"),
                **review_options,
            )
            for index, plan in enumerate(plans):
                if (
                    plan.status == "encode"
                    and (not targeted_review or index in review_plan_indices)
                    and index not in approved
                ):
                    plan.status = "skip"
                    plan.reason = "skipped in visual review"
                    _update_item(
                        store,
                        _item_id(plan.media.source.key),
                        status="skipped",
                        message=plan.reason,
                        plan=plan.to_dict(),
                    )

    def ready(data: dict[str, Any]) -> None:
        queued = sum(
            item["status"] == "ready" and item.get("selected", True)
            for item in data["items"]
        )
        eta = sum(
            float(item.get("eta_seconds") or 0)
            for item in data["items"]
            if item["status"] == "ready" and item.get("selected", True)
        )
        data.update({
            "status": "queued",
            "phase": "Queue ready",
            "summary": f"{queued} item(s) ready to encode",
            "overall_fraction": 0.0,
            "scan_fraction": 1.0,
            "encode_fraction": 0.0,
            "eta_seconds": eta,
        })

    store.mutate(ready)
    return plans, dvd_reports


def _session_progress(data: dict[str, Any]) -> tuple[float, float | None]:
    items = data["items"]
    weights = [
        max(float(item.get("duration") or 0), 1.0)
        for item in items
        if (
            item.get("selected", True)
            and item["status"] not in {"processed", "skipped", "cancelled"}
        )
    ]
    if not weights:
        return 1.0, 0.0
    total = sum(weights)
    completed = 0.0
    eta = 0.0
    for item in items:
        if (
            not item.get("selected", True)
            or item["status"] in {"processed", "skipped", "cancelled"}
        ):
            continue
        weight = max(float(item.get("duration") or 0), 1.0)
        fraction = (
            1.0 if item["status"] in {"complete", "error"}
            else float(item.get("progress") or 0)
        )
        completed += weight * fraction
        item_eta = item.get("eta_seconds")
        if item["status"] not in TERMINAL_ITEM_STATES and item_eta is not None:
            remaining = float(item_eta)
            if item["status"] not in {"encoding", "verifying", "paused"}:
                remaining *= 1 - fraction
            eta += max(0.0, remaining)
    return min(1.0, completed / total), eta


def _normalize_interrupted(store: SessionStore) -> None:
    def change(data: dict[str, Any]) -> None:
        if _pid_is_alive(data.get("worker_pid")):
            return
        for item in data["items"]:
            if item["status"] in {"encoding", "verifying"}:
                item.update({
                    "status": "ready",
                    "requested_action": None,
                    "progress": 0.0,
                    "encode_started_at_unix": None,
                    "message": "Interrupted item will restart from the beginning",
                })
                plan_data = item.get("plan")
                if plan_data and plan_data.get("output"):
                    output = Path(plan_data["output"])
                    partial = output.with_name(f".{output.stem}.part.mkv")
                    partial.unlink(missing_ok=True)
        data["worker_pid"] = None
        if data["status"] in {"running", "interrupted"}:
            data["status"] = "queued"
            data["phase"] = "Ready to resume"
        elif data.get("phase") == "Plan ready; start when convenient":
            data["phase"] = "Ready"

    store.mutate(change)


def _migrate_hidden_output_root(store: SessionStore) -> None:
    def change(data: dict[str, Any]) -> None:
        root = Path(data["root"])
        base = root.parent if root.is_file() else root
        old_root = (base / ".vidreclaim" / "output").resolve()
        settings = data.get("settings", {})
        configured = Path(
            settings.get("output_dir") or old_root
        ).expanduser().resolve()
        if configured != old_root:
            return
        new_root = (base / "VidReclaim Output").resolve()
        settings["output_dir"] = str(new_root)
        for item in data.get("items", []):
            if item.get("status") in {"complete", "processed"}:
                continue
            output_text = item.get("output")
            if output_text:
                try:
                    relative = Path(output_text).resolve().relative_to(old_root)
                except ValueError:
                    pass
                else:
                    item["output"] = str(new_root / relative)
            plan = item.get("plan")
            if not plan or not plan.get("output"):
                continue
            try:
                relative = Path(plan["output"]).resolve().relative_to(old_root)
            except ValueError:
                continue
            plan["output"] = str(new_root / relative)

    store.mutate(change)


def run_session(
    path: Path,
    *,
    start_encoding: bool | None = None,
) -> int:
    store = SessionStore(path)
    _migrate_hidden_output_root(store)
    _normalize_interrupted(store)
    session = store.read()
    if start_encoding is None:
        start_encoding = not bool(
            session.get("settings", {}).get("plan_only", False)
        )
    existing_pid = session.get("worker_pid")
    if (
        existing_pid
        and existing_pid != os.getpid()
        and _pid_is_alive(existing_pid)
    ):
        print(
            f"Queue worker {existing_pid} is already running for {store.path}",
            flush=True,
        )
        return 0
    if session["status"] in {"new", "scanning", "analyzing"} or not session["items"]:
        _prepare_session(store)
    session = store.read()
    settings = session["settings"]
    if settings.get("plan_only", False) and not start_encoding:
        def planned(data: dict[str, Any]) -> None:
            ready_count = sum(
                item["status"] == "ready" and item.get("selected", True)
                for item in data["items"]
            )
            data.update({
                "status": "paused" if ready_count else "complete",
                "phase": (
                    "Ready"
                    if ready_count
                    else "No files met the encode thresholds"
                ),
                "worker_pid": None,
                "summary": f"{ready_count} item(s) ready to encode",
            })

        store.mutate(planned)
        return 0

    if start_encoding:
        def activate_selected(data: dict[str, Any]) -> None:
            data["settings"]["plan_only"] = False
            for item in data["items"]:
                if (
                    item.get("selected", True)
                    and item["status"] in {"paused", "cancelled", "error"}
                    and item.get("plan")
                ):
                    plan_data = item["plan"]
                    if item["status"] == "error" and plan_data.get("output"):
                        output = Path(plan_data["output"])
                        output.with_name(
                            f".{output.stem}.part.mkv"
                        ).unlink(missing_ok=True)
                    item.update({
                        "status": "ready",
                        "requested_action": None,
                        "progress": 0.0,
                        "speed_x": None,
                        "message": "Ready to encode",
                    })

        store.mutate(activate_selected)

    session = store.read()
    runnable_count = sum(
        item["status"] in RUNNABLE_ITEM_STATES
        and item.get("selected", True)
        and item.get("plan") is not None
        for item in session["items"]
    )
    if runnable_count == 0:
        def nothing_to_start(data: dict[str, Any]) -> None:
            remaining = sum(
                item.get("selected", True)
                and item["status"] not in TERMINAL_ITEM_STATES
                for item in data["items"]
            )
            data.update({
                "status": "paused" if remaining else "complete",
                "phase": "No selected items are ready to encode",
                "worker_pid": None,
                "summary": "0 items ready to encode",
            })

        store.mutate(nothing_to_start)
        print("Queue: no selected items are ready to encode", flush=True)
        return 0

    print(
        f"Queue: starting {runnable_count} selected encode(s)",
        flush=True,
    )
    root = Path(session["root"])
    output_root = Path(settings["output_dir"])
    profile = PROFILES[settings["profile"]]

    def started(data: dict[str, Any]) -> None:
        data.update({
            "status": "running",
            "phase": "Encoding queue",
            "worker_pid": os.getpid(),
        })

    store.mutate(started)
    errors = 0
    while True:
        session = store.read()
        ready_items = sorted(
            (
                item for item in session["items"]
                if (
                    item["status"] in RUNNABLE_ITEM_STATES
                    and item.get("selected", True)
                )
            ),
            key=lambda item: item["order"],
        )
        if not ready_items:
            break
        item = ready_items[0]
        item_id = item["id"]
        plan = Plan.from_dict(item["plan"])
        label = item["name"]
        print(f"Queue: encoding {label}", flush=True)
        elapsed_base = float(item.get("encode_elapsed_seconds") or 0.0)
        active_since: float | None = time.monotonic()

        def elapsed_now() -> float:
            active = (
                time.monotonic() - active_since
                if active_since is not None else 0.0
            )
            return elapsed_base + active

        def update_elapsed_clock(action: str) -> None:
            nonlocal elapsed_base, active_since
            if action == "pause" and active_since is not None:
                elapsed_base += time.monotonic() - active_since
                active_since = None
            elif action == "run" and active_since is None:
                active_since = time.monotonic()

        _update_item(
            store,
            item_id,
            status="encoding",
            requested_action=None,
            progress=0.0,
            encode_started_at_unix=time.time(),
            message=(
                f"Sending to {settings.get('remote_host')}"
                if settings.get("remote_host") else "Encoding"
            ),
            transfer_progress=None,
        )

        def requested_action() -> str:
            current = store.read()
            latest = next(
                candidate for candidate in current["items"]
                if candidate["id"] == item_id
            )
            action = latest.get("requested_action") or "run"
            update_elapsed_clock(action)
            desired_status = "paused" if action == "pause" else "encoding"
            if latest["status"] != desired_status and action in {"pause", "run"}:
                _update_item(
                    store,
                    item_id,
                    status=desired_status,
                    encode_elapsed_seconds=elapsed_now(),
                    message="Paused" if action == "pause" else "Encoding",
                )
            return action

        def update_progress(fraction: float, speed: float | None) -> None:
            remaining = (
                plan.media.duration * (1 - fraction) / speed
                if speed and speed > 0 else item.get("eta_seconds")
            )
            _update_item(
                store,
                item_id,
                progress=min(1.0, max(0.0, fraction)),
                speed_x=speed,
                eta_seconds=remaining,
                encode_elapsed_seconds=elapsed_now(),
                message="Verifying" if fraction >= 1 else "Encoding",
                status="verifying" if fraction >= 1 else "encoding",
                transfer_progress=None,
            )
            snapshot = store.read()
            overall, eta = _session_progress(snapshot)

            def update_overall(data: dict[str, Any]) -> None:
                data["overall_fraction"] = overall
                data["encode_fraction"] = overall
                data["eta_seconds"] = eta

            store.mutate(update_overall)

        def update_stage(message: str) -> None:
            match = re.search(r"\((\d+)%\)$", message)
            transferring = message.startswith(("Uploading ", "Downloading "))
            _update_item(
                store,
                item_id,
                message=message,
                encode_elapsed_seconds=elapsed_now(),
                transfer_progress=(
                    min(1.0, max(0.0, int(match.group(1)) / 100))
                    if match else (0.0 if transferring else None)
                ),
            )

        try:
            if settings.get("delete_source_as_you_go") and plan.candidate:
                output_root.mkdir(parents=True, exist_ok=True)
                free = shutil.disk_usage(output_root).free
                required = round(plan.candidate.projected_bytes * 1.15)
                if free < required:
                    raise CommandError(
                        "Not enough free space for this output and safety margin"
                    )
            result = encode(
                root,
                plan,
                output_root=output_root,
                encoder=settings["encoder"],
                preset=settings["preset"],
                profile=profile,
                nice=settings["nice"],
                deep_verify=settings.get("deep_verify", False),
                min_savings_pct=settings.get("min_savings_pct"),
                progress=update_progress,
                control=requested_action,
                remote=(
                    config_from_settings(settings)
                    if plan.media.source.kind == "file" else None
                ),
                stage=update_stage,
            )
            result_data: dict[str, Any] = {
                "status": "complete",
                "progress": 1.0,
                "message": f"Verified; {result.actual_savings_pct:.1f}% smaller",
                "output": str(result.output),
                "actual_savings_pct": result.actual_savings_pct,
                "output_bytes": result.output_bytes,
                "processed": True,
                "completed_at_unix": time.time(),
                "encode_elapsed_seconds": elapsed_now(),
                "encode_started_at_unix": None,
                "requested_action": None,
                "speed_x": None,
                "eta_seconds": 0.0,
            }
            if settings.get("replace") and plan.media.source.kind == "file":
                archived, final = archive_and_replace_file(
                    root,
                    result,
                    archive_root=(
                        root.parent if root.is_file() else root
                    ) / ".reclaim-originals",
                )
                result_data.update({
                    "archived": str(archived),
                    "output": str(final),
                })
            elif (
                settings.get("delete_source_as_you_go")
                and plan.media.source.kind == "file"
            ):
                result_data["deleted_source"] = str(
                    delete_verified_file_source(result)
                )
            try:
                _save_processed_record(
                    root,
                    plan.media.source,
                    item=item,
                    result=result_data,
                )
            except OSError as error:
                result_data["message"] += (
                    f"; processed-history update failed: {error}"
                )
            _update_item(store, item_id, **result_data)
        except EncodeControl as controlled:
            _update_item(
                store,
                item_id,
                status="skipped" if controlled.action == "skip" else "cancelled",
                requested_action=None,
                progress=0.0,
                speed_x=None,
                eta_seconds=None,
                encode_elapsed_seconds=elapsed_now(),
                encode_started_at_unix=None,
                message=(
                    "Skipped by user"
                    if controlled.action == "skip"
                    else "Cancelled by user"
                ),
            )
        except (CommandError, OSError) as error:
            errors += 1
            _update_item(
                store,
                item_id,
                status="error",
                requested_action=None,
                speed_x=None,
                encode_elapsed_seconds=elapsed_now(),
                encode_started_at_unix=None,
                message=str(error),
            )

    if settings.get("replace") or settings.get("delete_source_as_you_go"):
        session = store.read()
        dvd_groups: dict[Path, list[dict[str, Any]]] = {}
        for queued_item in session["items"]:
            plan_data = queued_item.get("plan")
            if not plan_data:
                continue
            source_data = plan_data["media"]["source"]
            if source_data.get("kind") == "dvd":
                dvd_groups.setdefault(Path(source_data["path"]), []).append(queued_item)
        for video_ts, dvd_items in dvd_groups.items():
            if not dvd_items or any(item["status"] != "complete" for item in dvd_items):
                continue
            if not video_ts.exists():
                continue
            try:
                if settings.get("delete_source_as_you_go"):
                    handled = delete_verified_dvd_source(video_ts)
                    field = "deleted_dvd_source"
                    note = "DVD source deleted after all selected titles verified"
                else:
                    handled = archive_dvd(
                        root,
                        video_ts,
                        archive_root=(
                            root.parent if root.is_file() else root
                        ) / ".reclaim-originals",
                    )
                    field = "archived_dvd_source"
                    note = "DVD source archived after all selected titles verified"
                for dvd_item in dvd_items:
                    _update_item(
                        store,
                        dvd_item["id"],
                        **{field: str(handled), "message": note},
                    )
            except CommandError as error:
                errors += 1
                for dvd_item in dvd_items:
                    _update_item(
                        store,
                        dvd_item["id"],
                        status="error",
                        message=f"Output verified, but DVD source handling failed: {error}",
                    )

    session = store.read()
    paused = sum(
        item["status"] == "paused" and item.get("selected", True)
        for item in session["items"]
    )
    queued = sum(
        item["status"] == "ready" and item.get("selected", True)
        for item in session["items"]
    )
    completed = sum(item["status"] == "complete" for item in session["items"])
    errors = sum(
        item["status"] == "error" and item.get("selected", True)
        for item in session["items"]
    )
    status = "paused" if paused or queued else ("complete" if not errors else "attention")
    phase = "Paused; resume when ready" if status == "paused" else (
        "Queue complete" if status == "complete" else "Completed with errors"
    )

    def finished(data: dict[str, Any]) -> None:
        overall, eta = _session_progress(data)
        data.update({
            "status": status,
            "phase": phase,
            "worker_pid": None,
            "overall_fraction": overall,
            "scan_fraction": 1.0,
            "encode_fraction": overall,
            "eta_seconds": eta,
            "completed_count": completed,
            "error_count": errors,
            "summary": (
                f"{completed} complete, {paused} paused, "
                f"{errors} need attention"
            ),
        })

    store.mutate(finished)
    return 1 if errors else 0


def control_session(
    path: Path,
    *,
    action: str,
    item_id: str | None = None,
    item_ids: list[str] | None = None,
    folder: str | None = None,
) -> dict[str, Any]:
    store = SessionStore(path)

    def change(data: dict[str, Any]) -> None:
        items = data["items"]
        if action in {
            "clear-all",
            "clear-completed",
            "clear-cancelled",
            "clear-finished",
        } and (
            _pid_is_alive(data.get("worker_pid"))
            or any(
                item["status"] in {"encoding", "verifying"}
                for item in items
            )
        ):
            raise CommandError(
                "Cancel the running queue before clearing items",
            )
        requested_ids = set(item_ids or [])
        if item_id:
            requested_ids.add(item_id)

        def in_folder(item: dict[str, Any]) -> bool:
            if folder is None:
                return True
            normalized = folder.strip("/")
            candidate = str(item.get("relative_folder") or "").strip("/")
            return (
                not normalized
                or candidate == normalized
                or candidate.startswith(normalized + "/")
            )

        targets = [
            item for item in items
            if (not requested_ids or item["id"] in requested_ids)
            and in_folder(item)
        ]
        if (
            not requested_ids
            and folder is None
            and action in {"pause", "resume", "cancel", "skip"}
        ):
            targets = [
                item for item in targets if item.get("selected", True)
            ]
        missing = requested_ids - {item["id"] for item in targets}
        if missing:
            raise CommandError(
                f"Queue item not found: {sorted(missing)[0]}",
            )
        if action == "clear-all":
            data["items"] = []
            data.update({
                "status": "empty",
                "phase": "Queue cleared",
                "summary": "Queue is empty",
                "overall_fraction": 0.0,
                "scan_fraction": 0.0,
                "encode_fraction": 0.0,
                "eta_seconds": 0.0,
            })
            return
        if action in {"clear-completed", "clear-cancelled", "clear-finished"}:
            removable = {
                "clear-completed": {"complete", "processed"},
                "clear-cancelled": {"cancelled"},
                "clear-finished": TERMINAL_ITEM_STATES,
            }[action]
            data["items"] = [
                item for item in items if item["status"] not in removable
            ]
            for order, item in enumerate(
                sorted(data["items"], key=lambda value: value["order"]),
            ):
                item["order"] = order
            data["summary"] = f"{len(data['items'])} item(s) remain"
            overall, eta = _session_progress(data)
            data["overall_fraction"] = overall
            data["encode_fraction"] = overall
            data["eta_seconds"] = eta
            return
        if action in {"move-up", "move-down"}:
            if len(requested_ids) != 1:
                raise CommandError(f"{action} requires an item id")
            ordered = sorted(items, key=lambda item: item["order"])
            selected_id = next(iter(requested_ids))
            index = next(
                i for i, item in enumerate(ordered)
                if item["id"] == selected_id
            )
            other = index - 1 if action == "move-up" else index + 1
            if 0 <= other < len(ordered):
                ordered[index]["order"], ordered[other]["order"] = (
                    ordered[other]["order"],
                    ordered[index]["order"],
                )
            return
        selection_states = {"ready", "paused", "cancelled", "error"}
        if action == "only":
            if not requested_ids:
                raise CommandError("only requires at least one item id")
            for item in items:
                if item["status"] in selection_states:
                    item["selected"] = item["id"] in requested_ids
            targets = [item for item in items if item["id"] in requested_ids]
        elif action in {"include", "exclude"}:
            for item in targets:
                if item["status"] in selection_states:
                    item["selected"] = action == "include"
        for item in targets:
            status = item["status"]
            if action == "pause" and status in {"ready", "encoding"}:
                item["requested_action"] = "pause"
                item["status"] = "paused"
                item["message"] = "Paused"
            elif action == "resume" and status in {"paused", "cancelled", "error"}:
                if status == "error":
                    plan_data = item.get("plan")
                    if plan_data and plan_data.get("output"):
                        output = Path(plan_data["output"])
                        output.with_name(f".{output.stem}.part.mkv").unlink(
                            missing_ok=True
                    )
                item["requested_action"] = None
                item["status"] = "ready"
                item["selected"] = True
                item["progress"] = 0.0
                item["message"] = "Ready to resume"
            elif action in {"skip", "cancel"} and status not in TERMINAL_ITEM_STATES:
                item["requested_action"] = action
                if status != "encoding":
                    item["status"] = "skipped" if action == "skip" else "cancelled"
                    item["message"] = (
                        "Skipped by user" if action == "skip"
                        else "Cancelled by user"
                    )
        if action == "resume":
            data["status"] = "queued"
            data["phase"] = "Ready to resume"
        if action in {"include", "exclude", "only"}:
            included = sum(
                item.get("selected", True)
                and item["status"] not in {"complete", "processed", "skipped"}
                for item in items
            )
            data["summary"] = f"{included} item(s) included"
            data["eta_seconds"] = sum(
                float(
                    item.get("eta_seconds")
                    or item.get("projected_encode_seconds")
                    or 0
                )
                for item in items
                if (
                    item.get("selected", True)
                    and item["status"] not in TERMINAL_ITEM_STATES
                )
            )
            if any(
                item.get("selected", True) and item["status"] == "ready"
                for item in items
            ):
                data["status"] = "queued"
                data["phase"] = "Queue selection updated"
        overall, progress_eta = _session_progress(data)
        data["overall_fraction"] = overall
        data["encode_fraction"] = overall
        if action not in {"include", "exclude", "only"}:
            data["eta_seconds"] = progress_eta

    return store.mutate(change)
