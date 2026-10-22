#!/bin/sh
# Regenerates the e2e fixture audio: quiet sine tones, mono MP3 at 24 kb/s, so
# they stay tiny in git and play in both the simulator and Playwright's Chromium.
#   sh e2e/fixtures/audio/make.sh
set -eu
cd "$(dirname "$0")"
FFMPEG="${FFMPEG:-$HOME/.local/bin/ffmpeg}"
tone() { # name seconds frequency
  "$FFMPEG" -hide_banner -loglevel error -y -f lavfi -i "sine=frequency=$3:sample_rate=22050:duration=$2" \
    -af "volume=0.04" -ac 1 -c:a libmp3lame -b:a 24k "$1.mp3"
}
tone tone-30s 30 440
tone tone-40s 40 523
tone tone-45s 45 587
tone tone-60s 60 659
