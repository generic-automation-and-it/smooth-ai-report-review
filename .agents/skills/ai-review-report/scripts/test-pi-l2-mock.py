#!/usr/bin/env python3
"""L2 mock for the pi backend: a localhost OpenAI-compatible SSE endpoint.

Usage: test-pi-l2-mock.py <port> <scenario-file> <requests-file>
The scenario file holds {"mode": "answer|empty|http500|tool_calls", ...}.
No network egress, no secret: the L2 suite only checks transport and policy.
"""
import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        pass

    def do_POST(self):
        if self.path.rstrip("/").endswith("/reset"):
            COUNT["n"] = 0
            open(SCENARIO["requests"], "w").close()
            data = b'{"reset":true}'
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return
        length = int(self.headers.get("Content-Length", "0"))
        raw = self.rfile.read(length) if length else b"{}"
        try:
            body = json.loads(raw.decode("utf-8", "replace"))
        except Exception:
            body = {"_raw": raw.decode("utf-8", "replace")}
        with open(SCENARIO["requests"], "a") as f:
            f.write(json.dumps(body) + "\n")
        try:
            with open(SCENARIO["file"]) as f:
                scenario = json.load(f)
        except Exception:
            scenario = {"mode": "answer", "answer": "OK"}
        COUNT["n"] += 1
        if COUNT["n"] > 1 and isinstance(scenario.get("then"), dict):
            scenario = scenario["then"]
        mode = scenario.get("mode", "answer")
        if mode == "http500":
            data = b'{"error":{"message":"mock 500"}}'
            self.send_response(500)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return
        if mode == "tool_calls":
            message = {
                "role": "assistant",
                "content": None,
                "tool_calls": [
                    {
                        "id": "call_1",
                        "type": "function",
                        "function": {"name": tc["name"], "arguments": json.dumps(tc.get("arguments", {}))},
                    }
                    for tc in scenario.get("tool_calls", [])
                ],
            }
            finish = "tool_calls"
        else:
            message = {"role": "assistant", "content": scenario.get("answer", "") if mode != "empty" else ""}
            finish = "stop"
        self._stream(message, finish)

    def _stream(self, message, finish):
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "close")
        self.end_headers()
        delta = {"role": "assistant", "content": message.get("content")}
        if message.get("tool_calls"):
            delta["tool_calls"] = [
                {"index": i, "id": tc["id"], "type": "function", "function": tc["function"]}
                for i, tc in enumerate(message["tool_calls"])
            ]
        chunk = {"id": "c", "object": "chat.completion.chunk", "created": 0,
                 "choices": [{"index": 0, "delta": delta, "finish_reason": None}]}
        self.wfile.write(b"data: " + json.dumps(chunk).encode() + b"\n\n")
        final = {"id": "c", "object": "chat.completion.chunk", "created": 0,
                 "choices": [{"index": 0, "delta": {}, "finish_reason": finish}],
                 "usage": {"prompt_tokens": 1, "completion_tokens": 1, "total_tokens": 2}}
        self.wfile.write(b"data: " + json.dumps(final).encode() + b"\n\n")
        self.wfile.write(b"data: [DONE]\n\n")
        self.close_connection = True


SCENARIO = {}
COUNT = {"n": 0}

if __name__ == "__main__":
    SCENARIO["file"] = sys.argv[2]
    SCENARIO["requests"] = sys.argv[3]
    ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
