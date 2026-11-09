#!/usr/bin/env python3
"""Stdlib-only OpenAI-compatible mock for exercising chatcli and the app.

Models:
  mock-chat       plain streamed content
  mock-reasoning  reasoning_content deltas, then content
  mock-ollama     `reasoning` deltas (Ollama style), then content
  mock-think      <think>..</think> inline in content, tags split across chunks
A prompt starting with "/long" streams a long Markdown reply in irregular bursts, like a real network.
On mock-reasoning, "/long" streams a long bursty reasoning section first.
On mock-reasoning, "/huge" streams ~20k characters of reasoning then ~6k of Markdown, fast, as a load test.
"/spans" streams inline formatting slowly, three characters at a time, to show half-finished spans.
Image parts are acknowledged with their sizes, except by mock-think, which rejects them like a text-only model.
Set MOCK_API_KEY to require `Authorization: Bearer <key>`. Set MOCK_EXTRA_MODELS=96 to list a long model list like OpenAI's.
"""
import argparse
import base64
from itertools import takewhile
import re
import json
import os
import random
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MODELS = ["mock-chat", "mock-reasoning", "mock-ollama", "mock-think"]
# A long list like OpenAI's (~100 ids), to exercise the model picker.
MODELS += [f"mock-extra-{i:03}" for i in range(int(os.environ.get("MOCK_EXTRA_MODELS", "0")))]
# Like vLLM with the user's template. Other models ignore reasoning_effort, as llama.cpp does.
EFFORTS = {"mock-reasoning": {"none", "low", "medium", "xhigh"}}
TEXT_ONLY = {"mock-think"}


MCP_TOOLS = [
    {"name": "get_me", "description": "Who the token belongs to", "result": "You are mock-user (Mock User).",
     "inputSchema": {"type": "object", "properties": {}}, "annotations": {"readOnlyHint": True}},
    {"name": "list_repos", "description": "Repositories you can read", "result": "mock-user/app, mock-user/site",
     "inputSchema": {"type": "object", "properties": {}}, "annotations": {"readOnlyHint": True}},
    {"name": "create_issue", "description": "Open an issue", "result": "Created issue #7.",
     "inputSchema": {"type": "object", "properties": {"title": {"type": "string"}}}, "annotations": {"readOnlyHint": False}},
]


def chunk(delta, finish=None):
    return {"object": "chat.completion.chunk",
            "choices": [{"index": 0, "delta": delta, "finish_reason": finish}]}


def script(model, reply):
    words = [w + " " for w in reply.split()]
    if model == "mock-reasoning":
        return [chunk({"reasoning_content": t}) for t in ["Let me ", "think ", "about it. "]] + \
               [chunk({"content": w}) for w in words]
    if model == "mock-ollama":
        return [chunk({"reasoning": t}) for t in ["Hmm, ", "okay. "]] + \
               [chunk({"content": w}) for w in words]
    if model == "mock-think":
        return [chunk({"content": t}) for t in ["<thi", "nk>Pondering ", "the que", "stion</th", "ink>\n\n"]] + \
               [chunk({"content": w}) for w in words]
    return [chunk({"content": w}) for w in words]


LONG_REPLY = """## How NVFP4 works

NVFP4 stores each weight in **4 bits** using the E2M1 layout, and groups values into blocks of 16 that share an FP8 scale.

### Why blocks help
1. A single outlier only stretches the scale of its own block
2. The FP8 scale keeps more dynamic range than an integer scale
3. A per-tensor FP32 scale covers what the block scales cannot

> In practice accuracy lands close to FP8 for most large models.

| Format | Bits per value | Scale granularity |
|--------|---------------:|-------------------|
| FP8 | 8 | per tensor |
| MXFP4 | 4 | per 32 values |
| NVFP4 | 4 | per 16 values |

```python
w_q = quantize(w, fmt="nvfp4", block=16)
```

That is the whole idea. Smaller blocks cost a little more metadata but track the data much more closely, which is why NVFP4 holds up where plain INT4 starts to drift.
"""


SPANS_REPLY = """Use **bold claims** sparingly, *italic asides* when useful, and `inline_code()` for names.
Read [the NVFP4 guide](https://example.com/nvfp4) and ~~old advice~~ the **newest `kernel` notes**.
"""


def bursty(text, seed=7):
    rng = random.Random(seed)
    pieces, i = [], 0
    while i < len(text):
        n = rng.choice([2, 4, 8, 16, 32, 48])
        pieces.append((text[i:i + n], rng.choice([0.01, 0.02, 0.05, 0.12, 0.25])))
        i += n
    return pieces


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass

    def send_json(self, status, body):
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def authorized(self):
        key = os.environ.get("MOCK_API_KEY")
        if key and self.headers.get("Authorization") != f"Bearer {key}":
            self.send_json(401, {"error": {"message": "Incorrect API key provided",
                                           "type": "invalid_request_error"}})
            return False
        return True

    def do_GET(self):
        if not self.authorized():
            return
        if self.path.rstrip("/") == "/v1/models":
            self.send_json(200, {"object": "list",
                                 "data": [{"id": m, "object": "model"} for m in MODELS]})
        else:
            self.send_json(404, {"error": {"message": "not found"}})

    def search(self):
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))) or b"{}")
        if not self.headers.get("X-API-KEY"):
            return self.send_json(403, {"message": "Unauthorized."})
        q = body.get("q", "")
        self.send_json(200, {
            "searchParameters": {"q": q},
            "answerBox": {"title": f"{q} (featured)", "answer": f"The short answer about {q}.",
                          "link": "https://example.com/featured"},
            "organic": [{"title": f"{q} result {i}", "link": f"https://example.com/{i}",
                         "snippet": f"Snippet {i} about {q}.", "position": i} for i in range(1, 4)],
        })

    def mcp(self):
        if self.headers.get("Authorization") != "Bearer mock-token":
            self.send_response(401)
            self.send_header("WWW-Authenticate", 'Bearer error="invalid_token"')
            self.end_headers()
            return
        msg = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))) or b"{}")
        if "id" not in msg:
            self.send_response(202)
            self.end_headers()
            return
        method, params = msg.get("method"), msg.get("params", {})
        tools = [t for t in MCP_TOOLS if t["annotations"]["readOnlyHint"] or not self.path.endswith("/readonly")]
        headers = {}
        if method == "initialize":
            headers["Mcp-Session-Id"] = "mock-session"
            result = {"protocolVersion": "2025-06-18", "capabilities": {"tools": {}},
                      "serverInfo": {"name": "mock-mcp", "version": "1"}}
        elif self.headers.get("Mcp-Session-Id") != "mock-session":
            return self.send_json(404, {"error": "unknown session"})
        elif method == "tools/list":
            result = {"tools": [{k: t[k] for k in ("name", "description", "inputSchema", "annotations")} for t in tools]}
        elif method == "tools/call":
            tool = next((t for t in tools if t["name"] == params.get("name")), None)
            result = {"content": [{"type": "text", "text": tool["result"] if tool else "no such tool"}],
                      "isError": tool is None}
            time.sleep(0.8)
        else:
            result = None
        reply = {"jsonrpc": "2.0", "id": msg["id"], "result": result} if result is not None else \
                {"jsonrpc": "2.0", "id": msg["id"], "error": {"code": -32601, "message": f"no method {method}"}}
        data = json.dumps(reply)
        if method == "tools/call":
            body = f"event: message\ndata: {data}\n\n".encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
        else:
            body = data.encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
        for k, v in headers.items():
            self.send_header(k, v)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        if self.path.rstrip("/") == "/search":
            return self.search()
        if self.path.startswith("/mcp"):
            return self.mcp()
        if not self.authorized():
            return
        if self.path.rstrip("/") != "/v1/chat/completions":
            return self.send_json(404, {"error": {"message": "not found"}})
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))) or b"{}")
        model = body.get("model", "mock-chat")
        if model not in MODELS:
            return self.send_json(404, {"error": {"message": f"model '{model}' not found"}})
        effort = body.get("reasoning_effort")
        if effort is not None and model in EFFORTS and effort not in EFFORTS[model]:
            return self.send_json(400, {"error": {"message": f"Unexpected reasoning effort {effort}."}})
        content = next((m["content"] for m in reversed(body.get("messages", []))
                        if m["role"] == "user"), "")
        parts = content if isinstance(content, list) else [{"type": "text", "text": content}]
        last_user = " ".join(p["text"] for p in parts if p.get("type") == "text")
        images = [p["image_url"]["url"] for p in parts if p.get("type") == "image_url"]
        if images and model in TEXT_ONLY:
            return self.send_json(400, {"error": {"message": f"{model} does not support image input."}})
        reply = f"You said: {last_user}"
        messages = body.get("messages", [])
        offered = [t["function"]["name"] for t in body.get("tools", [])]
        if messages and messages[-1]["role"] == "tool":
            results = list(takewhile(lambda m: m["role"] == "tool", reversed(messages)))[::-1]
            reply = "Tool said: " + " / ".join(m["content"] for m in results)
        elif (wanted := next((t for t in offered if f"use {t}" in last_user), None)):
            call = {"index": 0, "id": f"call_{int(time.time() * 1000)}", "type": "function",
                    "function": {"name": wanted, "arguments": ""}}
            pieces = ['{"title":', ' "From the', ' app"}']
            events = [chunk({"tool_calls": [call]})] + \
                     [chunk({"tool_calls": [{"index": 0, "function": {"arguments": p}}]}) for p in pieces] + \
                     [chunk({}, finish="tool_calls")]
            return self.stream(events, [0.05] * len(events), finish=None)
        if last_user.startswith("Answer using these web search results"):
            sources = re.findall(r"^\[(\d+)\] .*\n(\S+)$", last_user, re.M)
            question = last_user.rsplit("Question: ", 1)[-1]
            reply = f"From {len(sources)} results about {question}: see [1]({sources[0][1]}) and [2]({sources[1][1]})."
        if images:
            sizes = ", ".join(f"{len(base64.b64decode(u.split(',', 1)[1])) // 1024} KB" for u in images)
            reply = f"You sent {len(images)} image(s) ({sizes}) and said: {last_user or '(nothing)'}"
        if any(m["role"] == "system" and m["content"].startswith("You name chat conversations")
               for m in body.get("messages", [])):
            words = last_user.split("\n\n", 1)[-1].split()[:4]
            reply = f'Title: "{" ".join(words).title()}."'
        events = script(model, reply)
        delays = [0.03] * len(events)
        if last_user.strip().startswith("/huge"):
            thinking = (LONG_REPLY.replace("#", "").replace("|", " ") * 30)[:20000]
            answer = (LONG_REPLY * 6)[:6000]
            events = [chunk({"reasoning_content": thinking[i:i + 6]}) for i in range(0, len(thinking), 6)] + \
                     [chunk({"content": answer[i:i + 6]}) for i in range(0, len(answer), 6)]
            delays = [0.005] * len(events)
        elif last_user.strip().startswith("/spans"):
            pieces = [(SPANS_REPLY[i:i + 3], 0.06) for i in range(0, len(SPANS_REPLY), 3)]
            events = [chunk({"content": t}) for t, _ in pieces]
            delays = [d for _, d in pieces]
        elif last_user.strip().startswith("/long"):
            pieces = bursty(LONG_REPLY)
            events = [chunk({"content": t}) for t, _ in pieces]
            delays = [d for _, d in pieces]
            if model == "mock-reasoning":
                thinking = bursty(LONG_REPLY.replace("#", "").replace("|", " ") * 2, seed=3)
                events = [chunk({"reasoning_content": t}) for t, _ in thinking] + events
                delays = [d for _, d in thinking] + delays

        if not body.get("stream"):
            content = "".join(e["choices"][0]["delta"].get("content", "") for e in events)
            return self.send_json(200, {"object": "chat.completion", "model": model, "choices": [
                {"index": 0, "message": {"role": "assistant", "content": content},
                 "finish_reason": "stop"}]})

        self.stream(events, delays)

    def stream(self, events, delays, finish="stop"):
        if finish:
            events, delays = events + [chunk({}, finish)], delays + [0]
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.end_headers()
        self.wfile.write(b": mock stream\n\n")
        for e, delay in zip(events, delays):
            self.wfile.write(f"data: {json.dumps(e)}\n\n".encode())
            self.wfile.flush()
            time.sleep(delay)
        self.wfile.write(b"data: [DONE]\n\n")
        self.wfile.flush()


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8099)
    args = parser.parse_args()
    print(f"mock OpenAI server on http://{args.host}:{args.port}/v1", flush=True)
    ThreadingHTTPServer((args.host, args.port), Handler).serve_forever()
