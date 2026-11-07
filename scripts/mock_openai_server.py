#!/usr/bin/env python3
"""Stdlib-only OpenAI-compatible mock for exercising chatcli and the app.

Models:
  mock-chat       plain streamed content
  mock-reasoning  reasoning_content deltas, then content
  mock-ollama     `reasoning` deltas (Ollama style), then content
  mock-think      <think>..</think> inline in content, tags split across chunks
Set MOCK_API_KEY to require `Authorization: Bearer <key>`.
"""
import argparse
import json
import os
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MODELS = ["mock-chat", "mock-reasoning", "mock-ollama", "mock-think"]


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

    def do_POST(self):
        if not self.authorized():
            return
        if self.path.rstrip("/") != "/v1/chat/completions":
            return self.send_json(404, {"error": {"message": "not found"}})
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))) or b"{}")
        model = body.get("model", "mock-chat")
        if model not in MODELS:
            return self.send_json(404, {"error": {"message": f"model '{model}' not found"}})
        last_user = next((m["content"] for m in reversed(body.get("messages", []))
                          if m["role"] == "user"), "")
        reply = f"You said: {last_user}"
        events = script(model, reply)

        if not body.get("stream"):
            content = "".join(e["choices"][0]["delta"].get("content", "") for e in events)
            return self.send_json(200, {"object": "chat.completion", "model": model, "choices": [
                {"index": 0, "message": {"role": "assistant", "content": content},
                 "finish_reason": "stop"}]})

        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.end_headers()
        self.wfile.write(b": mock stream\n\n")
        for e in events + [chunk({}, "stop")]:
            self.wfile.write(f"data: {json.dumps(e)}\n\n".encode())
            self.wfile.flush()
            time.sleep(0.03)
        self.wfile.write(b"data: [DONE]\n\n")
        self.wfile.flush()


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8099)
    args = parser.parse_args()
    print(f"mock OpenAI server on http://{args.host}:{args.port}/v1", flush=True)
    ThreadingHTTPServer((args.host, args.port), Handler).serve_forever()
