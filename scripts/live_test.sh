#!/bin/sh
# Runs a live test against real servers. Usage: scripts/live_test.sh [LiveImageToolTests | LiveDevToolsTests | LiveFetchTests]
# LiveImageToolTests (the default) needs LIVE_CHAT_BASE, LIVE_CHAT_KEY, LIVE_CHAT_MODEL, LIVE_IMAGE_BASE,
# LIVE_IMAGE_KEY and LIVE_IMAGE_MODEL. LiveDevToolsTests needs only the three LIVE_CHAT_* ones.
# LiveFetchTests needs the same three, runs on both APIs, and reads https://example.com from the internet.
# The first two take LIVE_OUT_DIR to keep what they write. Set the variables in .env or the shell.
set -eu
cd "$(dirname "$0")/.."
if [ -f .env ]; then set -a; . ./.env; set +a; fi
exec scripts/test.sh --filter "${1:-LiveImageToolTests}"
