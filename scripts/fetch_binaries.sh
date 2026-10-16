#!/usr/bin/env bash
# Downloads the pinned ffmpeg build into Resources/bin and verifies its SHA-256.
set -euo pipefail

FFMPEG_VERSION="9.0.2"
FFMPEG_URL="https://ffmpeg.martin-riedl.de/download/macos/arm64/1789931890_9.0.2/ffmpeg.zip"
FFMPEG_SHA256="c8ed4c4e6978a03c485edbfe4e0a5dc2380f8a30bba5150531b31b094492d924"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/Resources/bin"
mkdir -p "$BIN"

if [[ -x "$BIN/ffmpeg" ]] && "$BIN/ffmpeg" -hide_banner -version 2>/dev/null | head -1 | grep -q "$FFMPEG_VERSION"; then
  echo "ffmpeg $FFMPEG_VERSION already present."
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "Downloading ffmpeg $FFMPEG_VERSION (arm64)…"
curl -fL --progress-bar "$FFMPEG_URL" -o "$WORK/ffmpeg.zip"

echo "Verifying checksum…"
ACTUAL="$(shasum -a 256 "$WORK/ffmpeg.zip" | awk '{print $1}')"
if [[ "$ACTUAL" != "$FFMPEG_SHA256" ]]; then
  echo "Checksum mismatch! expected $FFMPEG_SHA256, got $ACTUAL" >&2
  exit 1
fi

mkdir -p "$WORK/out"
unzip -q "$WORK/ffmpeg.zip" -d "$WORK/out"
install -m 755 "$WORK/out/ffmpeg" "$BIN/ffmpeg"
xattr -c "$BIN/ffmpeg" 2>/dev/null || true
echo "ffmpeg installed to Resources/bin/ffmpeg"
