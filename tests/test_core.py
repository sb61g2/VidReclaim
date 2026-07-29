from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from vidreclaim.discovery import discover
from vidreclaim.dvd import DvdTitle, _extract_json, select_main_titles
from vidreclaim.model import Candidate, MediaInfo, Plan, PROFILES, Source
from vidreclaim.planner import (
    analyze_fast,
    base_crf,
    candidate_dimensions,
    sample_offsets,
)
from vidreclaim.queueing import (
    SessionStore,
    _load_processed_catalog,
    _normalize_interrupted,
    _processed_record,
    _save_processed_record,
    _scan_progress_fraction,
    _source_signature,
    _what_if_estimates,
    control_session,
    create_session,
)
from vidreclaim.review import _render_html, build_review_assets
from vidreclaim.runner import EncodeControl, _stream_command, output_path
from vidreclaim.runner import (
    EncodeResult,
    delete_verified_dvd_source,
    delete_verified_file_source,
)
from vidreclaim.stitch import StitchSettings, canvas_dimensions, natural_key, stitch
from vidreclaim.space import SpaceNode, scan_space, write_space_json


def dvd_title(index: int, minutes: float) -> DvdTitle:
    return DvdTitle(index, minutes * 60, 720, 480, 29.97, 1, 0, {})


def media(path: Path, width: int = 3840, height: int = 2160) -> MediaInfo:
    return MediaInfo(
        source=Source(path),
        size_bytes=1_000_000_000,
        duration=3600,
        bit_rate=2_222_222,
        video_bit_rate=2_000_000,
        nonvideo_bit_rate=222_222,
        codec="h264",
        profile="High",
        width=width,
        height=height,
        fps=24,
        pix_fmt="yuv420p",
        bit_depth=8,
        field_order="progressive",
        audio_streams=1,
        subtitle_streams=0,
    )


class DvdSelectionTests(unittest.TestCase):
    def test_movie_keeps_dominant_feature(self) -> None:
        titles = [dvd_title(1, 121), dvd_title(2, 24), dvd_title(3, 3)]
        self.assertEqual([1], [item.index for item in select_main_titles(titles)])

    def test_episodic_disc_keeps_similar_cluster(self) -> None:
        titles = [
            dvd_title(1, 44), dvd_title(2, 43), dvd_title(3, 45),
            dvd_title(4, 8), dvd_title(5, 20),
        ]
        self.assertEqual(
            [1, 2, 3],
            [item.index for item in select_main_titles(titles)],
        )

    def test_short_disc_falls_back_to_longest(self) -> None:
        titles = [dvd_title(1, 8), dvd_title(2, 4)]
        self.assertEqual([1], [item.index for item in select_main_titles(titles)])

    def test_handbrake_json_marker_is_parsed(self) -> None:
        payload = {"TitleList": [{"Index": 1}]}
        parsed = _extract_json(
            "log noise\nJSON Title Set: " + json.dumps(payload) + "\nmore logs"
        )
        self.assertEqual(payload, parsed)


class PlannerTests(unittest.TestCase):
    def test_samples_are_spread_across_runtime(self) -> None:
        self.assertEqual([89.25, 297.5, 505.75], sample_offsets(605, 10, 3))

    def test_short_video_has_one_sample(self) -> None:
        self.assertEqual([0.0], sample_offsets(8, 10, 3))

    def test_4k_gets_native_and_1080_candidates(self) -> None:
        info = media(Path("/tmp/movie.mkv"))
        self.assertEqual([(3840, 2160), (1920, 1080)], candidate_dimensions(info))

    def test_1080_stays_native(self) -> None:
        info = media(Path("/tmp/movie.mkv"), 1920, 1080)
        self.assertEqual([(1920, 1080)], candidate_dimensions(info))

    def test_resolution_quality_defaults(self) -> None:
        self.assertEqual(20, base_crf(480))
        self.assertEqual(22, base_crf(1080))
        self.assertEqual(24, base_crf(2160))

    def test_fast_analysis_preserves_crisp_4k(self) -> None:
        info = media(Path("/tmp/crisp.mkv"))
        info.video_bit_rate = 20_000_000
        info.bit_rate = 20_222_222
        info.size_bytes = round(info.bit_rate * info.duration / 8)
        plan = analyze_fast(
            info,
            profile=PROFILES["balanced"],
            min_reclaim_bytes=100 * 1024 * 1024,
        )
        self.assertEqual("encode", plan.status)
        self.assertEqual((3840, 2160), (plan.candidate.width, plan.candidate.height))

    def test_plan_round_trips_from_persistent_json(self) -> None:
        info = media(Path("/tmp/movie.mkv"), 1920, 1080)
        plan = analyze_fast(
            info,
            profile=PROFILES["balanced"],
            min_reclaim_bytes=10,
        )
        restored = Plan.from_dict(plan.to_dict())
        self.assertEqual(plan.media.source.path, restored.media.source.path)
        self.assertEqual(plan.status, restored.status)
        self.assertEqual(plan.candidate, restored.candidate)


class DiscoveryAndOutputTests(unittest.TestCase):
    def test_video_ts_is_one_dvd_not_loose_vobs(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            video_ts = root / "Disc" / "VIDEO_TS"
            video_ts.mkdir(parents=True)
            (video_ts / "VTS_01_1.VOB").write_bytes(b"vob")
            (root / "clip.mp4").write_bytes(b"mp4")
            found = list(discover(root))
        self.assertEqual(2, len(found))
        self.assertEqual(1, sum(item.kind == "dvd" for item in found))
        self.assertFalse(any(item.path.suffix.lower() == ".vob" for item in found))

    def test_single_file_output_uses_output_directory(self) -> None:
        source = Path("/tmp/source/movie.mp4")
        info = media(source, 1920, 1080)
        candidate = Candidate(1920, 1080, 22)
        plan = Plan(info, "encode", "test", candidate=candidate)
        self.assertEqual(
            Path("/tmp/output/movie.mkv"),
            output_path(source, plan, Path("/tmp/output")),
        )

    def test_explicit_delete_helpers_are_narrowly_scoped(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "movie.mp4"
            output = root / "movie.mkv"
            source.write_bytes(b"source")
            output.write_bytes(b"output")
            info = media(source, 1920, 1080)
            candidate = Candidate(1920, 1080, 22)
            plan = Plan(info, "encode", "test", candidate=candidate)
            result = EncodeResult(plan, output, output.stat().st_size, 50, True)
            delete_verified_file_source(result)
            self.assertFalse(source.exists())
            self.assertTrue(output.exists())

            video_ts = root / "Disc" / "VIDEO_TS"
            video_ts.mkdir(parents=True)
            (video_ts / "VTS_01_1.VOB").write_bytes(b"video")
            delete_verified_dvd_source(video_ts)
            self.assertFalse(video_ts.exists())
            self.assertTrue(video_ts.parent.exists())


class ReviewTests(unittest.TestCase):
    def test_review_contains_slider_and_decision_control(self) -> None:
        page = _render_html([{
            "plan_index": 0,
            "name": "Movie",
            "path": "/media/Movie.mkv",
            "source": "H.264",
            "output": "HEVC",
            "pairs": [{
                "before": "before.jpg",
                "after": "after.jpg",
                "time": "0:10:00",
            }],
        }])
        self.assertIn('type="range"', page)
        self.assertIn('name="approve"', page)
        self.assertIn("before.jpg", page)
        self.assertIn("after.jpg", page)

    def test_review_assets_can_target_selected_plan_indices(self) -> None:
        first_candidate = Candidate(1920, 1080, 22)
        second_candidate = Candidate(1920, 1080, 22)
        plans = [
            Plan(
                media(Path("/media/first.mkv"), 1920, 1080),
                "encode",
                "test",
                candidate=first_candidate,
                candidates=[first_candidate],
            ),
            Plan(
                media(Path("/media/second.mkv"), 1920, 1080),
                "encode",
                "test",
                candidate=second_candidate,
                candidates=[second_candidate],
            ),
        ]
        with tempfile.TemporaryDirectory() as temporary:
            cards = build_review_assets(
                plans,
                session_dir=Path(temporary),
                sample_seconds=10,
                plan_indices={1},
            )
        self.assertEqual([1], [card["plan_index"] for card in cards])

    def test_still_frame_review_uses_fast_selected_snapshots(self) -> None:
        candidate = Candidate(1920, 1080, 22)
        plan = Plan(
            media(Path("/media/movie.mkv"), 1920, 1080),
            "encode",
            "test",
            candidate=candidate,
            candidates=[candidate],
        )
        with (
            tempfile.TemporaryDirectory() as temporary,
            mock.patch("vidreclaim.review._snapshot") as snapshot,
            mock.patch(
                "vidreclaim.review._encode_review_frame",
            ) as encode_frame,
        ):
            cards = build_review_assets(
                [plan],
                session_dir=Path(temporary),
                sample_seconds=10,
                mode="frames",
                sample_count=2,
            )
        self.assertEqual(2, len(cards[0]["pairs"]))
        self.assertEqual(2, encode_frame.call_count)
        self.assertEqual(4, snapshot.call_count)


class StitchTests(unittest.TestCase):
    def test_natural_order_places_clip_2_before_clip_10(self) -> None:
        paths = [Path("clip10.mp4"), Path("clip2.mp4"), Path("clip1.mp4")]
        self.assertEqual(
            ["clip1.mp4", "clip2.mp4", "clip10.mp4"],
            [path.name for path in sorted(paths, key=natural_key)],
        )

    def test_canvas_can_follow_first_or_largest(self) -> None:
        first = media(Path("/tmp/first.mp4"), 1280, 720)
        second = media(Path("/tmp/second.mp4"), 1920, 1080)
        self.assertEqual((1280, 720), canvas_dimensions([first, second], "first"))
        self.assertEqual((1920, 1080), canvas_dimensions([first, second], "largest"))

    def test_mixed_dynamic_range_splits_into_named_outputs(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            sdr_path = root / "clip-sdr.mp4"
            hdr_path = root / "clip-hdr.mp4"
            sdr_path.touch()
            hdr_path.touch()
            sdr = media(sdr_path, 1920, 1080)
            hdr = media(hdr_path, 3840, 2160)
            hdr.hdr = True
            with (
                mock.patch(
                    "vidreclaim.stitch.probe_file",
                    side_effect=[sdr, hdr],
                ),
                mock.patch(
                    "vidreclaim.stitch._stitch_prepared",
                    side_effect=lambda paths, media, output, **_: output,
                ),
            ):
                outputs = stitch(
                    [sdr_path, hdr_path],
                    root / "combined.mkv",
                    settings=StitchSettings(mixed_dynamic_range="split"),
                )
        self.assertEqual(
            ["combined-sdr.mkv", "combined-hdr.mkv"],
            [path.name for path in outputs],
        )


class SpaceMapTests(unittest.TestCase):
    def test_scan_aggregates_files_and_deduplicates_hardlinks(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "A").mkdir()
            original = root / "A" / "movie.mkv"
            original.write_bytes(b"x" * 10_000)
            (root / "small.txt").write_bytes(b"x" * 100)
            (root / "movie-link.mkv").hardlink_to(original)
            scanned, stats = scan_space([root], allocated=False)
        self.assertEqual(2, scanned.files)
        self.assertEqual(2, stats.files)
        self.assertEqual(10_100, scanned.size)

    def test_structured_report_keeps_the_complete_tree(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "space.json"
            children = [
                SpaceNode(f"movie-{index}.mkv", f"/media/{index}", "video", 1)
                for index in range(200)
            ]
            root = SpaceNode(
                "Scanned locations", "", "root",
                size=200, files=200, children=children,
            )
            write_space_json(root, output, allocated=False)
            report = json.loads(output.read_text(encoding="utf-8"))
        self.assertEqual(200, len(report["root"]["children"]))


class QueueTests(unittest.TestCase):
    def test_scan_progress_tracks_metadata_and_analysis_stages(self) -> None:
        data = {
            "items": [
                {"status": "probing", "progress": 0.0},
                {"status": "analyzing", "progress": 0.5},
                {"status": "ready", "progress": 0.0},
            ],
        }
        self.assertAlmostEqual(
            _scan_progress_fraction(data),
            (0.0 + 0.75 + 1.0) / 3.0,
        )

    def settings(self, root: Path) -> dict[str, object]:
        return {
            "profile": "balanced",
            "min_savings_pct": 20,
            "min_reclaim_mb": 100,
            "sample_seconds": 10,
            "samples": 3,
            "encoder": "x265",
            "preset": "medium",
            "nice": 10,
            "keep_dvd_extras": False,
            "dvd_min_title_minutes": 10,
            "thorough_analysis": False,
            "scan_workers": 6,
            "visual_review": False,
            "deep_verify": False,
            "replace": False,
            "delete_source_as_you_go": False,
            "output_dir": str(root / ".vidreclaim" / "output"),
        }

    def test_queue_control_pauses_resumes_and_reorders(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            path = root / "session.json"
            create_session(path, root=root, settings=self.settings(root))
            store = SessionStore(path)

            def add_items(data: dict[str, object]) -> None:
                data["status"] = "queued"
                data["items"] = [
                    {"id": "a", "order": 0, "status": "ready"},
                    {"id": "b", "order": 1, "status": "ready"},
                ]

            store.mutate(add_items)
            control_session(path, action="pause", item_id="a")
            self.assertEqual("paused", store.read()["items"][0]["status"])
            control_session(path, action="resume", item_id="a")
            self.assertEqual("ready", store.read()["items"][0]["status"])
            control_session(path, action="move-down", item_id="a")
            items = sorted(store.read()["items"], key=lambda item: item["order"])
            self.assertEqual(["b", "a"], [item["id"] for item in items])

    def test_folder_selection_only_mode_and_cleanup(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            path = root / "session.json"
            create_session(path, root=root, settings=self.settings(root))
            store = SessionStore(path)

            def add_items(data: dict[str, object]) -> None:
                data["status"] = "queued"
                data["items"] = [
                    {
                        "id": "episode-a", "order": 0, "status": "ready",
                        "relative_folder": "Shows/Season 1", "selected": True,
                    },
                    {
                        "id": "episode-b", "order": 1, "status": "ready",
                        "relative_folder": "Shows/Season 2", "selected": True,
                    },
                    {
                        "id": "movie", "order": 2, "status": "ready",
                        "relative_folder": "Movies", "selected": True,
                    },
                    {
                        "id": "done", "order": 3, "status": "complete",
                        "relative_folder": "Movies", "selected": True,
                    },
                ]

            store.mutate(add_items)
            control_session(path, action="exclude", folder="Shows")
            selected = {
                item["id"]: item.get("selected")
                for item in store.read()["items"]
            }
            self.assertFalse(selected["episode-a"])
            self.assertFalse(selected["episode-b"])
            self.assertTrue(selected["movie"])

            control_session(
                path, action="only", item_ids=["episode-b", "movie"],
            )
            selected = {
                item["id"]: item.get("selected")
                for item in store.read()["items"]
            }
            self.assertFalse(selected["episode-a"])
            self.assertTrue(selected["episode-b"])
            self.assertTrue(selected["movie"])

            control_session(path, action="cancel", item_ids=["movie"])
            control_session(path, action="clear-cancelled")
            self.assertNotIn(
                "movie", {item["id"] for item in store.read()["items"]},
            )
            control_session(path, action="clear-completed")
            self.assertNotIn(
                "done", {item["id"] for item in store.read()["items"]},
            )
            control_session(path, action="clear-all")
            self.assertEqual([], store.read()["items"])

    def test_processed_catalog_requires_unchanged_media_and_output(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source_path = root / "movie.mkv"
            output = root / ".vidreclaim" / "output" / "movie.mkv"
            source_path.write_bytes(b"source")
            output.parent.mkdir(parents=True)
            output.write_bytes(b"result")
            source = Source(source_path)
            catalog_path = root / "processed.json"
            item = {
                "source_signature": _source_signature(source),
                "source_bytes": source_path.stat().st_size,
            }
            result = {
                "output": str(output),
                "output_bytes": output.stat().st_size,
                "actual_savings_pct": 10.0,
                "encode_elapsed_seconds": 12.0,
                "completed_at_unix": 1.0,
            }
            with mock.patch.dict(
                "os.environ",
                {"VIDRECLAIM_CATALOG_PATH": str(catalog_path)},
            ):
                _save_processed_record(
                    root, source, item=item, result=result,
                )
                catalog = _load_processed_catalog()
                self.assertIsNotNone(
                    _processed_record(root, source, catalog),
                )
                self.assertIsNotNone(
                    _processed_record(root, Source(output), catalog),
                )
                source_path.write_bytes(b"changed source")
                self.assertIsNone(
                    _processed_record(root, source, catalog),
                )

    def test_interrupted_encode_becomes_resumable(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            path = root / "session.json"
            create_session(path, root=root, settings=self.settings(root))
            store = SessionStore(path)

            def interrupt(data: dict[str, object]) -> None:
                data["status"] = "running"
                data["worker_pid"] = 999_999_999
                data["items"] = [{
                    "id": "a",
                    "order": 0,
                    "status": "encoding",
                    "requested_action": None,
                    "progress": 0.7,
                    "message": "Encoding",
                    "plan": None,
                }]

            store.mutate(interrupt)
            _normalize_interrupted(store)
            item = store.read()["items"][0]
            self.assertEqual("ready", item["status"])
            self.assertEqual(0.0, item["progress"])

    def test_streamed_encoder_honors_cancel_control(self) -> None:
        actions = iter(["run", "cancel"])

        def control() -> str:
            return next(actions, "cancel")

        with self.assertRaises(EncodeControl):
            _stream_command(
                [
                    sys.executable,
                    "-u",
                    "-c",
                    "import time\nwhile True:\n print('tick', flush=True)\n time.sleep(.1)",
                ],
                nice=0,
                on_line=lambda _: None,
                control=control,
            )

    def test_what_if_matrix_is_instant_and_marks_current_choice(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            settings = self.settings(root)
            info = media(root / "movie.mkv", 1920, 1080)
            info.video_bit_rate = 8_000_000
            info.bit_rate = 8_222_222
            info.size_bytes = round(info.bit_rate * info.duration / 8)
            estimates = _what_if_estimates(
                info, settings,
            )
        self.assertEqual(12, len(estimates))
        self.assertEqual(1, sum(item["selected"] for item in estimates))
        balanced = {
            item["encoder_label"]: item
            for item in estimates if item["profile"] == "balanced"
        }
        self.assertLess(
            balanced["M4 hardware"]["encode_seconds"],
            balanced["x265 · Medium"]["encode_seconds"],
        )
        self.assertGreater(
            balanced["M4 hardware"]["projected_bytes"],
            balanced["x265 · Medium"]["projected_bytes"],
        )


if __name__ == "__main__":
    unittest.main()
