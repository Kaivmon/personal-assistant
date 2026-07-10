from __future__ import annotations

import argparse

from .assistant import Assistant
from .config import Settings
from .db import connect, initialize
from .service import run


def main() -> None:
    parser = argparse.ArgumentParser(prog="personal-assistant")
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("init-db")
    msg = sub.add_parser("message")
    msg.add_argument("text")
    sub.add_parser("serve")
    args = parser.parse_args()
    settings = Settings.from_env()
    if args.command == "init-db":
        with connect(settings.db_path) as conn:
            initialize(conn)
        print(f"Initialized {settings.db_path}")
    elif args.command == "message":
        assistant = Assistant(settings.db_path, settings.report_dir, settings.report_ttl_seconds)
        print(assistant.handle_message(args.text)["reply"])
    elif args.command == "serve":
        run(settings)

