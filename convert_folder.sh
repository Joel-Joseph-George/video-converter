#!/usr/bin/env zsh
# Quick launcher to convert MKV files or folders into FCP/DaVinci-ready MP4s.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
CONVERTER="${SCRIPT_DIR}/mkv_to_mp4.py"

if [[ $# -eq 0 ]]; then
  echo "Drag and drop an MKV file or folder here, then press Return:"
  read -r INPUT_PATH
  # Strip optional surrounding quotes added by Terminal drag-and-drop
  INPUT_PATH="${INPUT_PATH#\'}"
  INPUT_PATH="${INPUT_PATH%\'}"
  INPUT_PATH="${INPUT_PATH#\"}"
  INPUT_PATH="${INPUT_PATH%\"}"
  if [[ -z "${INPUT_PATH}" ]]; then
    echo "No path provided." >&2
    exit 1
  fi
  exec /usr/bin/python3 "${CONVERTER}" "${INPUT_PATH}"
fi

exec /usr/bin/python3 "${CONVERTER}" "$@"

