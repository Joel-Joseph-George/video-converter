"""Unit tests for mkv_to_mp4 stream parsing, command generation, and file collection."""

from __future__ import annotations

from pathlib import Path
import tempfile
import unittest

import mkv_to_mp4 as mod


MAC_ENCODERS = mod.AvailableEncoders(
    aac_at=True,
    h264_videotoolbox=True,
    hevc_videotoolbox=True,
    prores_videotoolbox=True,
    libx264=True,
)


def _sample_bluray_json(
    video_codec: str = "hevc",
    pix_fmt: str = "yuv420p10le",
    r_fps: str = "24000/1001",
    avg_fps: str = "24000/1001",
    audio_streams: list[dict] | None = None,
    with_cover_art: bool = True,
    with_pgs_sub: bool = True,
) -> dict:
    streams: list[dict] = []
    idx = 0
    if with_cover_art:
        streams.append(
            {
                "index": idx,
                "codec_type": "video",
                "codec_name": "mjpeg",
                "disposition": {"attached_pic": 1},
            }
        )
        idx += 1

    streams.append(
        {
            "index": idx,
            "codec_type": "video",
            "codec_name": video_codec,
            "pix_fmt": pix_fmt,
            "width": 3840,
            "height": 2160,
            "r_frame_rate": r_fps,
            "avg_frame_rate": avg_fps,
            "disposition": {"attached_pic": 0},
        }
    )
    idx += 1

    for audio in audio_streams or []:
        entry = {"index": idx, "codec_type": "audio", **audio}
        streams.append(entry)
        idx += 1

    if with_pgs_sub:
        streams.append(
            {
                "index": idx,
                "codec_type": "subtitle",
                "codec_name": "hdmv_pgs_subtitle",
                "tags": {"language": "eng"},
            }
        )

    return {
        "format": {"size": str(15 * 1024**3), "duration": "7200.0"},
        "streams": streams,
        "chapters": [{"id": 0}, {"id": 1}],
    }


class TestMkvToMp4(unittest.TestCase):
    """Tests for Blu-ray MKV parsing and conversion planning."""

    def test_ignores_cover_art_and_applies_hvc1_for_hevc(self) -> None:
        raw = _sample_bluray_json(
            video_codec="hevc",
            audio_streams=[
                {
                    "codec_name": "dts",
                    "channels": 6,
                    "channel_layout": "5.1(side)",
                    "tags": {"language": "eng"},
                },
                {
                    "codec_name": "aac",
                    "channels": 2,
                    "channel_layout": "stereo",
                    "tags": {"language": "eng"},
                },
            ],
        )
        probe = mod.parse_probe_data(raw, Path("/movies/film.mkv"))
        self.assertIsNotNone(probe.video)
        assert probe.video is not None
        self.assertEqual(probe.video.index, 1)
        self.assertEqual(probe.video.codec_name, "hevc")
        self.assertFalse(probe.video.is_vfr)

        plan = mod.build_plan(probe, mod.ConvertOptions(), MAC_ENCODERS, ffmpeg_bin="ffmpeg")
        self.assertTrue(plan.can_proceed)
        self.assertFalse(plan.requires_video_transcode)
        cmd = plan.command
        self.assertIn("0:1", cmd)
        self.assertIn("-tag:v:0", cmd)
        self.assertIn("hvc1", cmd)
        self.assertIn("-c:v:0", cmd)
        self.assertIn("copy", cmd)
        # First audio (DTS 5.1(side)) converts cleanly with channelmap + aac_at; second (AAC) copies.
        self.assertIn("aac_at", cmd)
        self.assertIn("channelmap=channel_layout=5.1", cmd)
        self.assertIn("-c:a:1", cmd)
        self.assertIn("-sn", cmd)
        self.assertIn("+faststart", cmd)

    def test_71_surround_uses_native_aac_fallback(self) -> None:
        raw = _sample_bluray_json(
            video_codec="h264",
            pix_fmt="yuv420p",
            audio_streams=[
                {
                    "codec_name": "truehd",
                    "channels": 8,
                    "channel_layout": "7.1",
                    "tags": {"language": "eng"},
                }
            ],
        )
        probe = mod.parse_probe_data(raw, Path("/movies/atmos.mkv"))
        plan = mod.build_plan(probe, mod.ConvertOptions(), MAC_ENCODERS)
        self.assertTrue(plan.can_proceed)
        self.assertNotIn("hvc1", plan.command)
        self.assertIn("aformat=channel_layouts=7.1", plan.command)
        self.assertIn("640k", plan.command)
        self.assertNotIn("aac_at", plan.command)

    def test_ac3_converts_by_default_for_fcp_safety(self) -> None:
        raw = _sample_bluray_json(
            audio_streams=[
                {
                    "codec_name": "ac3",
                    "channels": 6,
                    "channel_layout": "5.1",
                    "tags": {"language": "eng"},
                }
            ]
        )
        probe = mod.parse_probe_data(raw, Path("/movies/ac3.mkv"))
        default_plan = mod.build_plan(probe, mod.ConvertOptions(), MAC_ENCODERS)
        self.assertIn("aac_at", default_plan.command)

        copy_plan = mod.build_plan(probe, mod.ConvertOptions(copy_ac3=True), MAC_ENCODERS)
        c_idx = copy_plan.command.index("-c:a:0")
        self.assertEqual(copy_plan.command[c_idx + 1], "copy")

    def test_mov_mode_uses_lossless_pcm_and_no_faststart(self) -> None:
        raw = _sample_bluray_json(
            audio_streams=[
                {
                    "codec_name": "dts",
                    "channels": 6,
                    "channel_layout": "5.1(side)",
                    "tags": {"language": "eng"},
                }
            ]
        )
        probe = mod.parse_probe_data(raw, Path("/movies/film.mkv"))
        plan = mod.build_plan(probe, mod.ConvertOptions(container="mov"), MAC_ENCODERS)
        self.assertTrue(plan.can_proceed)
        self.assertEqual(plan.output_path.suffix, ".mov")
        self.assertIn("pcm_s24le", plan.command)
        self.assertNotIn("+faststart", plan.command)

    def test_audio_language_filter_and_stereo_downmix(self) -> None:
        raw = _sample_bluray_json(
            audio_streams=[
                {"codec_name": "dts", "channels": 6, "channel_layout": "5.1", "tags": {"language": "jpn"}},
                {"codec_name": "ac3", "channels": 6, "channel_layout": "5.1", "tags": {"language": "eng"}},
            ]
        )
        probe = mod.parse_probe_data(raw, Path("/movies/anime.mkv"))
        plan = mod.build_plan(
            probe,
            mod.ConvertOptions(audio_langs=("eng",), stereo=True),
            MAC_ENCODERS,
        )
        self.assertEqual(len(plan.audio_actions), 1)
        # Index 0 is cover art, index 1 is video, index 2 is jpn audio, index 3 is eng audio.
        self.assertIn("0:3", plan.command)
        self.assertNotIn("0:2", [tok for tok in plan.command if tok.startswith("0:")])
        self.assertIn("-ac:a:0", plan.command)
        self.assertIn("2", plan.command)

    def test_incompatible_vc1_blocks_without_allow_transcode(self) -> None:
        raw = _sample_bluray_json(
            video_codec="vc1",
            audio_streams=[{"codec_name": "dts", "channels": 6, "channel_layout": "5.1"}],
        )
        probe = mod.parse_probe_data(raw, Path("/movies/old_bluray.mkv"))
        blocked = mod.build_plan(probe, mod.ConvertOptions(), MAC_ENCODERS)
        self.assertFalse(blocked.can_proceed)
        self.assertTrue(blocked.requires_video_transcode)
        self.assertIn("--allow-transcode", blocked.skip_reason or "")

        allowed = mod.build_plan(probe, mod.ConvertOptions(allow_transcode=True), MAC_ENCODERS)
        self.assertTrue(allowed.can_proceed)
        self.assertIn("hevc_videotoolbox", allowed.command)

    def test_vfr_detection_flags_warning(self) -> None:
        raw = _sample_bluray_json(r_fps="60/1", avg_fps="47.5/1", audio_streams=[])
        probe = mod.parse_probe_data(raw, Path("/movies/vfr.mkv"))
        assert probe.video is not None
        self.assertTrue(probe.video.is_vfr)
        plan = mod.build_plan(probe, mod.ConvertOptions(), MAC_ENCODERS)
        self.assertTrue(any("Variable Frame Rate" in w for w in plan.warnings))

    def test_collect_inputs_skips_macos_appledouble_files(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            valid = root / "movie.mkv"
            ghost = root / "._movie.mkv"
            other = root / "notes.txt"
            nested = root / "sub" / "part2.MKV"
            nested.parent.mkdir()
            for f in (valid, ghost, other, nested):
                f.write_bytes(b"")

            non_rec = mod.collect_inputs([root], recursive=False)
            self.assertEqual(non_rec, [valid.resolve()])

            rec = mod.collect_inputs([root], recursive=True)
            self.assertEqual(rec, [valid.resolve(), nested.resolve()])

    def test_parse_progress_time_sec(self) -> None:
        self.assertAlmostEqual(mod.parse_progress_time_sec("out_time_us", "12500000") or 0.0, 12.5)
        self.assertAlmostEqual(mod.parse_progress_time_sec("out_time", "01:02:03.500") or 0.0, 3723.5)
        self.assertIsNone(mod.parse_progress_time_sec("out_time_us", "N/A"))
        self.assertIsNone(mod.parse_progress_time_sec("bitrate", "1234kbits/s"))


if __name__ == "__main__":
    unittest.main()
