#!/bin/sh
# Drives the real app on a simulator, with no taps, to check that a reply keeps streaming and is saved when the app
# leaves the screen. Needs a Debug build, because the app's launch arguments exist only there.
#   UDID=<simulator> scripts/background_check.sh
# Other settings: SOURCE_DIR (the checkout to build, default this one), WORK (scratch folder), PORT (default 8188),
# SLOW_SECONDS (length of the streamed reply, default 25), LONG_SECONDS (the long case's reply, default 75),
# ONLY=kept, long, killed or dropped to run one case (long prints SKIP where the system refuses continued processing
# tasks, as the iOS 27.2 simulator does),
# SCREENSHOT and DROPPED_SCREENSHOT (where the relaunched app and the app after a dropped stream are captured).
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${SOURCE_DIR:-$ROOT}"
: "${UDID:?set UDID to a simulator that is not in use}"
PORT="${PORT:-8188}"
SECONDS_LONG="${SLOW_SECONDS:-25}"
LONG_SECONDS="${LONG_SECONDS:-75}"
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
    xcrun simctl launch "$UDID" "$APP_ID" --debug-server "http://127.0.0.1:$PORT/v1" --debug-send "/slow ${STREAM_SECONDS:-$SECONDS_LONG} ${1:-}" >/dev/null
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

# Why the system refused the continued processing task the app asked for since $1 (epoch seconds), or nothing.
task_refusal() {
    xcrun simctl spawn "$UDID" log show --info --style compact --start "$(date -j -f %s "${1%.*}" '+%Y-%m-%d %H:%M:%S')" \
        --predicate 'subsystem == "com.local.lmchat" AND eventMessage CONTAINS "refused the continued task"' 2>/dev/null |
        sed -n 's/.*refused the continued task: //p' | tail -1
}

# Leaves the app mid-stream and waits for the app's own file to hold the whole reply. $1 names the mock log and the
# case, $2 the seconds the mock takes. MIN_AFTER_LEAVING, if set, is how long after leaving the reply must still have
# been arriving for the case to mean anything, so a long case can't pass on a reply that finished inside the grant.
leave_and_wait() {
    case_name="$1"; stream_seconds="$2"
    STREAM_SECONDS="$stream_seconds"
    start_mock "$case_name"
    fresh_install
    launch_with_reply
    sleep 5
    left_at="$(now)"
    xcrun simctl launch "$UDID" com.apple.mobilesafari >/dev/null
    python3 - "$(xcrun simctl get_app_container "$UDID" "$APP_ID" data)/Library/Application Support/LMChat/conversations.json" \
        "$left_at" $((stream_seconds + 30)) "$MOCK_LOG" "${MIN_AFTER_LEAVING:-0}" >"$WORK/wait-$case_name.txt" <<'PY'
import json, os, re, sys, time
path, left_at, budget, mock_log, min_after = sys.argv[1], float(sys.argv[2]), int(sys.argv[3]), sys.argv[4], float(sys.argv[5])

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
# The file is replaced whole, so its modification time is when the finished reply landed, to better than the poll.
written = re.search(r"^\[([0-9.]+)\] stream written", open(mock_log).read(), re.M)
if finished and written:
    print(f"lag: the app's file showed the finished reply {os.path.getmtime(path) - float(written.group(1)):.1f}s after "
          "the mock finished writing it (the iOS grant is about 30s from leaving the foreground)")
else:
    print("lag: not measured (the reply did not finish or the mock did not log that it finished writing)")
if finished and changed_at - left_at < min_after:
    print(f"TOO SHORT: the reply finished {changed_at - left_at:.1f}s after leaving, inside the {min_after:.0f}s this case needs", file=sys.stderr)
    sys.exit(3)
PY
    short=$?
    cat "$WORK/wait-$case_name.txt"
    started_at="$(sed -n 's/^\[\([0-9.]*\)\] slow stream start.*/\1/p' "$MOCK_LOG" | head -1)"
    python3 -c "import sys; print(f'the app left the foreground {float(sys.argv[1]) - float(sys.argv[2]):.1f}s into the stream')" "$left_at" "${started_at:-0}"
    grep -E "complete|broken" "$MOCK_LOG" | sed 's/^/  mock: /'
    label="$3"
    set -- $(saved_reply)
    refusal=""
    [ "${MIN_AFTER_LEAVING:-0}" != 0 ] && refusal="$(task_refusal "$left_at")"
    if [ "$short" = 3 ]; then
        result "$label" fail "the reply finished too soon after leaving for this case to prove anything"
    elif [ -n "$refusal" ] && [ "${3:-}" != true ]; then
        echo "SKIP $label: the system refused the continued processing task ($refusal), so only the 30s grant covered the reply and it was cut at $1 characters (interrupted: ${2:-false}). Run this case where the system accepts the task."
    elif grep -q "stream complete.*the client closed the connection" "$MOCK_LOG" && [ "${3:-}" = true ] && [ "${2:-}" = false ]; then
        result "$label" ok "the app read the mock's whole stream while in the background and saved the whole reply ($1 characters)"
    else
        result "$label" fail "mock: $(grep -E 'stream (complete|broken)' "$MOCK_LOG" | head -1 | cut -c1-140 || true); saved: ${1:-none} characters, interrupted: ${2:-false}, ends with END: ${3:-false}"
    fi
    stop_mock
    unset STREAM_SECONDS
}

if [ -z "${ONLY:-}" ] || [ "$ONLY" = kept ]; then
    leave_and_wait kept "$SECONDS_LONG" "kept going"
fi

if [ -z "${ONLY:-}" ] || [ "$ONLY" = long ]; then
    MIN_AFTER_LEAVING=60 leave_and_wait long "$LONG_SECONDS" "long reply"
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
