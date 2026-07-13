#!/usr/bin/env python3
"""CORS proxy for nanobot API server.

Forwards requests from browser-based clients (like Airi) to nanobot's
OpenAI-compatible API, adding CORS headers so the browser doesn't block
cross-origin requests.

Also merges multiple messages (system + user) into a single user message,
since nanobot's API currently only supports one user message per request.

Usage:
    python3 cors-proxy.py [--port 18900] [--target http://127.0.0.1:8900]
"""

import argparse
import json
import sys
import urllib.error
import urllib.request
from http.server import HTTPServer, BaseHTTPRequestHandler

TARGET = "http://127.0.0.1:8900"
PORT = 18900


def merge_messages(body: bytes) -> bytes:
    """Merge multiple messages into a single user message.

    nanobot's /v1/chat/completions only accepts ``messages`` with exactly
    one entry whose role is "user". Clients like Airi send system + user
    messages. We merge them into one user message, prefixing system
    content with a [System] tag.
    """
    data = json.loads(body)
    msgs = data.get("messages", [])
    if len(msgs) <= 1:
        return body

    parts: list[str] = []
    for m in msgs:
        role = m.get("role", "user")
        content = m.get("content", "")
        if isinstance(content, list):
            content = " ".join(
                p.get("text", "") for p in content if isinstance(p, dict)
            )
        if role == "system":
            parts.append(f"[System]\n{content}")
        else:
            parts.append(content)

    data["messages"] = [{"role": "user", "content": "\n\n".join(parts)}]
    return json.dumps(data).encode()


class CORSProxy(BaseHTTPRequestHandler):
    """HTTP handler that proxies requests with CORS headers."""

    def log_message(self, fmt, *args):
        print(f"[proxy] {args[0]}", file=sys.stderr, flush=True)

    # ── CORS preflight ──────────────────────────────────────────────

    def do_OPTIONS(self):
        self._send_cors_headers()
        self.end_headers()

    # ── GET (models, health) ────────────────────────────────────────

    def do_GET(self):
        try:
            req = urllib.request.Request(f"{TARGET}{self.path}")
            self._copy_header(req, "Authorization")
            resp = urllib.request.urlopen(req, timeout=10)
            body = resp.read()
            self._send_cors_headers()
            self.send_header(
                "Content-Type",
                resp.headers.get("Content-Type", "application/json"),
            )
            self.end_headers()
            self.wfile.write(body)
        except Exception as e:
            self._error(str(e))

    # ── POST (chat completions) ─────────────────────────────────────

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length) if length else b""

        # Merge multi-message requests for nanobot compatibility
        body = merge_messages(body)

        print(
            f"[proxy] POST {self.path} "
            f"msgs={len(json.loads(body).get('messages', []))}",
            file=sys.stderr,
            flush=True,
        )

        try:
            req = urllib.request.Request(f"{TARGET}{self.path}", data=body)
            self._copy_header(req, "Authorization")
            self._copy_header(req, "Content-Type")
            resp = urllib.request.urlopen(req, timeout=120)
            resp_body = resp.read()
            self._send_cors_headers()
            self.send_header(
                "Content-Type",
                resp.headers.get("Content-Type", "application/json"),
            )
            self.end_headers()
            self.wfile.write(resp_body)
            print(f"[proxy] -> {len(resp_body)} bytes", file=sys.stderr, flush=True)
        except urllib.error.HTTPError as e:
            err_body = e.read()
            print(
                f"[proxy] API {e.code}: {err_body[:200]}",
                file=sys.stderr,
                flush=True,
            )
            self._send_cors_headers()
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(err_body)
        except Exception as e:
            self._error(str(e))

    # ── helpers ─────────────────────────────────────────────────────

    def _copy_header(self, req: urllib.request.Request, name: str) -> None:
        value = self.headers.get(name, "")
        if value:
            req.add_header(name, value)

    def _send_cors_headers(self) -> None:
        self.send_response(200)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header(
            "Access-Control-Allow-Headers", "Authorization, Content-Type"
        )
        self.send_header(
            "Access-Control-Allow-Methods", "GET, POST, OPTIONS"
        )

    def _error(self, message: str) -> None:
        self._send_cors_headers()
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps({"error": message}).encode())


def main():
    parser = argparse.ArgumentParser(description="CORS proxy for nanobot API")
    parser.add_argument("--port", type=int, default=PORT)
    args = parser.parse_args()

    print(
        f"[proxy] {args.port} -> {TARGET}  (merge multi-messages)",
        file=sys.stderr,
        flush=True,
    )
    server = HTTPServer(("127.0.0.1", args.port), CORSProxy)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\n[proxy] stopped", file=sys.stderr)
        server.server_close()


if __name__ == "__main__":
    main()
