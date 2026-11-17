#!/bin/sh
# Drives the real app on a simulator, with no taps, to check that a reply keeps streaming and is saved when the app
# leaves the screen. Needs a Debug build, because the app's launch arguments exist only there.
#   UDID=<simulator> scripts/background_check.sh
# Other settings: SOURCE_DIR (the checkout to build, default this one), WORK (scratch folder), PORT (default 8188),
# SLOW_SECONDS (length of the streamed reply, default 25), ONLY=kept, killed or dropped to run one case,
# SCREENSHOT and DROPPED_SCREENSHOT (where the relaunched app and the app after a dropped stream are captured).
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${SOURCE_DIR:-$ROOT}"
: "${UDID:?set UDID to a simulator that is not in use}"
PORT="${PORT:-8188}"
SECONDS_LONG="${SLOW_SECONDS:-25}"
WORK="${WORK:-$(mktemp -d)}"
SCREENSHOT="${SCREENSHOT:-$WORK/relaunched.png}"
DROPPED_SCREENSHOT="${DROPPED_SCREENSHOT:-$WORK/dropped.png}"
APP_ID=com.local.lmchat
FAILED=0
MOCK_PID=""
mkdir -p "$WORK"

stop_mock() { [ -n "$MOCK_PID" ] && { kill "$MOCK_PID"; wait "$MOCK_PID"; } 2>/dev/null; MOCK_PID=""; }
trap 'stop_mock; xcrun simctl terminate "$UDID" "$APP_ID" >/dev/null 2>&1' EXIT

now() { python3 -c 'import time; print(f"{time.time():.2f}")'; }

xcrun simctl boot "$UDID" 2>/dev/null
xcrun simctl bootstatus "$UDID" -b >/dev/null 2>&1
xcodebuild -project "$SRC/LMChat.xcodeproj" -scheme LMChat -destination "platform=iOS Simulator,id=$UDID" \
    -derivedDataPath "$WORK/dd" -quiet build >"$WORK/build.log" 2>&1 || { echo "FAIL build: see $WORK/build.log"; exit 1; }
APP="$WORK/dd/Build/Products/Debug-iphonesimulator/LMChat.app"

start_mock() {
    MOCK_LOG="$WORK/mock-$1.log"
    python3 "$SRC/scripts/mock_openai_server.py" --port "$PORT" >"$MOCK_LOG" 2>&1 &
    MOCK_PID=$!
    for _ in $(seq 50); do grep -q "mock OpenAI" "$MOCK_LOG" && return; sleep 0.1; done
    echo "FAIL the mock server did not start: see $MOCK_LOG"; exit 1
}

fresh_install() {
    xcrun simctl terminate "$UDID" "$APP_ID" >/dev/null 2>&1
    xcrun simctl uninstall "$UDID" "$APP_ID" >/dev/null 2>&1
    xcrun simctl install "$UDID" "$APP"
}

launch_with_reply() {
    xcrun simctl launch "$UDID" "$APP_ID" --debug-server "http://127.0.0.1:$PORT/v1" --debug-send "/slow $SECONDS_LONG ${1:-}" >/dev/null
}

# What the app saved: "assistant_chars interrupted ends_with_END", or "none".
saved_reply() {
    file="$(xcrun simctl get_app_container "$UDID" "$APP_ID" data)/Library/Application Support/LMChat/conversations.json"
    python3 - "$file" <<'PY'
import json, sys
try:
    chats = json.load(open(sys.argv[1]))
except (OSError, ValueError):
    print("none"); sys.exit()
replies = [m for c in chats for m in c["messages"] if m["role"] == "assistant"]
if not replies:
    print("none")
else:
    r = replies[-1]
    print(len(r["content"]), str(r.get("interrupted", False)).lower(), str(r["content"].rstrip().endswith("END")).lower())
PY
}

result() {
    if [ "$2" = ok ]; then echo "PASS $1: $3"; else echo "FAIL $1: $3"; FAILED=1; fi
}

if [ -z "${ONLY:-}" ] || [ "$ONLY" = kept ]; then
    start_mock kept
    fresh_install
    launch_with_reply
    sleep 5
    left_at="$(now)"
    xcrun simctl launch "$UDID" com.apple.mobilesafari >/dev/null
    python3 - "$(xcrun simctl get_app_container "$UDID" "$APP_ID" data)/Library/Application Support/LMChat/conversations.json" \
        "$left_at" $((SECONDS_LONG + 30)) <<'PY'
import json, sys, time
path, left_at, budget = sys.argv[1], float(sys.argv[2]), int(sys.argv[3])

def reply():
    try:
        messages = [m for c in json.load(open(path)) for m in c["messages"] if m["role"] == "assistant"]
    except (OSError, ValueError):
        return 0, False
    if not messages:
        return 0, False
    last = messages[-1]
    return len(last["content"]), last["content"].rstrip().endswith("END") and not last.get("interrupted", False)

# A backgrounded app reads the stream later than the server writes it, so the server finishing says nothing about
# the app. Wait for the app's own file.
chars, changed_at, finished = 0, left_at, False
while time.time() < left_at + budget and not finished:
    now_chars, finished = reply()
    if now_chars != chars:
        chars, changed_at = now_chars, time.time()
    time.sleep(0.5)
print(f"the reply on disk last grew {changed_at - left_at:.1f}s after the app left the foreground ({chars} characters, "
      f"{'finished' if finished else f'not finished after {budget}s'})")
PY
    started_at="$(sed -n 's/^\[\([0-9.]*\)\] slow stream start.*/\1/p' "$MOCK_LOG" | head -1)"
    python3 -c "import sys; print(f'the app left the foreground {float(sys.argv[1]) - float(sys.argv[2]):.1f}s into the stream')" "$left_at" "${started_at:-0}"
    grep -E "complete|broken" "$MOCK_LOG" | sed 's/^/  mock: /'
    set -- $(saved_reply)
    if grep -q "stream complete.*the client closed the connection" "$MOCK_LOG" && [ "${3:-}" = true ] && [ "${2:-}" = false ]; then
        result "kept going" ok "the app read the mock's whole stream while in the background and saved the whole reply ($1 characters)"
    else
        result "kept going" fail "mock: $(grep -E 'stream (complete|broken)' "$MOCK_LOG" | head -1 | cut -c1-140 || true); saved: ${1:-none} characters, interrupted: ${2:-false}, ends with END: ${3:-false}"
    fi
    stop_mock
fi

if [ -z "${ONLY:-}" ] || [ "$ONLY" = killed ]; then
    start_mock killed
    fresh_install
    launch_with_reply
    sleep 8
    xcrun simctl terminate "$UDID" "$APP_ID" >/dev/null
    set -- $(saved_reply)
    if [ "${1:-none}" != none ] && [ "$1" -gt 0 ] && [ "$2" = true ] && [ "$3" = false ]; then
        result "killed" ok "the app was terminated mid-stream and the file holds $1 characters of the reply, marked interrupted"
    else
        result "killed" fail "saved: ${1:-none} characters, interrupted: ${2:-false}"
    fi
    stop_mock
    xcrun simctl launch "$UDID" "$APP_ID" >/dev/null
    sleep 4
    xcrun simctl io "$UDID" screenshot "$SCREENSHOT" >/dev/null 2>&1 && echo "screenshot of the relaunched app: $SCREENSHOT"
fi

if [ -z "${ONLY:-}" ] || [ "$ONLY" = dropped ]; then
    start_mock dropped
    fresh_install
    launch_with_reply "drop 12"
    sleep 5
    xcrun simctl launch "$UDID" com.apple.mobilesafari >/dev/null
    # The app reads later than the server writes, so wait for the app's own file to show the reply ended.
    python3 - "$(xcrun simctl get_app_container "$UDID" "$APP_ID" data)/Library/Application Support/LMChat/conversations.json" <<'PY'
import json, sys, time
for _ in range(120):
    try:
        messages = [m for c in json.load(open(sys.argv[1])) for m in c["messages"] if m["role"] == "assistant"]
    except (OSError, ValueError):
        messages = []
    if messages and not messages[-1].get("interrupted", False):
        break
    time.sleep(0.5)
PY
    xcrun simctl launch "$UDID" "$APP_ID" >/dev/null
    sleep 3
    xcrun simctl io "$UDID" screenshot "$DROPPED_SCREENSHOT" >/dev/null 2>&1
    set -- $(saved_reply)
    if grep -q "stream dropped" "$MOCK_LOG" && [ "${1:-none}" != none ] && [ "$1" -gt 0 ] && [ "$2" = false ] && [ "$3" = false ]; then
        result "dropped" ok "the stream was reset in the background and the app kept $1 characters of the reply; screenshot: $DROPPED_SCREENSHOT"
    else
        result "dropped" fail "mock: $(grep -E 'stream (complete|broken|dropped)' "$MOCK_LOG" | head -1 | cut -c1-140 || true); saved: ${1:-none} characters, interrupted: ${2:-false}, ends with END: ${3:-false}"
    fi
    stop_mock
fi

exit $FAILED
