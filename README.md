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

The photo button beside the message field attaches up to four photos. Each is downscaled to 1536 px on its long edge and sent as a JPEG `image_url` part, so the model has to accept images. A text-only model's refusal shows in the error banner. Photos are saved as files in `images/` beside `conversations.json`, which holds only their IDs, so saving a chat stays fast however many photos it has.

Long-press a message you sent and choose Edit to change it. Sending the edit asks the model again from that point and erases everything after it. Photos only the erased messages used are deleted.

Type `/` in the message field to see commands. `/compact` asks the model to summarize the chat so far, then sends that summary in place of the earlier messages, which stay on screen. Text after the command, like `/compact keep the code`, tells it what to make sure it keeps. A summary that fails, is stopped, or hits the model's output limit is thrown away so no history is lost. A message that starts with `/` but names no command is sent as ordinary text.

`/web-search <query>` searches Google through [Serper](https://serper.dev) and has the model answer from the top results, citing them as numbered links. Add your Serper key in Settings › API Keys; it is kept in the Keychain. The results are saved with the question, so follow-up messages can still refer to them, and they are listed under it as sources. Editing the question searches again. To test against the mock server, launch with `-serperURL http://<mac>:8099`.

Settings › MCP Connections adds MCP servers that give the model tools. Tools from every server that is switched on are offered to the model in each chat; when it calls one, the app runs it, shows the call under the reply (tap it for the arguments and result), and asks the model again with the result, for up to 10 rounds. A tool the server doesn't mark read-only waits for you to Allow or Decline it. Servers are reached over Streamable HTTP with an optional Bearer token kept in the Keychain. If a model's server rejects requests that carry tools, the app asks it again without them and stops offering tools to that model.

**GitHub.** Add GitHub fills in GitHub's hosted server, `https://api.githubcopilot.com/mcp/readonly`, which offers only tools that read. Paste a [fine-grained personal access token](https://github.com/settings/personal-access-tokens/new) with read access to the repositories you want the model to see. Turning on Allow changes switches to the full server, whose tools that write ask before running. Every tool's description is sent with each message, so a small local model's context fills faster with more servers switched on.

The mock server also speaks MCP at `/mcp` (all tools) and `/mcp/readonly`, with the token `mock-token`, and its models call a tool when a prompt says "use <tool name>".

## chatcli

```sh
swift run chatcli --base 127.0.0.1:1234 --models
swift run chatcli --base 127.0.0.1:1234 --model <id> [--key K] [--effort low] "Hello"
swift run chatcli --base 127.0.0.1:1234 --model <id> --efforts
swift run chatcli --base 127.0.0.1:1234 --title "what is NVFP4?"
swift run chatcli --base 127.0.0.1:1234 --model <id> --image photo.heic "What is in this photo?"
```

Reasoning goes to stderr dimmed, the answer to stdout. Failures exit non-zero. `--title` prints the title the app would give a chat starting with that prompt. `--efforts` prints the reasoning effort levels the model accepts, the same check the app runs before showing its effort slider. `--image` attaches a photo, prepared the way the app prepares one, and can repeat.

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
