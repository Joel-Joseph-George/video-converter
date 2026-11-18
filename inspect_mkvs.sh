#!/usr/bin/env zsh
# Inspect MKV files (codecs, audio tracks, HDR, VFR, subtitles) without converting.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
CONVERTER="${SCRIPT_DIR}/mkv_to_mp4.py"

if [[ $# -eq 0 ]]; then
  echo "Usage: ./inspect_mkvs.sh <file-or-folder> [extra mkv_to_mp4.py flags]" >&2
  exit 1
fi

exec /usr/bin/python3 "${CONVERTER}" --inspect "$@"

