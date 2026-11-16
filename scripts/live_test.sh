#!/bin/sh
# Runs the live image tool test against real servers. Set LIVE_CHAT_BASE, LIVE_CHAT_KEY, LIVE_CHAT_MODEL,
# LIVE_IMAGE_BASE, LIVE_IMAGE_KEY and LIVE_IMAGE_MODEL (and optionally LIVE_OUT_DIR) in .env or the shell.
set -eu
cd "$(dirname "$0")/.."
if [ -f .env ]; then set -a; . ./.env; set +a; fi
exec scripts/test.sh --filter LiveImageToolTests
