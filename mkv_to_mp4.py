#!/usr/bin/env python3
"""Smart lossless-first MKV to MP4/MOV converter for Final Cut Pro & DaVinci Resolve.

Designed for large (10-20+ GB) Blu-ray and film MKV files on macOS Apple Silicon:
- Inspects streams with ffprobe before converting.
- Copies H.264 / HEVC video bit-for-bit (-c:v copy) with zero quality loss.
- Automatically applies -tag:v hvc1 for HEVC so Final Cut Pro & Resolve import cleanly.
- Converts NLE-incompatible audio (DTS, TrueHD, FLAC, AC-3, E-AC-3) to high-bitrate
  AAC (for .mp4) or lossless 24-bit PCM (for .mov) while copying AAC untouched.
- Safely drops Blu-ray PGS/VobSub subtitles from MP4 (with optional sidecar export).
- Writes atomically to a temporary file and checks free disk space beforehand.
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass, field
import json
import math
import os
from pathlib import Path
import shlex
import shutil
import signal
import subprocess
import sys
import time
from typing import Any


EDITOR_COPY_VIDEO_CODECS = {"h264", "hevc"}
TRANSCODE_REQUIRED_VIDEO_CODECS = {"vc1", "mpeg2video", "vp9", "vp8", "theora", "av1"}
IMAGE_SUBTITLE_EXTS = {
    "hdmv_pgs_subtitle": ".sup",
    "dvd_subtitle": ".sub",
}
TEXT_SUBTITLE_EXTS = {
    "subrip": ".srt",
    "srt": ".srt",
    "ass": ".ass",
    "ssa": ".ssa",
    "webvtt": ".vtt",
    "mov_text": ".srt",
}
COVER_ART_CODECS = {"mjpeg", "png", "bmp", "webp", "gif"}


@dataclass(frozen=True)
class ToolPaths:
    """Resolved paths to ffmpeg and ffprobe executables."""

    ffmpeg: str
    ffprobe: str


@dataclass(frozen=True)
class AvailableEncoders:
    """Encoder capabilities detected from the installed ffmpeg binary."""

    aac_at: bool = False
    h264_videotoolbox: bool = False
    hevc_videotoolbox: bool = False
    prores_videotoolbox: bool = False
    libx264: bool = False


@dataclass(frozen=True)
class VideoStream:
    """Metadata for the primary video stream in an MKV."""

    index: int
    codec_name: str
    pix_fmt: str
    width: int
    height: int
    r_frame_rate: str
    avg_frame_rate: str
    is_vfr: bool
    has_dolby_vision: bool
    color_transfer: str


@dataclass(frozen=True)
class AudioStream:
    """Metadata for an audio stream in an MKV."""

    index: int
    codec_name: str
    channels: int
    channel_layout: str
    language: str
    title: str


@dataclass(frozen=True)
class SubtitleStream:
    """Metadata for a subtitle stream in an MKV."""

    index: int
    codec_name: str
    language: str
    title: str


@dataclass(frozen=True)
class ProbeResult:
    """Parsed ffprobe inspection result for a single input file."""

    path: Path
    size_bytes: int
    duration_sec: float
    video: VideoStream | None
    audio_streams: list[AudioStream]
    subtitle_streams: list[SubtitleStream]
    chapter_count: int


@dataclass(frozen=True)
class ConvertOptions:
    """CLI options governing how conversion commands are constructed."""

    container: str = "mp4"
    output_dir: Path | None = None
    audio_langs: tuple[str, ...] = ()
    first_audio: bool = False
    stereo: bool = False
    copy_ac3: bool = False
    faststart: bool = True
    extract_subs: bool = False
    allow_transcode: bool = False
    prores: bool = False
    keep_chapters: bool = True
    overwrite: bool = False
    inspect_only: bool = False
    dry_run: bool = False
    progress_json: bool = False


@dataclass
class ConversionPlan:
    """Complete execution plan and diagnostics for converting one MKV."""

    input_path: Path
    output_path: Path
    temp_path: Path
    can_proceed: bool
    requires_video_transcode: bool
    video_action: str
    audio_actions: list[str] = field(default_factory=list)
    warnings: list[str] = field(default_factory=list)
    skip_reason: str | None = None
    command: list[str] = field(default_factory=list)
    selected_subtitles: list[SubtitleStream] = field(default_factory=list)


def format_bytes(num_bytes: int) -> str:
    """Format byte counts into readable GiB/MiB strings."""
    value = float(num_bytes)
    for unit in ("B", "KiB", "MiB", "GiB", "TiB"):
        if value < 1024.0 or unit == "TiB":
            return f"{value:.2f} {unit}" if unit != "B" else f"{int(value)} B"
        value /= 1024.0
    return f"{value:.2f} TiB"


def format_duration(seconds: float) -> str:
    """Format duration in seconds into HH:MM:SS."""
    total = max(0, int(round(seconds)))
    hours, rem = divmod(total, 3600)
    minutes, secs = divmod(rem, 60)
    return f"{hours:02d}:{minutes:02d}:{secs:02d}"


def _parse_rate(rate_str: str) -> float | None:
    """Parse an ffprobe fractional rate string like '24000/1001' or '29.97'."""
    if not rate_str or rate_str in {"0/0", "N/A"}:
        return None
    try:
        if "/" in rate_str:
            num_str, den_str = rate_str.split("/", 1)
            den = float(den_str)
            if den == 0:
                return None
            val = float(num_str) / den
        else:
            val = float(rate_str)
    except ValueError:
        return None
    if not math.isfinite(val) or val <= 0:
        return None
    return val


def detect_vfr(r_frame_rate: str, avg_frame_rate: str) -> bool:
    """Return True if nominal and average frame rates diverge noticeably."""
    r_fps = _parse_rate(r_frame_rate)
    avg_fps = _parse_rate(avg_frame_rate)
    if r_fps is None or avg_fps is None:
        return False
    return abs(r_fps - avg_fps) / max(r_fps, avg_fps) > 0.02


def find_ffmpeg_tools(script_dir: Path | None = None) -> ToolPaths:
    """Locate ffmpeg and ffprobe across PATH and standard macOS/local locations."""
    base = script_dir or Path(__file__).resolve().parent
    env_bin = os.environ.get("MKV_TO_MP4_BIN_DIR", "")
    search_dirs = [
        env_bin,
        str(base / "bin"),
        str(Path.home() / "Library" / "Application Support" / "Video Converter" / "bin"),
        str(Path.home() / "Library" / "Application Support" / "MKV to MP4" / "bin"),
        "/opt/homebrew/bin",
        "/usr/local/bin",
        str(Path.home() / ".local" / "bin"),
        os.environ.get("PATH", ""),
    ]
    search_path = os.pathsep.join(d for d in search_dirs if d)
    ffmpeg = shutil.which("ffmpeg", path=search_path)
    ffprobe = shutil.which("ffprobe", path=search_path)
    if not ffmpeg or not ffprobe:
        missing = [name for name, val in (("ffmpeg", ffmpeg), ("ffprobe", ffprobe)) if not val]
        raise FileNotFoundError(
            f"Missing required tool(s): {', '.join(missing)}.\n"
            "Install on Apple Silicon macOS using one of:\n"
            "  1. Homebrew: brew install ffmpeg\n"
            "  2. Zero-Homebrew native arm64 builds from https://ffmpeg.martin-riedl.de\n"
            f"     (place 'ffmpeg' and 'ffprobe' in '{base / 'bin'}' or '/usr/local/bin')"
        )
    return ToolPaths(ffmpeg=ffmpeg, ffprobe=ffprobe)


def detect_encoders(ffmpeg_bin: str) -> AvailableEncoders:
    """Query ffmpeg for hardware and audio encoders available on this machine."""
    proc = subprocess.run(
        [ffmpeg_bin, "-hide_banner", "-encoders"],
        capture_output=True,
        text=True,
        check=False,
    )
    text = proc.stdout + "\n" + proc.stderr
    return AvailableEncoders(
        aac_at=" aac_at " in text,
        h264_videotoolbox=" h264_videotoolbox " in text,
        hevc_videotoolbox=" hevc_videotoolbox " in text,
        prores_videotoolbox=" prores_videotoolbox " in text,
        libx264=" libx264 " in text,
    )


def probe_file(ffprobe_bin: str, input_path: Path) -> ProbeResult:
    """Run ffprobe on input_path and parse stream/format details."""
    cmd = [
        ffprobe_bin,
        "-v",
        "error",
        "-show_format",
        "-show_streams",
        "-show_chapters",
        "-of",
        "json",
        str(input_path),
    ]
    proc = subprocess.run(cmd, capture_output=True, text=True, check=False)
    if proc.returncode != 0:
        raise RuntimeError(f"ffprobe failed on '{input_path.name}': {proc.stderr.strip()}")
    data = json.loads(proc.stdout)
    return parse_probe_data(data, input_path)


def parse_probe_data(data: dict[str, Any], input_path: Path) -> ProbeResult:
    """Parse raw ffprobe JSON into structured ProbeResult."""
    fmt = data.get("format") or {}
    raw_size = int(fmt.get("size") or (input_path.stat().st_size if input_path.exists() else 0))
    duration_sec = float(fmt.get("duration") or 0.0)

    primary_video: VideoStream | None = None
    audio_streams: list[AudioStream] = []
    subtitle_streams: list[SubtitleStream] = []

    for stream in data.get("streams") or []:
        stype = stream.get("codec_type")
        idx = int(stream["index"])
        tags = stream.get("tags") or {}
        disposition = stream.get("disposition") or {}
        codec = str(stream.get("codec_name") or "").lower()

        if stype == "video":
            if disposition.get("attached_pic") == 1 or codec in COVER_ART_CODECS:
                continue
            if primary_video is None:
                side_data = stream.get("side_data_list") or []
                has_dovi = any(
                    "dolby vision" in str(item.get("side_data_type", "")).lower()
                    or "dovi" in str(item.get("side_data_type", "")).lower()
                    for item in side_data
                )
                r_rate = str(stream.get("r_frame_rate") or "")
                avg_rate = str(stream.get("avg_frame_rate") or "")
                primary_video = VideoStream(
                    index=idx,
                    codec_name=codec,
                    pix_fmt=str(stream.get("pix_fmt") or ""),
                    width=int(stream.get("width") or 0),
                    height=int(stream.get("height") or 0),
                    r_frame_rate=r_rate,
                    avg_frame_rate=avg_rate,
                    is_vfr=detect_vfr(r_rate, avg_rate),
                    has_dolby_vision=has_dovi,
                    color_transfer=str(stream.get("color_transfer") or ""),
                )
        elif stype == "audio":
            audio_streams.append(
                AudioStream(
                    index=idx,
                    codec_name=codec,
                    channels=int(stream.get("channels") or 0),
                    channel_layout=str(stream.get("channel_layout") or ""),
                    language=str(tags.get("language") or "und").lower(),
                    title=str(tags.get("title") or ""),
                )
            )
        elif stype == "subtitle":
            subtitle_streams.append(
                SubtitleStream(
                    index=idx,
                    codec_name=codec,
                    language=str(tags.get("language") or "und").lower(),
                    title=str(tags.get("title") or ""),
                )
            )

    chapters = data.get("chapters") or []
    return ProbeResult(
        path=input_path,
        size_bytes=raw_size,
        duration_sec=duration_sec,
        video=primary_video,
        audio_streams=audio_streams,
        subtitle_streams=subtitle_streams,
        chapter_count=len(chapters),
    )


def select_audio_streams(
    audio_streams: list[AudioStream],
    audio_langs: tuple[str, ...],
    first_audio: bool,
) -> tuple[list[AudioStream], list[str]]:
    """Select audio tracks based on language filters and --first-audio."""
    warnings: list[str] = []
    if not audio_streams:
        return [], ["No audio streams found; output will contain video only."]

    selected = list(audio_streams)
    if audio_langs:
        normalized = {lang.strip().lower() for lang in audio_langs if lang.strip()}
        matched = [s for s in selected if s.language in normalized]
        if matched:
            selected = matched
        else:
            warnings.append(
                f"No audio tracks matched language filter ({', '.join(sorted(normalized))}); "
                "keeping all audio tracks instead."
            )

    if first_audio and len(selected) > 1:
        selected = [selected[0]]

    return selected, warnings


def _build_audio_args(
    stream: AudioStream,
    out_idx: int,
    options: ConvertOptions,
    encoders: AvailableEncoders,
) -> tuple[list[str], str]:
    """Build ffmpeg per-stream arguments and description for one audio track."""
    lang_tag = f"[{stream.language}]" if stream.language else ""
    base_label = f"#{stream.index}{lang_tag} {stream.codec_name} ({stream.channels}ch)"

    if options.container == "mov":
        if stream.codec_name.startswith("pcm_"):
            return [f"-c:a:{out_idx}", "copy"], f"{base_label} -> copy (PCM)"
        args = [f"-c:a:{out_idx}", "pcm_s24le"]
        if options.stereo and stream.channels > 2:
            args.extend([f"-ac:a:{out_idx}", "2"])
            return args, f"{base_label} -> pcm_s24le 2ch (lossless stereo downmix)"
        return args, f"{base_label} -> pcm_s24le (lossless PCM)"

    # MP4 container rules tailored for Final Cut Pro + DaVinci Resolve
    if stream.codec_name == "aac" and not (options.stereo and stream.channels > 2):
        return [f"-c:a:{out_idx}", "copy"], f"{base_label} -> copy (AAC)"

    if options.copy_ac3 and stream.codec_name in {"ac3", "eac3"} and not (options.stereo and stream.channels > 2):
        return [f"-c:a:{out_idx}", "copy"], f"{base_label} -> copy ({stream.codec_name.upper()})"

    if options.stereo and stream.channels > 2:
        encoder = "aac_at" if encoders.aac_at else "aac"
        args = [f"-c:a:{out_idx}", encoder, f"-ac:a:{out_idx}", "2", f"-b:a:{out_idx}", "320k"]
        return args, f"{base_label} -> {encoder} 2ch 320k"

    if stream.channels >= 8:
        # FFmpeg native AAC handles 7.1 channel mapping reliably; aac_at can misroute 8ch layouts.
        args = [
            f"-c:a:{out_idx}",
            "aac",
            f"-filter:a:{out_idx}",
            "aformat=channel_layouts=7.1",
            f"-b:a:{out_idx}",
            "640k",
        ]
        return args, f"{base_label} -> aac 7.1 640k"

    if stream.channels == 6:
        encoder = "aac_at" if encoders.aac_at else "aac"
        args = [f"-c:a:{out_idx}", encoder, f"-b:a:{out_idx}", "448k"]
        if "side" in stream.channel_layout.lower():
            args.extend([f"-filter:a:{out_idx}", "channelmap=channel_layout=5.1"])
        else:
            args.extend([f"-filter:a:{out_idx}", "aformat=channel_layouts=5.1"])
        return args, f"{base_label} -> {encoder} 5.1 448k"

    if stream.channels in {3, 4, 5, 7}:
        # Rare multi-channel layouts (e.g. 5.0 or 6.1 DTS-ES): native aac avoids aac_at layout errors.
        bitrate = "512k" if stream.channels == 7 else "384k"
        args = [f"-c:a:{out_idx}", "aac", f"-b:a:{out_idx}", bitrate]
        return args, f"{base_label} -> aac {stream.channels}ch {bitrate}"

    encoder = "aac_at" if encoders.aac_at else "aac"
    bitrate = "192k" if stream.channels <= 1 else "320k"
    args = [f"-c:a:{out_idx}", encoder, f"-b:a:{out_idx}", bitrate]
    return args, f"{base_label} -> {encoder} {bitrate}"


def _build_video_transcode_args(
    video: VideoStream,
    options: ConvertOptions,
    encoders: AvailableEncoders,
) -> tuple[list[str], str]:
    """Build high-quality video transcode arguments when lossless copy is unsupported."""
    args: list[str] = []
    target_fps = _parse_rate(video.r_frame_rate) or _parse_rate(video.avg_frame_rate)
    if video.is_vfr and target_fps:
        fps_str = f"{target_fps:.3f}".rstrip("0").rstrip(".")
        args.extend(["-vf", f"fps={fps_str}", "-fps_mode", "cfr"])

    if options.container == "mov" and options.prores and encoders.prores_videotoolbox:
        args.extend(["-c:v:0", "prores_videotoolbox", "-profile:v:0", "2"])
        return args, "transcode -> ProRes 422 (prores_videotoolbox)"

    if encoders.hevc_videotoolbox and video.codec_name in {"hevc", "av1", "vp9", "vc1"}:
        args.extend(["-c:v:0", "hevc_videotoolbox", "-q:v:0", "75", "-tag:v:0", "hvc1"])
        return args, "transcode -> HEVC high-quality (hevc_videotoolbox, hvc1)"

    if encoders.h264_videotoolbox:
        args.extend(["-c:v:0", "h264_videotoolbox", "-q:v:0", "75"])
        return args, "transcode -> H.264 high-quality (h264_videotoolbox)"

    if encoders.libx264:
        args.extend(["-c:v:0", "libx264", "-crf", "16", "-preset", "medium"])
        return args, "transcode -> H.264 visually lossless (libx264 -crf 16)"

    args.extend(["-c:v:0", "h264"])
    return args, "transcode -> H.264"


def resolve_output_paths(input_path: Path, options: ConvertOptions) -> tuple[Path, Path]:
    """Compute final output path and atomic temporary output path."""
    ext = ".mov" if options.container == "mov" else ".mp4"
    target_dir = options.output_dir if options.output_dir else input_path.parent
    output_path = target_dir / f"{input_path.stem}{ext}"
    temp_path = target_dir / f".{input_path.stem}.converting{ext}"
    return output_path, temp_path


def build_plan(
    probe: ProbeResult,
    options: ConvertOptions,
    encoders: AvailableEncoders,
    ffmpeg_bin: str = "ffmpeg",
) -> ConversionPlan:
    """Construct a complete, safe ConversionPlan from a ProbeResult."""
    output_path, temp_path = resolve_output_paths(probe.path, options)
    warnings: list[str] = []

    if probe.video is None:
        return ConversionPlan(
            input_path=probe.path,
            output_path=output_path,
            temp_path=temp_path,
            can_proceed=False,
            requires_video_transcode=False,
            video_action="none",
            skip_reason="No non-cover-art video stream found.",
        )

    if output_path.exists() and not options.overwrite and not options.inspect_only:
        return ConversionPlan(
            input_path=probe.path,
            output_path=output_path,
            temp_path=temp_path,
            can_proceed=False,
            requires_video_transcode=False,
            video_action="skip",
            skip_reason=f"Output already exists: {output_path.name} (use --overwrite to replace)",
        )

    video = probe.video
    codec_incompatible = video.codec_name not in EDITOR_COPY_VIDEO_CODECS
    needs_transcode = codec_incompatible or (video.is_vfr and options.allow_transcode)

    if video.has_dolby_vision:
        warnings.append(
            "Dolby Vision metadata detected: MP4 copy preserves base HDR10 layer, "
            "but Final Cut Pro / Resolve may ignore dual-layer DV metadata."
        )

    if video.is_vfr and not options.allow_transcode:
        warnings.append(
            f"Variable Frame Rate detected (r={video.r_frame_rate}, avg={video.avg_frame_rate}). "
            "Blu-ray rips are normally CFR; if audio drifts in Resolve/FCP, re-run with --allow-transcode."
        )

    if codec_incompatible and not options.allow_transcode:
        reason = (
            f"Video codec '{video.codec_name}' cannot be losslessly remuxed into "
            f"{options.container.upper()} for FCP/Resolve. Re-run with --allow-transcode to convert."
        )
        return ConversionPlan(
            input_path=probe.path,
            output_path=output_path,
            temp_path=temp_path,
            can_proceed=False,
            requires_video_transcode=True,
            video_action=f"blocked ({video.codec_name})",
            warnings=warnings,
            skip_reason=reason,
        )

    cmd: list[str] = [
        ffmpeg_bin,
        "-hide_banner",
        "-y",
        "-i",
        str(probe.path),
        "-map",
        f"0:{video.index}",
    ]

    if needs_transcode or options.prores:
        v_args, video_action = _build_video_transcode_args(video, options, encoders)
    else:
        v_args = ["-c:v:0", "copy"]
        if video.codec_name == "hevc":
            v_args.extend(["-tag:v:0", "hvc1"])
            video_action = f"copy HEVC ({video.width}x{video.height}, {video.pix_fmt}, tag=hvc1)"
        else:
            video_action = f"copy {video.codec_name.upper()} ({video.width}x{video.height}, {video.pix_fmt})"

    selected_audio, audio_warnings = select_audio_streams(
        probe.audio_streams, options.audio_langs, options.first_audio
    )
    warnings.extend(audio_warnings)

    audio_args: list[str] = []
    audio_actions: list[str] = []
    for out_idx, a_stream in enumerate(selected_audio):
        cmd.extend(["-map", f"0:{a_stream.index}"])
        per_stream_args, label = _build_audio_args(a_stream, out_idx, options, encoders)
        audio_args.extend(per_stream_args)
        audio_actions.append(label)

    cmd.extend(v_args)
    cmd.extend(audio_args)
    cmd.append("-sn")
    cmd.extend(["-map_metadata", "0"])
    if options.keep_chapters:
        cmd.extend(["-map_chapters", "0"])
    else:
        cmd.extend(["-map_chapters", "-1"])

    if options.faststart and options.container == "mp4":
        cmd.extend(["-movflags", "+faststart"])

    cmd.append(str(temp_path))

    if probe.subtitle_streams and not options.extract_subs:
        sub_codecs = ", ".join(sorted({s.codec_name for s in probe.subtitle_streams}))
        warnings.append(
            f"Dropping {len(probe.subtitle_streams)} subtitle track(s) ({sub_codecs}) "
            "for clean MP4/MOV editor import (pass --extract-subs to save sidecar files)."
        )

    return ConversionPlan(
        input_path=probe.path,
        output_path=output_path,
        temp_path=temp_path,
        can_proceed=True,
        requires_video_transcode=needs_transcode or options.prores,
        video_action=video_action,
        audio_actions=audio_actions,
        warnings=warnings,
        command=cmd,
        selected_subtitles=probe.subtitle_streams if options.extract_subs else [],
    )


def _subtitle_extension(codec_name: str) -> str | None:
    """Return suitable sidecar file extension for supported subtitle codecs."""
    if codec_name in TEXT_SUBTITLE_EXTS:
        return TEXT_SUBTITLE_EXTS[codec_name]
    if codec_name in IMAGE_SUBTITLE_EXTS:
        return IMAGE_SUBTITLE_EXTS[codec_name]
    return None


def extract_subtitles(
    ffmpeg_bin: str,
    probe: ProbeResult,
    output_path: Path,
    overwrite: bool,
) -> list[Path]:
    """Extract subtitle streams as standalone sidecar files alongside the output."""
    extracted: list[Path] = []
    for pos, sub in enumerate(probe.subtitle_streams):
        ext = _subtitle_extension(sub.codec_name)
        if ext is None:
            print(f"  [sub] Skipping unsupported subtitle codec '{sub.codec_name}' (stream #{sub.index})")
            continue
        lang = sub.language or "und"
        sidecar = output_path.with_name(f"{output_path.stem}.{pos + 1}.{lang}{ext}")
        if sidecar.exists() and not overwrite:
            continue
        cmd = [
            ffmpeg_bin,
            "-hide_banner",
            "-loglevel",
            "error",
            "-y",
            "-i",
            str(probe.path),
            "-map",
            f"0:{sub.index}",
            "-c:s",
            "copy",
            str(sidecar),
        ]
        proc = subprocess.run(cmd, capture_output=True, text=True, check=False)
        if proc.returncode == 0 and sidecar.exists():
            extracted.append(sidecar)
        else:
            print(f"  [sub] Failed to extract stream #{sub.index} ({sub.codec_name}): {proc.stderr.strip()}")
    return extracted


def _existing_ancestor(path: Path) -> Path:
    """Return path or its nearest existing parent directory."""
    cur = path
    while not cur.exists() and cur != cur.parent:
        cur = cur.parent
    return cur


def check_free_space(probe: ProbeResult, plan: ConversionPlan, options: ConvertOptions) -> str | None:
    """Verify sufficient free space in the destination directory before starting."""
    dest_dir = plan.output_path.parent
    probe_dir = dest_dir if dest_dir.exists() else _existing_ancestor(dest_dir)
    free_bytes = shutil.disk_usage(probe_dir).free

    # +faststart creates a second full rewrite pass temporarily; ProRes MOV expands heavily.
    if options.container == "mov" and options.prores:
        multiplier = 5.0
    elif options.faststart and options.container == "mp4":
        multiplier = 2.1
    else:
        multiplier = 1.25

    needed_bytes = int(probe.size_bytes * multiplier)
    if free_bytes < needed_bytes:
        return (
            f"Low disk space in '{dest_dir}': {format_bytes(free_bytes)} free, "
            f"recommended at least {format_bytes(needed_bytes)} for '{probe.path.name}'."
        )
    return None


def collect_inputs(paths: list[Path], recursive: bool) -> list[Path]:
    """Collect .mkv files from given files and directories, ignoring macOS ._ sidecars."""
    collected: list[Path] = []
    seen: set[Path] = set()

    for raw in paths:
        path = raw.expanduser().resolve()
        if not path.exists():
            print(f"[warn] Path does not exist: {raw}", file=sys.stderr)
            continue
        if path.is_file():
            if path.suffix.lower() == ".mkv" and not path.name.startswith("._") and path not in seen:
                seen.add(path)
                collected.append(path)
            elif path.suffix.lower() != ".mkv":
                print(f"[warn] Skipping non-MKV file: {path.name}", file=sys.stderr)
            continue

        iterator = path.rglob("*") if recursive else path.iterdir()
        for child in sorted(iterator):
            if (
                child.is_file()
                and child.suffix.lower() == ".mkv"
                and not child.name.startswith("._")
                and child not in seen
            ):
                seen.add(child)
                collected.append(child)

    return collected


def print_plan(probe: ProbeResult, plan: ConversionPlan) -> None:
    """Print human-readable stream analysis and planned ffmpeg operations."""
    print(f"\n=== {probe.path.name} ({format_bytes(probe.size_bytes)}, {format_duration(probe.duration_sec)}) ===")
    print(f"  Output: {plan.output_path}")
    print(f"  Video : {plan.video_action}")
    if plan.audio_actions:
        for idx, action in enumerate(plan.audio_actions, start=1):
            print(f"  Audio{idx}: {action}")
    else:
        print("  Audio : none")
    if probe.chapter_count:
        print(f"  Chapters: {probe.chapter_count}")
    for warn in plan.warnings:
        print(f"  [warn] {warn}")
    if plan.skip_reason:
        print(f"  [skip] {plan.skip_reason}")


def emit_json_event(event: str, **payload: Any) -> None:
    """Write one line-delimited JSON progress event to stdout and flush immediately."""
    print(json.dumps({"event": event, **payload}), flush=True)


def parse_progress_time_sec(key: str, value: str) -> float | None:
    """Parse ffmpeg -progress time fields ('out_time_us' or 'out_time')."""
    if key == "out_time_us":
        try:
            micros = int(value)
        except ValueError:
            return None
        return max(0.0, micros / 1_000_000.0)
    if key == "out_time" and ":" in value:
        parts = value.split(":")
        if len(parts) == 3:
            try:
                return max(0.0, int(parts[0]) * 3600.0 + int(parts[1]) * 60.0 + float(parts[2]))
            except ValueError:
                return None
    return None


def _run_ffmpeg_with_progress(
    command: list[str],
    probe: ProbeResult,
    temp_path: Path,
) -> tuple[int, str]:
    """Execute ffmpeg with -progress pipe:1 and emit JSON progress updates."""
    progress_cmd = [command[0], "-nostdin", "-progress", "pipe:1", "-loglevel", "error", *command[1:]]
    proc = subprocess.Popen(
        progress_cmd,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        bufsize=1,
    )
    out_time_sec = 0.0
    speed = ""
    last_error_lines: list[str] = []

    try:
        assert proc.stdout is not None
        for raw_line in proc.stdout:
            line = raw_line.strip()
            if not line:
                continue
            if "=" not in line:
                last_error_lines.append(line)
                if len(last_error_lines) > 10:
                    last_error_lines.pop(0)
                continue
            key, _, val = line.partition("=")
            parsed_sec = parse_progress_time_sec(key, val)
            if parsed_sec is not None:
                out_time_sec = parsed_sec
            elif key == "speed":
                speed = val.strip()
            elif key == "progress":
                pct = 0.0
                if probe.duration_sec > 0:
                    pct = min(99.5, max(0.0, (out_time_sec / probe.duration_sec) * 100.0))
                if val == "end":
                    pct = 99.8
                emit_json_event(
                    "progress",
                    file=probe.path.name,
                    percent=round(pct, 1),
                    speed=speed,
                    out_time_sec=round(out_time_sec, 1),
                    duration_sec=round(probe.duration_sec, 1),
                    phase="finalizing" if val == "end" else "converting",
                )
        returncode = proc.wait()
    except KeyboardInterrupt:
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()
        if temp_path.exists():
            temp_path.unlink()
        raise

    return returncode, "\n".join(last_error_lines)


def execute_plan(
    tools: ToolPaths,
    probe: ProbeResult,
    plan: ConversionPlan,
    options: ConvertOptions,
) -> tuple[bool, str]:
    """Execute a ConversionPlan with atomic temp-file rename and cleanup on failure."""
    space_warning = check_free_space(probe, plan, options)
    if space_warning:
        if not options.progress_json:
            print(f"  [error] {space_warning}", file=sys.stderr)
        return False, space_warning

    if options.dry_run:
        if not options.progress_json:
            print("  [dry-run] Command:")
            print("   ", shlex.join(plan.command))
        return True, "dry-run"

    plan.output_path.parent.mkdir(parents=True, exist_ok=True)
    if plan.temp_path.exists():
        plan.temp_path.unlink()

    start = time.monotonic()
    error_detail = ""
    if options.progress_json:
        returncode, error_detail = _run_ffmpeg_with_progress(plan.command, probe, plan.temp_path)
    else:
        try:
            proc = subprocess.run(plan.command, check=False)
            returncode = proc.returncode
        except KeyboardInterrupt:
            print("\n  [abort] Interrupted by user; removing partial temp file...")
            if plan.temp_path.exists():
                plan.temp_path.unlink()
            raise

    if returncode != 0 or not plan.temp_path.exists():
        msg = error_detail or f"ffmpeg exited with code {returncode}."
        if not options.progress_json:
            print(f"  [error] {msg}", file=sys.stderr)
        if plan.temp_path.exists():
            plan.temp_path.unlink()
        return False, msg

    plan.temp_path.replace(plan.output_path)
    elapsed = time.monotonic() - start
    out_size = plan.output_path.stat().st_size
    if not options.progress_json:
        print(
            f"  [done] {plan.output_path.name} ({format_bytes(out_size)}) "
            f"in {elapsed:.1f}s"
        )

    if plan.selected_subtitles:
        extracted = extract_subtitles(tools.ffmpeg, probe, plan.output_path, options.overwrite)
        if extracted and not options.progress_json:
            print(f"  [subs] Extracted {len(extracted)} sidecar subtitle file(s).")

    return True, f"Converted ({format_bytes(out_size)}) in {elapsed:.1f}s"


def build_arg_parser() -> argparse.ArgumentParser:
    """Create CLI argument parser."""
    parser = argparse.ArgumentParser(
        description="Lossless-first MKV to MP4/MOV converter for Final Cut Pro & DaVinci Resolve."
    )
    parser.add_argument(
        "inputs",
        nargs="+",
        type=Path,
        help="MKV file(s) or folder(s) containing MKV files.",
    )
    parser.add_argument(
        "-o",
        "--output-dir",
        type=Path,
        default=None,
        help="Directory for converted files (default: same folder as each input MKV).",
    )
    parser.add_argument(
        "-c",
        "--container",
        choices=("mp4", "mov"),
        default="mp4",
        help="Output container: 'mp4' (default, AAC audio) or 'mov' (lossless 24-bit PCM audio).",
    )
    parser.add_argument(
        "-r",
        "--recursive",
        action="store_true",
        help="Search folders recursively for .mkv files.",
    )
    parser.add_argument(
        "--audio-langs",
        default="",
        help="Comma-separated ISO 639-2 language codes to keep (e.g. 'eng,jpn'). Default: keep all.",
    )
    parser.add_argument(
        "--first-audio",
        action="store_true",
        help="Keep only the first matching audio track instead of all tracks.",
    )
    parser.add_argument(
        "--stereo",
        action="store_true",
        help="Downmix 5.1/7.1 surround tracks to 2.0 stereo (handy for YouTube/commentary edits).",
    )
    parser.add_argument(
        "--copy-ac3",
        action="store_true",
        help="Copy AC-3/E-AC-3 audio as-is in MP4 instead of converting to AAC (DaVinci Studio only; FCP often mutes AC-3).",
    )
    parser.add_argument(
        "--no-faststart",
        action="store_true",
        help="Skip -movflags +faststart (saves a second SSD copy pass on 15-20 GB MP4s).",
    )
    parser.add_argument(
        "--extract-subs",
        action="store_true",
        help="Save subtitles as external sidecar files (.srt/.ass/.sup) alongside the output.",
    )
    parser.add_argument(
        "--allow-transcode",
        action="store_true",
        help="Allow high-quality transcoding if video is VC-1/MPEG-2/VP9 or Variable Frame Rate.",
    )
    parser.add_argument(
        "--prores",
        action="store_true",
        help="When --container mov is set, transcode video to Apple ProRes 422 (huge files, fastest timeline scrubbing).",
    )
    parser.add_argument(
        "--no-chapters",
        action="store_true",
        help="Do not copy MKV chapter markers into the output.",
    )
    parser.add_argument(
        "--overwrite",
        action="store_true",
        help="Overwrite existing output files.",
    )
    parser.add_argument(
        "--inspect",
        action="store_true",
        help="Inspect files and print the conversion plan without converting anything.",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Print the exact ffmpeg commands without executing them.",
    )
    parser.add_argument(
        "--progress-json",
        action="store_true",
        help="Emit line-delimited JSON status and progress events for GUI wrappers.",
    )
    return parser


def _handle_sigterm(_signum: int, _frame: Any) -> None:
    """Convert SIGTERM from GUI cancellation into KeyboardInterrupt for cleanup."""
    raise KeyboardInterrupt()


def main(argv: list[str] | None = None) -> int:
    """CLI entry point."""
    signal.signal(signal.SIGTERM, _handle_sigterm)
    parser = build_arg_parser()
    args = parser.parse_args(argv)

    if args.prores and args.container != "mov":
        parser.error("--prores requires --container mov")

    try:
        tools = find_ffmpeg_tools()
    except FileNotFoundError as exc:
        if args.progress_json:
            emit_json_event("error", message=str(exc))
        else:
            print(f"[error] {exc}", file=sys.stderr)
        return 2

    mkv_files = collect_inputs(args.inputs, recursive=args.recursive)
    if not mkv_files:
        msg = "No .mkv files found in the specified path(s)."
        if args.progress_json:
            emit_json_event("error", message=msg)
        else:
            print(f"[error] {msg}", file=sys.stderr)
        return 1

    encoders = detect_encoders(tools.ffmpeg)
    langs = tuple(part.strip().lower() for part in args.audio_langs.split(",") if part.strip())
    options = ConvertOptions(
        container=args.container,
        output_dir=args.output_dir.expanduser().resolve() if args.output_dir else None,
        audio_langs=langs,
        first_audio=args.first_audio,
        stereo=args.stereo,
        copy_ac3=args.copy_ac3,
        faststart=not args.no_faststart,
        extract_subs=args.extract_subs,
        allow_transcode=args.allow_transcode,
        prores=args.prores,
        keep_chapters=not args.no_chapters,
        overwrite=args.overwrite,
        inspect_only=args.inspect,
        dry_run=args.dry_run,
        progress_json=args.progress_json,
    )

    succeeded = 0
    skipped = 0
    failed = 0
    total = len(mkv_files)

    for idx, mkv in enumerate(mkv_files, start=1):
        try:
            probe = probe_file(tools.ffprobe, mkv)
        except RuntimeError as exc:
            if options.progress_json:
                emit_json_event("file_done", file=mkv.name, status="failed", message=str(exc))
            else:
                print(f"\n[error] {exc}", file=sys.stderr)
            failed += 1
            continue

        plan = build_plan(probe, options, encoders, ffmpeg_bin=tools.ffmpeg)
        if not options.progress_json:
            print_plan(probe, plan)
        else:
            emit_json_event(
                "inspect" if options.inspect_only else "file_start",
                index=idx,
                total=total,
                file=probe.path.name,
                input_path=str(probe.path),
                output_path=str(plan.output_path),
                size_bytes=probe.size_bytes,
                duration_sec=round(probe.duration_sec, 1),
                can_proceed=plan.can_proceed,
                requires_video_transcode=plan.requires_video_transcode,
                video_action=plan.video_action,
                audio_actions=plan.audio_actions,
                warnings=plan.warnings,
                skip_reason=plan.skip_reason,
            )

        if options.inspect_only:
            continue
        if not plan.can_proceed:
            if options.progress_json:
                emit_json_event(
                    "file_done",
                    file=probe.path.name,
                    status="skipped",
                    output_path=str(plan.output_path),
                    message=plan.skip_reason or "Skipped",
                )
            skipped += 1
            continue

        try:
            ok, message = execute_plan(tools, probe, plan, options)
        except KeyboardInterrupt:
            if options.progress_json:
                emit_json_event("cancelled", file=probe.path.name)
            return 130

        if ok:
            succeeded += 1
            if options.progress_json:
                out_bytes = plan.output_path.stat().st_size if plan.output_path.exists() else 0
                emit_json_event(
                    "file_done",
                    file=probe.path.name,
                    status="converted",
                    output_path=str(plan.output_path),
                    output_bytes=out_bytes,
                    message=message,
                )
        else:
            failed += 1
            if options.progress_json:
                emit_json_event(
                    "file_done",
                    file=probe.path.name,
                    status="failed",
                    output_path=str(plan.output_path),
                    message=message,
                )

    if not options.inspect_only:
        if options.progress_json:
            emit_json_event("batch_done", converted=succeeded, skipped=skipped, failed=failed)
        else:
            print(f"\nSummary: {succeeded} converted, {skipped} skipped, {failed} failed.")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
