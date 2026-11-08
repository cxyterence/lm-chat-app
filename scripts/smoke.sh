#!/bin/sh
set -eu
cd "$(dirname "$0")/.."

[ -f .env ] || { echo "error: no .env. Copy .env.example to .env and fill it in." >&2; exit 1; }
set -a; . ./.env; set +a
case "${1:-}" in
    "") ;;
    openai)
        : "${OPENAI_API_KEY:?set OPENAI_API_KEY in .env}"
        LLM_BASE_URI="${OPENAI_BASE_URI:-https://api.openai.com/v1}"
        LLM_API_KEY="$OPENAI_API_KEY"
        LLM_MODEL="${OPENAI_MODEL:?set OPENAI_MODEL in .env}"
        LLM_REASONING_EFFORT="${OPENAI_REASONING_EFFORT:-}"
        ;;
    *) echo "usage: scripts/smoke.sh [openai]" >&2; exit 2 ;;
esac
: "${LLM_BASE_URI:?set LLM_BASE_URI in .env}"

swift build -q --product chatcli
cli="$(swift build --show-bin-path)/chatcli"

set -- --base "$LLM_BASE_URI" --key "${LLM_API_KEY:-}"
echo "models:"
"$cli" "$@" --models

[ -n "${LLM_MODEL:-}" ] && set -- "$@" --model "$LLM_MODEL"
[ -n "${LLM_REASONING_EFFORT:-}" ] && set -- "$@" --effort "$LLM_REASONING_EFFORT"
reply=$("$cli" "$@" "${LLM_PROMPT:-Reply with one short sentence.}")
[ -n "$reply" ] || { echo "error: server streamed an empty reply" >&2; exit 1; }
echo "reply: $reply"
