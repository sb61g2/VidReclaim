from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

from vidreclaim.discovery import discover
from vidreclaim.dvd import DvdTitle, _extract_json, select_main_titles
from vidreclaim.model import Candidate, MediaInfo, Plan, Source
from vidreclaim.planner import base_crf, candidate_dimensions, sample_offsets
from vidreclaim.review import _render_html
from vidreclaim.runner import output_path
from vidreclaim.runner import (
    EncodeResult,
    delete_verified_dvd_source,
    delete_verified_file_source,
)
from vidreclaim.stitch import canvas_dimensions, natural_key
from vidreclaim.space import scan_space


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


if __name__ == "__main__":
    unittest.main()
