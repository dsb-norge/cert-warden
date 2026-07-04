#!/usr/bin/env python3
"""Tiny HTTP sink standing in for the Teams Notification Bot API in integration tests.

Accepts POSTs, appends one JSON line per request to the log file (path, auth header, parsed
body) and answers 202 like the real bot. Usage: sink.py <port> <logfile>
"""

import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

PORT = int(sys.argv[1])
LOGFILE = sys.argv[2]


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):  # noqa: N802 (stdlib naming)
        length = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(length).decode("utf-8", errors="replace")
        try:
            body = json.loads(raw)
        except json.JSONDecodeError:
            body = {"_raw": raw}
        record = {
            "path": self.path,
            "authorization": self.headers.get("Authorization", ""),
            "content_type": self.headers.get("Content-Type", ""),
            "body": body,
        }
        with open(LOGFILE, "a", encoding="utf-8") as f:
            f.write(json.dumps(record) + "\n")
        response = json.dumps({"status": "queued", "messageId": "msg-test"}).encode()
        self.send_response(202)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(response)))
        self.end_headers()
        self.wfile.write(response)

    def log_message(self, fmt, *args):  # silence request logging
        pass


HTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
