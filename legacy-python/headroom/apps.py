"""Finding running apps, their memory use, and quitting/reopening them."""

from __future__ import annotations

import os
import subprocess
import time
from dataclasses import dataclass, field

KB = 1024

# Never quit these, whatever the config or flags say.
PROTECTED_APPS = frozenset(
    {
        "Finder",
        "WindowServer",
        "Dock",
        "SystemUIServer",
        "loginwindow",
        "kernel_task",
        "launchd",
        "Terminal",
        "iTerm2",
        "iTerm",
        "Ghostty",
        "Warp",
    }
)


@dataclass
class Process:
    pid: int
    ppid: int
    rss_kb: int
    path: str


@dataclass
class AppUsage:
    name: str
    rss_bytes: int = 0
    pids: list[int] = field(default_factory=list)

    @property
    def gb(self) -> float:
        return self.rss_bytes / 1024**3


def parse_ps(text: str) -> list[Process]:
    """Parse `ps -axo pid=,ppid=,rss=,comm=` output."""
    procs = []
    for line in text.splitlines():
        parts = line.strip().split(None, 3)
        if len(parts) < 4:
            continue
        try:
            pid, ppid, rss = int(parts[0]), int(parts[1]), int(parts[2])
        except ValueError:
            continue
        procs.append(Process(pid, ppid, rss, parts[3]))
    return procs


def outermost_app(path: str) -> str | None:
    """Return the name of the outermost `<Name>.app` bundle in a path.

    Helpers live in nested bundles (e.g. ".../Google Chrome.app/.../Google
    Chrome Helper (Renderer).app/..."), so the outermost one is the parent app.
    """
    for part in path.split("/"):
        if part.endswith(".app") and len(part) > 4:
            return part[:-4]
    return None


def belongs_to(path: str, name: str) -> bool:
    return f"/{name}.app/" in path


def belongs_to_any(procs: list[Process], name: str) -> bool:
    return any(belongs_to(p.path, name) for p in procs)


def app_usage(procs: list[Process], names: list[str] | None = None) -> dict[str, AppUsage]:
    """Sum process RSS per app.

    With ``names``, attribute processes to those apps by path containing
    "/<Name>.app/". Without, group every process under its outermost .app.

    Note: RSS over-counts shared memory (frameworks, shared pages are counted
    in every process that maps them), so totals exceed what quitting frees.
    It is good enough for ranking.
    """
    usage: dict[str, AppUsage] = {}
    for p in procs:
        if names is None:
            owner = outermost_app(p.path)
        else:
            owner = next((n for n in names if belongs_to(p.path, n)), None)
        if owner is None:
            continue
        u = usage.setdefault(owner, AppUsage(owner))
        u.rss_bytes += p.rss_kb * KB
        u.pids.append(p.pid)
    return usage


def list_processes() -> list[Process]:
    out = subprocess.run(
        ["ps", "-axo", "pid=,ppid=,rss=,comm="], capture_output=True, text=True, check=True
    ).stdout
    return parse_ps(out)


def ancestor_apps(procs: list[Process], pid: int | None = None) -> set[str]:
    """Names of .app bundles in the parent chain of ``pid`` (default: us).

    Used to protect the app running the tool itself (e.g. VS Code's terminal).
    """
    by_pid = {p.pid: p for p in procs}
    pid = os.getpid() if pid is None else pid
    names: set[str] = set()
    seen: set[int] = set()
    while pid in by_pid and pid not in seen and pid > 1:
        seen.add(pid)
        p = by_pid[pid]
        app = outermost_app(p.path)
        if app:
            names.add(app)
        pid = p.ppid
    return names


def is_protected(name: str, self_apps: set[str] = frozenset()) -> bool:
    return name in PROTECTED_APPS or name in self_apps


def running_apps(names: list[str], procs: list[Process] | None = None) -> list[AppUsage]:
    """Running apps from ``names``, sorted by memory use, largest first."""
    procs = list_processes() if procs is None else procs
    usage = app_usage(procs, names)
    return sorted(usage.values(), key=lambda u: u.rss_bytes, reverse=True)


def _osascript_quote(name: str) -> str:
    return name.replace("\\", "\\\\").replace('"', '\\"')


def is_running(name: str) -> bool:
    return belongs_to_any(list_processes(), name)


def quit_app(name: str, timeout: float = 15.0, force: bool = False,
             self_apps: set[str] = frozenset()) -> bool:
    """Quit an app gracefully. Returns True if its processes are gone.

    Callers must only pass apps from the active quit list; protected apps are
    refused here as a last line of defence.
    """
    if is_protected(name, self_apps):
        raise ValueError(f"refusing to quit protected app: {name}")
    script = f'tell application "{_osascript_quote(name)}" to quit'
    try:
        subprocess.run(["osascript", "-e", script], capture_output=True, text=True,
                       timeout=timeout)
    except subprocess.TimeoutExpired:
        pass
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if not is_running(name):
            return True
        time.sleep(0.5)
    if force:
        for p in list_processes():
            if belongs_to(p.path, name):
                try:
                    os.kill(p.pid, 9)
                except (ProcessLookupError, PermissionError):
                    pass
        time.sleep(1.0)
        return not is_running(name)
    return False


def open_app(name: str) -> bool:
    r = subprocess.run(["open", "-a", name], capture_output=True, text=True)
    return r.returncode == 0
