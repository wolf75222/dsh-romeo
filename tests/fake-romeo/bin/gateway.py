#!/usr/bin/env python3
"""Fake gateway: /v1/models, and /v1/chat/completions answering 503 for a model until a job of the
fiche of the same name has run FAKE_LOAD_SECONDS."""
import json, os, sys, time
from http.server import BaseHTTPRequestHandler, HTTPServer

STATE = os.environ["FAKE_ROMEO_STATE"]
LOAD = float(os.environ.get("FAKE_LOAD_SECONDS", "2"))


def ready_models():
    try:
        jobs = [line.split() for line in open(os.path.join(STATE, "jobs")) if line.strip()]
    except FileNotFoundError:
        return set()
    return {fiche for _, fiche, start in jobs if time.time() - float(start) >= LOAD}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def reply(self, code, body):
        data = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def authorized(self):
        if self.headers.get("Authorization") not in ("Bearer test-key", "Bearer test-key-of-the-job-0123456789"):
            self.reply(401, {"error": "bad key"})
            return False
        return True

    def do_GET(self):
        if self.path == "/metrics":  # vLLM's counters, no key (as on ROMEO, from the login node)
            gen = int(time.time() * 50)
            data = ('vllm:num_requests_running{engine="0"} 3.0\nvllm:num_requests_waiting{engine="0"} 1.0\n'
                    'vllm:kv_cache_usage_perc{engine="0"} 0.25\nvllm:generation_tokens_total{engine="0"} %d.0\n'
                    'vllm:prompt_tokens_total{engine="0"} 1000.0\n' % gen).encode()
            self.send_response(200)
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return
        if self.authorized():
            self.reply(200, {"data": [{"id": m} for m in sorted(ready_models())]})

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))) or b"{}")
        if self.authorized():
            if body.get("model") in ready_models():
                self.reply(200, {"choices": [{"message": {"content": "hi"}}]})
            else:
                self.reply(503, {"error": "loading"})


HTTPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
