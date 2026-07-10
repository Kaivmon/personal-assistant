from __future__ import annotations

import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any

from .assistant import Assistant
from .config import Settings
from .db import connect, initialize


class Handler(BaseHTTPRequestHandler):
    assistant: Assistant
    settings: Settings

    def do_GET(self) -> None:
        if self.path == "/health":
            with connect(self.settings.db_path) as conn:
                initialize(conn)
            self._json(200, {"ok": True, "service": "personal-assistant"})
            return
        self._json(404, {"error": "not found"})

    def do_POST(self) -> None:
        payload = self._read_json()
        if self.path == "/openclaw/message":
            message = str(payload.get("message", ""))
            if not message.strip():
                self._json(400, {"error": "message is required"})
                return
            self._json(200, self.assistant.handle_message(message))
            return
        if self.path == "/openclaw/provider-status":
            self._json(
                200,
                self.assistant.provider_status(
                    int(payload.get("limit_per_window", self.settings.chatgpt_usage_limit)),
                    int(payload.get("used_in_window", self.settings.chatgpt_usage_used)),
                    self.settings.warn_remaining,
                ),
            )
            return
        if self.path == "/reports/cleanup":
            from .reports import cleanup_old_reports

            deleted = cleanup_old_reports(self.settings.report_dir, self.settings.report_ttl_seconds)
            self._json(200, {"deleted": [str(path) for path in deleted]})
            return
        self._json(404, {"error": "not found"})

    def log_message(self, format: str, *args: Any) -> None:
        return

    def _read_json(self) -> dict[str, Any]:
        length = int(self.headers.get("content-length", "0"))
        if length == 0:
            return {}
        return json.loads(self.rfile.read(length).decode("utf-8"))

    def _json(self, status: int, payload: dict[str, Any]) -> None:
        body = json.dumps(payload, sort_keys=True).encode("utf-8")
        self.send_response(status)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def run(settings: Settings | None = None) -> None:
    settings = settings or Settings.from_env()
    assistant = Assistant(settings.db_path, settings.report_dir, settings.report_ttl_seconds)
    Handler.assistant = assistant
    Handler.settings = settings
    server = ThreadingHTTPServer((settings.host, settings.port), Handler)
    server.serve_forever()


if __name__ == "__main__":
    run()

