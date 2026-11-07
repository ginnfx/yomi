#!/usr/bin/env python3
"""Merge one push provider's settings and make startup load both providers."""

import re
import shlex
import sys
from pathlib import Path


def merge(env_path: Path, start_path: Path, settings: list[str]) -> None:
    updates = dict(setting.split("=", 1) for setting in settings)
    if any(not re.fullmatch(r"YOMI_[A-Z0-9_]+", key) for key in updates):
        raise ValueError("Invalid environment variable name")
    lines = env_path.read_text().splitlines() if env_path.exists() else []
    kept = []
    for line in lines:
        assignment = re.match(r"\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)=", line)
        if assignment is None or assignment[1] not in updates:
            kept.append(line)
    kept.extend(f"export {key}={shlex.quote(value)}" for key, value in updates.items())
    startup = start_path.read_text()
    source_line = "[ -f ./push.env ] && . ./push.env"
    if source_line not in startup:
        marker = "exec ./yomi-upload"
        if marker not in startup:
            raise ValueError("Cannot locate yomi-upload startup command")
        startup = startup.replace(marker, source_line + "\n" + marker, 1)
    env_path.write_text("\n".join(kept) + "\n")
    start_path.write_text(startup)


if __name__ == "__main__":
    merge(Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3:])
