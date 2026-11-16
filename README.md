# LM Chat

An iOS chat client for locally hosted LLMs. Point it at any OpenAI-compatible endpoint (LM Studio, Ollama `/v1`, `llama-server`, vLLM, or a remote HTTPS host), pick a model from `/v1/models`, and chat with streamed replies. Conversations are stored on device.

A connection is a URL and an optional API key, plus the model and system prompt last used with it. Save as many as you like under Settings > Connections and tap one to switch, for example between a home server and a hosted API. Keys are kept in the Keychain. On an `api.openai.com` connection the model list shows only text models from gpt-6 on, plus gpt-4o-mini.

## Layout

- `Sources/ChatCore` Foundation-only client, SSE decoding, `<think>` splitting, persistence.
- `Sources/ChatUI` SwiftUI views and `ChatStore`. Public entry point is `RootView`.
- `Sources/chatcli` command-line client built on ChatCore.
- `Sources/uisnapshot` macOS-only tool that renders every theme to PNGs: `swift run uisnapshot <outdir>`. Set `UISNAPSHOT_THEMES=light,dark` to render only some.
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

Pictures come from an image model that chat models call as a tool, not from chatting with the image model. Settings › Image Generation picks one of the image models a saved connection serves, fetched with that connection's own key, or None. With one picked, every reply offers the model a `generate_image` tool beside any MCP tools, so use a chat model that supports tool calling. Ask in plain language, such as "draw a red fox in snow, widescreen", or attach a photo and say "make it night". The model writes a detailed prompt, an optional aspect ratio and resolution, and the numbers of the pictures to edit, and the app sends them to the image connection. With no source pictures that is `/v1/images/generations`. With source pictures it is `/v1/images/edits` as a multipart form. The picture shows in the reply. Tap it to view it full screen, or long-press to share or save it. The tool asks for no approval, since it only adds a picture to the chat. If the image server refuses, the model is handed its message and can explain or try again.

Every picture in a chat, the photos you attached and the ones the tool drew, is labelled "image 1", "image 2" and so on in order, so "now make it night" can edit image 1. The model learns your photos' labels from a note added to your message as it is sent, such as `(Attached: image 1)`, and a drawn picture's label from the tool's result. Your message is stored as you typed it. Pictures the tool drew are never sent back to the model as pixels. A size is sent as `WxH` rounded to a multiple of 16. An edit that names no shape or size asks for its first source picture's own, because SGLang refuses an edit without one. OpenAI gets a size only when the model names one. The app knows a model makes images when an SGLang diffusion server lists it with a task type ending in `2i` in any letter case (such as `t2i` or `I2I`), or when OpenAI lists it as `gpt-image-*` or `chatgpt-image-latest`. Such models are left out of the chat model picker. The mock server lists a `mock-image` model on both image endpoints, but its chat models never call `generate_image`.

Long-press a message you sent and choose Edit to change it. Sending the edit asks the model again from that point and erases everything after it. Photos only the erased messages used are deleted.

Type `/` in the message field to see commands. `/compact` asks the model to summarize the chat so far, then sends that summary in place of the earlier messages, which stay on screen. Text after the command, like `/compact keep the code`, tells it what to make sure it keeps. A summary that fails, is stopped, or hits the model's output limit is thrown away so no history is lost. A message that starts with `/` but names no command is sent as ordinary text.

`/web-search <query>` searches Google through [Serper](https://serper.dev) and has the model answer from the top results, citing them as numbered links. Add your Serper key in Settings › API Keys; it is kept in the Keychain. The results are saved with the question, so follow-up messages can still refer to them, and they are listed under it as sources. Editing the question searches again. To test against the mock server, launch with `-serperURL http://<mac>:8099`.

Settings › MCP Connections adds MCP servers that give the model tools. Tools from every server that is switched on are offered to the model in each chat; when it calls one, the app runs it, shows the call under the reply (tap it for the arguments and result), and asks the model again with the result, for up to 10 rounds. A tool the server doesn't mark read-only waits for you to Allow or Decline it. Servers are reached over Streamable HTTP with an optional Bearer token kept in the Keychain. If a model's server rejects requests that carry tools, the app asks it again without them and stops offering tools to that model.

**GitHub.** Add GitHub fills in GitHub's hosted server, `https://api.githubcopilot.com/mcp/readonly`, which offers only tools that read. Paste a [fine-grained personal access token](https://github.com/settings/personal-access-tokens/new) with read access to the repositories you want the model to see. Turning on Allow changes switches to the full server, whose tools that write ask before running. Every tool's description is sent with each message, so a small local model's context fills faster with more servers switched on.

The mock server also speaks MCP at `/mcp` (all tools) and `/mcp/readonly`, with the token `mock-token`, and its models call a tool when a prompt says "use <tool name>".

## Developer tools

Every request the app makes for a reply is kept in memory beside it, with your key shown as `$API_KEY`. Long-press a reply and choose Inspect, or tap the line under it, such as `0.8 s to first token · 42 tok/s · 1,204 tokens`. A server that reports no token counts gets only the time. The sheet opens on a summary, then one row per request: the reply's own, the one a tool made for a picture, and any you resend. A failed request shows its status and the server's message in red. Tap a row for its request and response as text, with the headers above and Copy, Copy as curl and Edit and Resend below. Photos show as short tokens such as `<image 1: 312 KB>`, in the text and in the curl command. A text over 20,000 characters shows its start and its end and says how much it left out. Copy still takes all of it. Requests are not saved. After a relaunch old replies have no Inspect, editing, retrying or deleting drops a reply's requests, and only the newest 40 requests or 24 MB of bodies are kept. A reply that fails before it shows anything has no message to hang its request on, so it stays behind the error banner's Inspect request until you dismiss the error or retry.

Edit and Resend opens the request body in a plain text editor. Send posts it to the same address with that connection's key, or the image connection's key for a picture request, and adds the answer as a Resent request. The chat is never changed. Leave a photo token where it is to send the photo again.

When the app changes a request for you, the reply says so in a caption under it. Tools are left out when the server refuses them, and stay out of later replies from that model until you quit the app. Reasoning is turned off when the model takes tools only that way. A reasoning level is swapped when the model doesn't take the one you picked. A size is noted when the app chose it for an image edit. Token counts are not asked for when the server refuses `stream_options`. These notes are saved with the chat.

## chatcli

```sh
swift run chatcli --base 127.0.0.1:1234 --models
swift run chatcli --base 127.0.0.1:1234 --model <id> [--key K] [--effort low] "Hello"
swift run chatcli --base 127.0.0.1:1234 --model <id> --efforts
swift run chatcli --base 127.0.0.1:1234 --model <id> --capabilities
swift run chatcli --base 127.0.0.1:1234 --model <id> --inspect "Hello"
swift run chatcli --base 127.0.0.1:1234 --title "what is NVFP4?"
swift run chatcli --base 127.0.0.1:1234 --model <id> --image photo.heic "What is in this photo?"
swift run chatcli --base 127.0.0.1:8099 --model mock-image --image-out out.png --ar 16:9 --res 1280 "a red fox in snow"
```

Reasoning goes to stderr dimmed, the answer to stdout. Failures exit non-zero. `--title` prints the title the app would give a chat starting with that prompt. `--efforts` prints the reasoning effort levels the model accepts, the same check the app runs before showing its effort slider. `--capabilities` asks the model whether it takes tools and pictures, which reasoning levels it accepts and how much context it has, with a handful of one-token requests. `--inspect` adds every request the run made, after the reply: status, timing, token counts, then a `curl` command that repeats it with `$API_KEY` for the key. `--image` attaches a photo, prepared the way the app prepares one, and can repeat. `--image-out <file>` probes an image server. It sends the prompt straight to the image model, with no chat model or tool in between, and writes the picture it returns. Add `--image` and the model edits those photos instead. `--ar W:H` picks the shape and `--res N` the long edge, as in `--ar 16:9 --res 1280`. `--res` takes `1k`, `2k`, `4k`, or 256 to 4096 pixels.

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

`scripts/live_test.sh` drives the real `ChatStore` against a real chat model and a real image model. It asks for a red fox in snow, widescreen, then for it at night, and checks that two pictures come back, the first wider than tall, and that the second call edits image 1. Set `LIVE_CHAT_BASE`, `LIVE_CHAT_KEY`, `LIVE_CHAT_MODEL`, `LIVE_IMAGE_BASE`, `LIVE_IMAGE_KEY` and `LIVE_IMAGE_MODEL` in `.env` or the shell, and `LIVE_OUT_DIR` to keep the pictures. Without all six the test is skipped.
