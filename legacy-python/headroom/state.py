"""Saving/loading the prep session so restore can undo it."""

from __future__ import annotations

import json
import os
from datetime import datetime, timezone
from pathlib import Path


def session_path() -> Path:
    base = os.environ.get("XDG_STATE_HOME") or str(Path.home() / ".local" / "state")
    return Path(base) / "headroom" / "session.json"


def load_session(path: Path | None = None) -> dict | None:
    path = path or session_path()
    if not path.exists():
        return None
    try:
        return json.loads(path.read_text())
    except json.JSONDecodeError:
        return None


def merge_session(existing: dict | None, new: dict) -> dict:
    """Merge a new prep result into an existing session so one restore undoes both."""
    if not existing:
        return new
    merged = dict(existing)
    for key in ("quit_apps", "unloaded_models"):
        merged[key] = list(dict.fromkeys(existing.get(key, []) + new.get(key, [])))
    merged["docker_stopped"] = bool(existing.get("docker_stopped")) or bool(new.get("docker_stopped"))
    # Keep the earliest "before" so the summary reflects the whole session.
    merged["available_after_gb"] = new.get("available_after_gb")
    merged["profile"] = new.get("profile", existing.get("profile"))
    return merged


def save_session(data: dict, path: Path | None = None) -> Path:
    """Write the session, merging with any existing one."""
    path = path or session_path()
    data = dict(data)
    data.setdefault("created_at", datetime.now(timezone.utc).isoformat(timespec="seconds"))
    merged = merge_session(load_session(path), data)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(merged, indent=2) + "\n")
    tmp.replace(path)
    return path


def clear_session(path: Path | None = None) -> None:
    path = path or session_path()
    path.unlink(missing_ok=True)
