"""Stopping and restarting Docker Desktop."""

from __future__ import annotations

import shutil
import subprocess
import time

from . import apps

APP_NAME = "Docker"


def usage(procs: list[apps.Process]) -> apps.AppUsage | None:
    """Docker Desktop's memory: its app processes plus the VM (com.docker.* / qemu / krunkit).

    The VM processes live outside Docker.app on some versions, so match them by name too.
    """
    total = apps.AppUsage(APP_NAME)
    for p in procs:
        base = p.path.rsplit("/", 1)[-1]
        if (apps.belongs_to(p.path, APP_NAME)
                or (base.startswith("com.docker.") and base != "com.docker.vmnetd")
                or (base in ("krunkit", "qemu-system-aarch64") and "docker" in p.path.lower())):
            total.rss_bytes += p.rss_kb * apps.KB
            total.pids.append(p.pid)
    return total if apps.belongs_to_any(procs, APP_NAME) else None


def stop(timeout: float = 60.0) -> bool:
    if shutil.which("docker"):
        try:
            r = subprocess.run(["docker", "desktop", "stop"], capture_output=True, text=True,
                               timeout=timeout)
            if r.returncode == 0 and _wait_gone(15.0):
                return True
        except (OSError, subprocess.TimeoutExpired):
            pass
    # Engine may be stopped while the app lingers; quit the app itself.
    return apps.quit_app(APP_NAME, timeout=timeout)


def _wait_gone(timeout: float) -> bool:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if not apps.is_running(APP_NAME):
            return True
        time.sleep(1.0)
    return not apps.is_running(APP_NAME)


def start() -> bool:
    return apps.open_app(APP_NAME)
