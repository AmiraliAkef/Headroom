"""Unloading local LLMs (Ollama, LM Studio)."""

from __future__ import annotations

import re
import shutil
import subprocess
from dataclasses import dataclass

_UNITS = {"B": 1, "KB": 1000, "MB": 1000**2, "GB": 1000**3, "TB": 1000**4,
          "KIB": 1024, "MIB": 1024**2, "GIB": 1024**3, "TIB": 1024**4}
_SIZE_RE = re.compile(r"([\d.]+)\s*([KMGT]?i?B)\b", re.IGNORECASE)


@dataclass
class LoadedModel:
    name: str
    size_bytes: int
    runtime: str  # "ollama" | "lmstudio"

    @property
    def gb(self) -> float:
        return self.size_bytes / 1024**3


def parse_size(text: str) -> int:
    m = _SIZE_RE.search(text)
    if not m:
        return 0
    return int(float(m.group(1)) * _UNITS[m.group(2).upper()])


def _columns(header: str) -> list[tuple[str, int]]:
    return [(m.group(0), m.start()) for m in re.finditer(r"\S+", header)]


def _table(text: str) -> list[dict[str, str]]:
    """Parse a fixed-width table whose header starts each column."""
    lines = [l for l in text.splitlines() if l.strip()]
    if not lines:
        return []
    cols = _columns(lines[0])
    rows = []
    for line in lines[1:]:
        row = {}
        for i, (name, start) in enumerate(cols):
            end = cols[i + 1][1] if i + 1 < len(cols) else None
            row[name.upper()] = line[start:end].strip()
        rows.append(row)
    return rows


def parse_ollama_ps(text: str) -> list[LoadedModel]:
    """Parse `ollama ps` (NAME ID SIZE PROCESSOR ... columns)."""
    lines = [l for l in text.splitlines() if l.strip()]
    if not lines or not lines[0].lstrip().upper().startswith("NAME"):
        return []
    return [LoadedModel(r["NAME"], parse_size(r.get("SIZE", "")), "ollama")
            for r in _table(text) if r.get("NAME")]


def parse_lms_ps(text: str) -> list[LoadedModel]:
    """Parse `lms ps`. Handles both the table and the "Identifier:" list formats."""
    lines = [l for l in text.splitlines() if l.strip()]
    if not lines or "no models" in text.lower():
        return []
    header = lines[0].upper()
    if "IDENTIFIER" in header and "SIZE" in header:
        return [LoadedModel(r["IDENTIFIER"], parse_size(r.get("SIZE", "")), "lmstudio")
                for r in _table(text) if r.get("IDENTIFIER")]
    models: list[LoadedModel] = []
    for line in lines:
        s = line.strip().lstrip("•-* ").strip()
        if s.lower().startswith("identifier:"):
            models.append(LoadedModel(s.split(":", 1)[1].strip(), 0, "lmstudio"))
        elif s.lower().startswith("size:") and models:
            models[-1].size_bytes = parse_size(s)
    return models


def _run(args: list[str], timeout: float = 30) -> subprocess.CompletedProcess:
    return subprocess.run(args, capture_output=True, text=True, timeout=timeout)


def loaded_models() -> list[LoadedModel]:
    """All loaded models from available runtimes. Missing CLIs or servers are skipped."""
    models: list[LoadedModel] = []
    if shutil.which("ollama"):
        try:
            r = _run(["ollama", "ps"], timeout=10)
            if r.returncode == 0:
                models += parse_ollama_ps(r.stdout)
        except (OSError, subprocess.TimeoutExpired):
            pass
    if shutil.which("lms"):
        try:
            r = _run(["lms", "ps"], timeout=10)
            if r.returncode == 0:
                models += parse_lms_ps(r.stdout)
        except (OSError, subprocess.TimeoutExpired):
            pass
    return models


def unload(model: LoadedModel) -> bool:
    if model.runtime == "ollama":
        args = ["ollama", "stop", model.name]
    elif model.runtime == "lmstudio":
        args = ["lms", "unload", model.name]
    else:
        return False
    try:
        return _run(args).returncode == 0
    except (OSError, subprocess.TimeoutExpired):
        return False


def unload_all_lmstudio() -> bool:
    try:
        return _run(["lms", "unload", "--all"]).returncode == 0
    except (OSError, subprocess.TimeoutExpired):
        return False
