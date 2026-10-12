#!/usr/bin/env python3
"""A stand-in for uzu's OpenAI-compatible server (uzu server), for the gateway tests: the same routes, reply shapes and
validation, no model. Like uzu, plain JSON replies are sent chunked.

    python3 mock_engine.py PORT RECORD_DIR

Every request body is written to RECORD_DIR/last_<path>.json. Like uzu it answers GET /v1/models and POST
/v1/chat/completions only, writes stream events as "data:{...}" (no space), puts usage (with spec_verify_ct, the
speculator's steps) on the finishing chunk, and refuses an unknown reasoning_effort or one that contradicts
enable_thinking with a 400. The first token comes 0.2 s after the request (the "prefill"); a prompt containing "SLOW"
then streams one token every 0.2 s.
"""
import json
import os
import socketserver
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT, RECORD = int(sys.argv[1]), sys.argv[2]
WORDS = ["Hello", " from", " the", " mock", " engine", "."]
EFFORTS = ("disabled", "default", "low", "medium", "high", "xhigh")


class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def send_json(self, code, obj):
        b = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def do_GET(self):
        if self.path.rstrip("/") in ("/v1/models", "/models"):
            return self.send_json(200, {"object": "list", "data": [{"id": "mock", "object": "model", "created": 0, "owned_by": "uzu"}]})
        return self.send_json(404, {"error": {"message": "not found"}})

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length") or 0)) or b"{}")
        name = self.path.strip("/").replace("/", "_")
        with open(os.path.join(RECORD, f"last_{name}.json"), "w") as fh:
            json.dump({"body": body, "headers": dict(self.headers)}, fh)
        if self.path not in ("/v1/chat/completions", "/chat/completions"):
            return self.send_json(404, {"error": {"message": "not found"}})
        effort = body.get("reasoning_effort")
        enable = body.get("enable_thinking", (body.get("chat_template_kwargs") or {}).get("enable_thinking"))
        if effort is not None and effort not in EFFORTS:
            return self.send_json(400, {"error": {"message": f"Unknown reasoning effort: {effort}", "param": "reasoning_effort"}})
        if effort is not None and enable is not None and (effort == "disabled") == enable:
            return self.send_json(400, {"error": {"message": f"reasoning_effort {effort} conflicts with enable_thinking {enable}"}})
        slow = "SLOW" in json.dumps(body.get("messages", ""))
        n_prompt = 40
        words = WORDS * (25 if slow else 1)
        usage = {"prompt_tokens": n_prompt, "completion_tokens": len(words), "total_tokens": n_prompt + len(words),
                 "prompt_tokens_details": {"cached_tokens": 10}, "spec_verify_ct": 2 if not slow else 50}
        time.sleep(0.2)
        if not body.get("stream"):  # like uzu (Rocket), a plain JSON reply goes out chunked, without a Content-Length
            data = json.dumps({"id": "cmpl-1", "object": "chat.completion", "created": 0, "model": "mock",
                               "choices": [{"index": 0, "message": {"role": "assistant", "content": "".join(words)},
                                            "finish_reason": "stop"}],
                               "usage": usage}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()
            self.wfile.write(b"%x\r\n%s\r\n0\r\n\r\n" % (len(data), data))
            return
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()

        def emit(obj):
            data = b"data:" + (obj if isinstance(obj, bytes) else json.dumps(obj).encode()) + b"\n\n"
            self.wfile.write(b"%x\r\n%s\r\n" % (len(data), data))
            self.wfile.flush()

        try:
            for w in words:
                emit({"id": "c1", "object": "chat.completion.chunk", "created": 0, "model": "mock",
                      "choices": [{"index": 0, "delta": {"content": w}, "finish_reason": None}]})
                if slow:
                    time.sleep(0.2)
            emit({"id": "c1", "object": "chat.completion.chunk", "created": 0, "model": "mock",
                  "choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}], "usage": usage})
            emit(b"[DONE]")
            self.wfile.write(b"0\r\n\r\n")
        except (BrokenPipeError, ConnectionResetError):
            with open(os.path.join(RECORD, "cancelled"), "w") as fh:
                fh.write("1")


class Server(ThreadingHTTPServer):
    daemon_threads = True

    def server_bind(self):  # skip HTTPServer's reverse DNS lookup of the host name (slow on some networks)
        socketserver.TCPServer.server_bind(self)
        self.server_name, self.server_port = self.server_address[:2]


Server(("127.0.0.1", PORT), H).serve_forever()
