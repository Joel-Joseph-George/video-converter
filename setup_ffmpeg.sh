#!/usr/bin/env zsh
# Install native Apple Silicon (arm64) ffmpeg and ffprobe for mkv_to_mp4.py.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
BIN_DIR="${SCRIPT_DIR}/bin"
if [[ -n "${1:-}" && "${1:-}" != "--brew" ]]; then
  BIN_DIR="$1"
fi
ARCH="$(uname -m)"

if [[ -z "${1:-}" ]] && command -v ffmpeg >/dev/null 2>&1 && command -v ffprobe >/dev/null 2>&1; then
  echo "ffmpeg and ffprobe are already available in PATH:"
  command -v ffmpeg ffprobe
  exit 0
fi

if [[ "${1:-}" == "--brew" ]]; then
  if ! command -v brew >/dev/null 2>&1; then
    echo "Homebrew is not installed. Run without --brew for a standalone ./bin install." >&2
    exit 1
  fi
  exec brew install ffmpeg
fi

if [[ "${ARCH}" != "arm64" ]]; then
  echo "This standalone downloader targets Apple Silicon (arm64), detected: ${ARCH}" >&2
  exit 1
fi

mkdir -p "${BIN_DIR}"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

download_and_verify() {
  local tool="$1"
  local base_url="https://ffmpeg.martin-riedl.de/redirect/latest/macos/arm64/release"
  local zip_path="${TMP_DIR}/${tool}.zip"
  local sha_path="${TMP_DIR}/${tool}.zip.sha256"

  echo "Downloading ${tool} (macOS arm64 release)..."
  local effective_url
  effective_url="$(curl -fsSL -w '%{url_effective}' -o "${zip_path}" "${base_url}/${tool}.zip")"

  echo "Verifying SHA-256 for ${tool}..."
  curl -fsSL -o "${sha_path}" "${effective_url}.sha256"

  local expected actual
  expected="$(awk '{print $1}' "${sha_path}" | tr '[:upper:]' '[:lower:]')"
  actual="$(shasum -a 256 "${zip_path}" | awk '{print $1}' | tr '[:upper:]' '[:lower:]')"
  if [[ -z "${expected}" || "${expected}" != "${actual}" ]]; then
    echo "SHA-256 verification failed for ${tool}.zip!" >&2
    echo "  Expected: ${expected}" >&2
    echo "  Actual  : ${actual}" >&2
    exit 1
  fi

  echo "Installing ${tool}..."
  unzip -oq "${zip_path}" -d "${TMP_DIR}/${tool}_unzipped"
  local binary
  binary="$(find "${TMP_DIR}/${tool}_unzipped" -type f -name "${tool}" | head -n 1)"
  if [[ -z "${binary}" ]]; then
    echo "Could not locate '${tool}' binary inside ${tool}.zip" >&2
    exit 1
  fi

  mv -f "${binary}" "${BIN_DIR}/${tool}"
  chmod +x "${BIN_DIR}/${tool}"
  xattr -d com.apple.quarantine "${BIN_DIR}/${tool}" 2>/dev/null || true
}

download_and_verify ffmpeg
download_and_verify ffprobe

echo "\nInstalled successfully to ${BIN_DIR}:"
"${BIN_DIR}/ffmpeg" -version | head -n 2
"${BIN_DIR}/ffprobe" -version | head -n 2

