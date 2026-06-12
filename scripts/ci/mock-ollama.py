#!/usr/bin/env python3
"""Stub Ollama server for the end-to-end CI test.

Answers POST /api/chat with a canned, fenced-JSON summary so the pipeline
test exercises the real OllamaSummarizer HTTP path with zero network access.
"""
import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

CANNED_CONTENT = (
    "Here you go:\n"
    "```json\n"
    + json.dumps(
        {
            "title": "CI Test Meeting",
            "summary": "This is a canned summary produced by the CI stub.",
            "key_points": ["Pipeline ran end to end"],
            "action_items": ["Me: send the budget report to finance"],
            "decisions": ["Ship version two next month"],
        }
    )
    + "\n```\n"
)


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        self.rfile.read(length)
        if self.path != "/api/chat":
            self.send_response(404)
            self.end_headers()
            return
        body = json.dumps(
            {
                "model": "stub",
                "message": {"role": "assistant", "content": CANNED_CONTENT},
                "done": True,
            }
        ).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_args):
        pass


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 11434
    HTTPServer(("127.0.0.1", port), Handler).serve_forever()
