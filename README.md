# 🎬 Video Converter
### Ultra-Fast, Lossless MKV to MP4 & MOV Remuxer for Final Cut Pro & DaVinci Resolve on Apple Silicon

[![macOS](https://img.shields.io/badge/macOS-13.0%2B%20(Ventura%20%7C%20Sonoma%20%7C%20Sequoia)-000000?style=for-the-badge&logo=apple&logoColor=white)](#)
[![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-M1%20%7C%20M2%20%7C%20M3%20%7C%20M4-0071e3?style=for-the-badge&logo=apple&logoColor=white)](#)
[![Video Quality](https://img.shields.io/badge/Video%20Quality-100%25%20Lossless%20(-c:v%20copy)-success?style=for-the-badge)](#)
[![Speed](https://img.shields.io/badge/Speed-15--20%20GB%20in%20~15s-blueviolet?style=for-the-badge)](#)
[![License](https://img.shields.io/badge/License-MIT-blue?style=for-the-badge)](#)

A high-performance, stream-aware remuxing suite and native macOS desktop app designed for video editors and filmmakers. Convert massive (10–20+ GB) `.mkv` Blu-ray and film rips into editor-ready `.mp4` or `.mov` files in **seconds** without re-encoding video—delivering **100% original video quality**, automatic Apple Silicon hardware tags, and audio tracks that never drop or mute in **Final Cut Pro**, **DaVinci Resolve**, or **QuickTime Player**.

---

## ⚡ The Problem: Why MKVs Break in Mac Video Editors

Final Cut Pro, DaVinci Resolve, and QuickTime do not natively support the Matroska (`.mkv`) container. When editors try to work around this, they typically run into two frustrating traps:

1. **The Re-encoding Trap (HandBrake / Adobe Media Encoder / VLC):**
   - Takes **30 to 60+ minutes** per film.
   - Causes **generational quality loss**, banding, macroblocking, and gamma shifts.
   - Wastes gigabytes of SSD writes and drives CPU/GPU temps to maximum.

2. **The Naive FFmpeg Trap (`ffmpeg -i input.mkv -c copy output.mp4`):**
   - 🔇 **Muted or Missing Audio:** Final Cut Pro and DaVinci Resolve mute, drop, or error out on raw Blu-ray audio streams (`DTS`, `DTS-HD MA`, `Dolby TrueHD`, and uncompressed `FLAC`) inside MP4 containers.
   - 🚫 **QuickTime / FCP Import Errors on HEVC:** Apple video frameworks require the `hvc1` FourCC tag. Generic FFmpeg HEVC muxing defaults to `hev1`, which QuickTime cannot open and Final Cut Pro marks as unsupported.
   - 💥 **Corrupted Video from Cover Art:** Rips often include high-resolution poster JPEG/PNG images marked as video tracks (`attached_pic`). Standard FFmpeg accidentally maps this static image as the main video stream, breaking the remuxed video.
   - ❌ **Subtitle Muxing Failures:** Bitmap subtitles (`hdmv_pgs_subtitle` / `dvd_subtitle`) are not allowed inside MP4 containers and crash the muxer.

### The Solution: How Video Converter Fixes This

| Feature | Re-encoding (HandBrake / Media Encoder) | Naive FFmpeg (`-c copy`) | **Video Converter** (This Tool) |
| :--- | :---: | :---: | :---: |
| **Speed (15–20 GB Rip)** | 25–60 minutes | ~10–30 seconds | **~10–30 seconds** ⚡ |
| **Video Quality** | 📉 Re-compressed (lossy) | 100% Lossless | **100% Lossless (Bit-for-Bit)** |
| **Apple HEVC Tag (`hvc1`)** | Varies | ❌ Defaults to `hev1` (FCP fails) | ✅ **Automatic `hvc1` Injection** |
| **Blu-ray Audio in FCP** | Re-encodes whole file | ❌ Muted / Unsupported | ✅ **Pristine Studio AAC / 24-bit PCM** |
| **Cover Art Poster Guard** | Manual removal required | ❌ Poster mapped as video | ✅ **Skips embedded cover art** |
| **PGS / VobSub Subtitles** | Burns in or crashes | ❌ Fails muxing | ✅ **Auto-dropped or exported to `.sup`/`.srt`** |
| **Chapter Markers** | Often lost | Often lost | ✅ **Preserved from source MKV** |
| **Crash / Interrupted Safety** | Partial corrupt file | Partial corrupt file | ✅ **Atomic writes (`.converting` temp file)** |
| **User Interface** | Complex encoding menus | Terminal only | **Native macOS App + Clean CLI** |

---

## 🌟 Key Features

- **100% Bit-for-Bit Lossless Video (`-c:v copy`):** H.264 (AVC) and H.265 (HEVC) streams are passed through untouched. No recompression, no color space shifts, no generational loss.
- **Apple Silicon NLE Audio Matrix:**
  - Existing AAC tracks are copied bit-for-bit.
  - Blu-ray audio formats (`DTS`, `TrueHD`, `FLAC`, `AC-3`, `E-AC-3`) are converted via macOS's native **Apple AudioToolbox** (`aac_at`) at high bitrates (320k stereo, 448k 5.1 surround) or native FFmpeg AAC for 7.1 surround (640k).
  - Optional downmix to clean stereo (`--stereo`) for YouTube, voiceovers, and commentary workflows.
- **Studio Master Mode (`--container mov`):** Remuxes with 100% untouched video while converting all audio tracks to uncompressed **24-bit PCM** (`pcm_s24le`), allowing smooth, instant timeline scrubbing in Final Cut Pro and DaVinci Resolve.
- **Apple ProRes 422 Hardware Transcode (`--prores`):** Need maximum playback speed on older or complex timelines? Transcode directly to ProRes 422 using Apple Silicon VideoToolbox hardware acceleration.
- **HDR10 & Dolby Vision Preservation:** Maintains HDR10 mastering metadata and flags Dolby Vision layers.
- **Cover Art Guard:** Automatically detects and strips thumbnail pictures (`mjpeg`, `png`, `attached_pic`) so they never corrupt video stream mapping.
- **Sidecar Subtitle Extraction (`--extract-subs`):** Cleanly extracts embedded Blu-ray PGS subtitles (`.sup`), SubRip (`.srt`), or SubStation Alpha (`.ass`) alongside your output file.
- **Atomic Writes & Disk Protection:** Checks available disk space before starting and writes to hidden temporary files (`.{name}.converting.mp4`). Interrupting with `Ctrl+C` or canceling in the app will never leave corrupt 15 GB files on your SSD.
- **Native macOS SwiftUI Desktop App:** Complete drag-and-drop interface, queue management, live progress bars, speed gauges, and automatic destination memory.

---

## 📦 What's Inside

```
.
├── Video Converter.app/   # Native compiled macOS desktop application
├── macos_app/
│   ├── MKVToMP4App.swift  # SwiftUI + AppKit frontend source code
│   └── build_app.sh       # Native app compiler script
├── mkv_to_mp4.py          # Core stream-aware converter engine
├── convert_folder.sh      # Drag-and-drop interactive CLI launcher
├── inspect_mkvs.sh        # Fast stream analyzer (codecs, audio, HDR, VFR)
├── setup_ffmpeg.sh        # Zero-Homebrew Apple Silicon FFmpeg installer
└── tests/
    └── test_mkv_to_mp4.py # Unit tests for stream mapping and argument logic
```

---

## 🚀 Quick Start

### Option A: The Native Mac App (Zero Terminal Needed)

1. Open **`Video Converter.app`** (or drag it to `/Applications` or your Dock).
2. If FFmpeg isn't installed on your Mac, click **"Install FFmpeg Now"** directly in the banner (downloads notarized Apple Silicon binaries with SHA-256 verification—no Homebrew required).
3. **Drag and drop** your `.mkv` files or entire folders onto the window (or onto the app Dock icon).
4. Select your output format (`MP4` or `MOV`) and choose your destination folder.
5. Click **Convert** and watch real-time progress. Click **Reveal in Finder** when done.

### Option B: Command Line (CLI)

```zsh
# 1. Download native Apple Silicon FFmpeg binaries into ./bin/ (one-time setup)
./setup_ffmpeg.sh

# 2. Inspect your MKV files (instant, non-destructive)
./inspect_mkvs.sh "Movie.mkv"

# 3. Convert to MP4 with 100% lossless video
./mkv_to_mp4.py "Movie.mkv"
```

---

## 🛠️ One-Time Setup (`ffmpeg` & `ffprobe`)

This tool requires `ffmpeg` and `ffprobe`. You can set them up in one of two ways:

### 1. Standalone / Zero-Homebrew (Recommended)
Run the bundled installer. It downloads official, notarized Apple Silicon (`arm64`) static builds from Martin Riedl, verifies their SHA-256 checksums, and installs them into `./bin/` (or `~/Library/Application Support/Video Converter/bin`):

```zsh
./setup_ffmpeg.sh
```

### 2. Homebrew
If you prefer managing tools through Homebrew:

```zsh
brew install ffmpeg
# or:
./setup_ffmpeg.sh --brew
```

---

## 🎬 Common Workflow Recipes

### 1. The Standard Remux (MP4 for Final Cut Pro / DaVinci Resolve)
Copies H.264 / HEVC video bit-for-bit, adds Apple's `hvc1` tag, and converts Blu-ray audio to high-bitrate Apple AudioToolbox AAC:
```zsh
./mkv_to_mp4.py "/path/to/Movie.mkv"
```

### 2. Studio Master Workflow (MOV + Lossless 24-bit PCM Audio)
Copies video untouched and decodes all audio tracks to uncompressed 24-bit PCM (`pcm_s24le`). Perfect for timeline scrubbing with zero audio decompression overhead:
```zsh
./mkv_to_mp4.py "/path/to/Movie.mkv" --container mov
```

### 3. Filter Down to English Audio Only
Blu-ray rips often contain 5+ foreign language and commentary tracks. Keep only the English track(s) for smaller file sizes and cleaner timelines:
```zsh
./mkv_to_mp4.py "/path/to/Movie.mkv" --audio-langs eng --first-audio
```

### 4. Downmix Surround to 2.0 Stereo (YouTube & Commentary)
Automatically mixes 5.1 or 7.1 surround audio down to a pristine 320 kbps stereo track:
```zsh
./mkv_to_mp4.py "/path/to/Movie.mkv" --stereo
```

### 5. Extract Subtitles as External Sidecar Files
Extracts embedded subtitles into `.srt` (text), `.ass` (styled), or `.sup` (Blu-ray PGS) files alongside the output:
```zsh
./mkv_to_mp4.py "/path/to/Movie.mkv" --extract-subs
```

### 6. Batch Convert an Entire Folder or Drive
Recursively searches a folder and saves all converted files into a dedicated editing SSD:
```zsh
./mkv_to_mp4.py "/Volumes/Rips/Movies" -r -o "/Volumes/EditingSSD/Converted"
```

### 7. Inspect Streams Without Converting
Quickly analyze video codec, pixel format, audio channels, HDR/Dolby Vision metadata, VFR frame rates, and chapter count:
```zsh
./inspect_mkvs.sh "/path/to/Movie.mkv"
```

### 8. Preview FFmpeg Commands (Dry Run)
Prints the exact `ffmpeg` command that would be executed without running it:
```zsh
./mkv_to_mp4.py "Movie.mkv" --dry-run
```

### 9. Hardware Apple ProRes 422 Transcode
When timeline performance is prioritized over file size, transcode to Apple ProRes 422 via Apple Silicon `prores_videotoolbox`:
```zsh
./mkv_to_mp4.py "Movie.mkv" --container mov --prores
```

---

## 📖 CLI Command Reference

```
usage: mkv_to_mp4.py [-h] [-o OUTPUT_DIR] [-c {mp4,mov}] [-r]
                     [--audio-langs AUDIO_LANGS] [--first-audio] [--stereo]
                     [--copy-ac3] [--no-faststart] [--extract-subs]
                     [--allow-transcode] [--prores] [--no-chapters]
                     [--overwrite] [--inspect] [--dry-run] [--progress-json]
                     inputs [inputs ...]
```

| Flag | Default | Description |
| :--- | :---: | :--- |
| `inputs` | *required* | One or more `.mkv` files or directories. |
| `-o`, `--output-dir` | Same folder | Target folder for output files. |
| `-c`, `--container` | `mp4` | Container format: `mp4` (AAC audio) or `mov` (lossless 24-bit PCM). |
| `-r`, `--recursive` | `False` | Recursively search subdirectories for `.mkv` files. |
| `--audio-langs` | All | Comma-separated ISO 639-2 language codes (e.g., `eng,jpn`). |
| `--first-audio` | `False` | Retain only the first audio track matching the language filter. |
| `--stereo` | `False` | Downmix 5.1/7.1 audio tracks to 2.0 stereo (320 kbps). |
| `--copy-ac3` | `False` | Pass through AC-3/E-AC-3 without AAC conversion (DaVinci Studio only). |
| `--no-faststart` | `False` | Skip `-movflags +faststart` to save an SSD rewrite pass on 20+ GB files. |
| `--extract-subs` | `False` | Extract subtitles as standalone sidecar files (`.srt`, `.ass`, `.sup`). |
| `--allow-transcode` | `False` | Allow high-quality transcode if video is VC-1, MPEG-2, VP9, or VFR. |
| `--prores` | `False` | Transcode video to Apple ProRes 422 (requires `--container mov`). |
| `--no-chapters` | `False` | Omit chapter markers from the output container. |
| `--overwrite` | `False` | Overwrite existing output files instead of skipping them. |
| `--inspect` | `False` | Print stream details and conversion plan without executing. |
| `--dry-run` | `False` | Print the exact generated FFmpeg commands without converting. |
| `--progress-json` | `False` | Output real-time line-delimited JSON progress events for GUI wrappers. |

---

## 🔬 Under the Hood: Audio Conversion Matrix

Final Cut Pro and DaVinci Resolve have strict rules regarding audio inside MP4 vs. MOV containers:

| Source Audio Codec | Target: `--container mp4` (Default) | Target: `--container mov` | Reason |
| :--- | :--- | :--- | :--- |
| **AAC** | `-c:a copy` (Bit-for-Bit) | `pcm_s24le` (Uncompressed) | AAC is natively supported in MP4; MOV converts to PCM for zero latency. |
| **DTS / DTS-HD MA** | `aac_at` (320k–448k) | `pcm_s24le` (24-bit PCM) | FCP & QuickTime cannot decode DTS in MP4. |
| **Dolby TrueHD** | `aac_at` (320k–448k) | `pcm_s24le` (24-bit PCM) | TrueHD is unsupported in MP4 on Apple video frameworks. |
| **FLAC** | `aac_at` (320k–448k) | `pcm_s24le` (24-bit PCM) | MP4 FLAC support is erratic across NLE versions. |
| **AC-3 / E-AC-3** | `aac_at` (320k–448k)* | `pcm_s24le` (24-bit PCM) | FCP often mutes AC-3 inside MP4. *(Use `--copy-ac3` to pass through).* |
| **7.1 Multi-channel** | Native `aac` (640k) | `pcm_s24le` 8-channel | Avoids Apple AudioToolbox channel mapping bugs on 8-channel layouts. |

---

## 🏗️ Building the macOS App From Source

The desktop app is written in pure **SwiftUI** and compiled directly using `swiftc` without requiring the full Xcode IDE:

```zsh
# Ensure you are in the project root
./macos_app/build_app.sh
```

The build script will:
1. Compile `macos_app/MKVToMP4App.swift` targeting Apple Silicon macOS 13.0+.
2. Dynamically render and package the high-resolution multi-size application icon (`AppIcon.icns`).
3. Embed helper scripts (`mkv_to_mp4.py`, `setup_ffmpeg.sh`, and local `./bin/` if present).
4. Generate the `Info.plist` with drag-and-drop document types and apply ad-hoc code signing.
5. Produce the ready-to-run `Video Converter.app` in the repository root.

---

## 🧪 Running Unit Tests

Test stream analysis, channel mapping, cover art filtering, and argument building:

```zsh
python3 -m unittest discover tests
```

---

## ❓ Frequently Asked Questions (FAQ)

#### Why did my 20 GB Blu-ray file finish in only 15 seconds?
Because the video is **not** re-encoded! The video stream (`H.264` or `HEVC`) is copied bit-for-bit directly from the MKV container into the MP4/MOV container. The only processing is demuxing, remuxing, and converting the audio track.

#### Why do my other converters produce MP4 files with no sound in Final Cut Pro?
Blu-ray rips almost always store audio in DTS-HD Master Audio, Dolby TrueHD, or AC-3. While players like VLC can read those tracks inside an MP4, Apple's AVFoundation framework (used by Final Cut Pro and QuickTime) does not decode DTS or TrueHD in MP4 containers. `Video Converter` detects these streams and converts them to high-bitrate AAC or 24-bit PCM so your audio works immediately.

#### Does this preserve HDR10 and Dolby Vision?
Yes. HDR10 color characteristics (BT.2020, SMPTE ST 2084 / PQ transfer) are preserved bit-for-bit during remuxing. For Dolby Vision, the base HDR10 layer is fully preserved; note that dual-layer Dolby Vision RPU metadata may be ignored by Final Cut Pro depending on the profile.

#### macOS says "Video Converter.app cannot be opened because it is from an unidentified developer."
If you build or download the app without an Apple Developer certificate:
1. Right-click (or Control-click) `Video Converter.app` in Finder.
2. Select **Open**.
3. Click **Open** in the confirmation dialog. (You only need to do this once).

#### How much free disk space is required?
Because the tool preserves your original MKV file and writes atomically to a temporary file, you will need free space roughly equal to the input file size (plus ~10% buffer for faststart). For MOV conversion with ProRes transcode (`--prores`), we recommend 3–5× the original file size.

---

## 📄 License

This project is licensed under the [MIT License](LICENSE). You are free to use, modify, and distribute it for personal, commercial, and studio workflows.
