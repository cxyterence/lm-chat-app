# LM Chat

An iOS chat client for locally hosted LLMs. Point it at any OpenAI-compatible endpoint (LM Studio, Ollama `/v1`, `llama-server`, vLLM, or a remote HTTPS host), pick a model from `/v1/models`, and chat with streamed replies. Conversations are stored on device.

A connection is a URL and an optional API key, plus the model and system prompt last used with it. Save as many as you like under Settings > Connections and tap one to switch, for example between a home server and a hosted API. Keys are kept in the Keychain. On an `api.openai.com` connection the model list shows only text models from gpt-6 on, plus gpt-4o-mini.

## Layout

- `Sources/ChatCore` Foundation-only client, SSE decoding, `<think>` splitting, persistence.
- `Sources/ChatUI` SwiftUI views and `ChatStore`. Public entry point is `RootView`.
- `Sources/chatcli` command-line client built on ChatCore.
- `Sources/uisnapshot` macOS-only tool that renders every theme to PNGs: `swift run uisnapshot <outdir>`.
- `App/` the only code in the Xcode app target.
- `scripts/mock_openai_server.py` stdlib mock server for offline testing.

## Run the app

```sh
xcodegen generate   # only needed after editing project.yml
open LMChat.xcodeproj
```

Pick an iOS 17+ simulator or device and run the `LMChat` scheme. Add a connection in Settings > Connections:

| Server | Address |
| --- | --- |
| LM Studio | `192.168.1.5:1234` |
| Ollama | `192.168.1.5:11434` |
| llama.cpp | `192.168.1.5:8080` |
| Remote | `https://box.tailnet.ts.net/v1` |

A bare host gets `http://` and `/v1` added. Anything with an explicit scheme or path is kept as typed (trailing slash trimmed).

## chatcli

```sh
swift run chatcli --base 127.0.0.1:1234 --models
swift run chatcli --base 127.0.0.1:1234 --model <id> [--key K] [--effort low] "Hello"
swift run chatcli --base 127.0.0.1:1234 --model <id> --efforts
swift run chatcli --base 127.0.0.1:1234 --title "what is NVFP4?"
```

Reasoning goes to stderr dimmed, the answer to stdout. Failures exit non-zero. `--title` prints the title the app would give a chat starting with that prompt. `--efforts` prints the reasoning effort levels the model accepts, the same check the app runs before showing its effort slider.

## Smoke test against your server

```sh
cp .env.example .env   # set LLM_BASE_URI, optionally LLM_API_KEY and LLM_MODEL
scripts/smoke.sh          # your server
scripts/smoke.sh openai   # OpenAI, using OPENAI_API_KEY and OPENAI_MODEL
```

It lists the server's models and streams one reply through `chatcli`. `.env` is git-ignored.

## Tests

```sh
swift test            # with Xcode installed
scripts/test.sh       # with Command Line Tools only
python3 scripts/mock_openai_server.py --port 8099
```
