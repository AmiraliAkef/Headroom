"""Reading system memory stats on macOS.

Every parser is a pure function taking a command's text output, so it can be
tested against captured fixtures. ``read_memory()`` wires them to real commands.
"""

from __future__ import annotations

import re
import subprocess
from dataclasses import dataclass, asdict

GB = 1024**3

PRESSURE_LEVELS = {1: "normal", 2: "warning", 4: "critical"}


@dataclass
class MemoryStats:
    total_bytes: int
    available_bytes: int  # estimate, see estimate_available()
    compressed_bytes: int
    swap_used_bytes: int
    swap_total_bytes: int
    pressure: str

    @property
    def total_gb(self) -> float:
        return self.total_bytes / GB

    @property
    def available_gb(self) -> float:
        return self.available_bytes / GB

    @property
    def compressed_gb(self) -> float:
        return self.compressed_bytes / GB

    @property
    def swap_used_gb(self) -> float:
        return self.swap_used_bytes / GB

    def to_dict(self) -> dict:
        d = asdict(self)
        d.update(
            total_gb=round(self.total_gb, 2),
            available_gb=round(self.available_gb, 2),
            compressed_gb=round(self.compressed_gb, 2),
            swap_used_gb=round(self.swap_used_gb, 2),
        )
        return d


def parse_memsize(text: str) -> int:
    """Parse `sysctl -n hw.memsize` -> bytes."""
    return int(text.strip())


_PAGE_SIZE_RE = re.compile(r"page size of (\d+) bytes")
_VM_LINE_RE = re.compile(r'^"?([^":]+)"?:\s+(\d+)\.?\s*$')


def parse_vm_stat(text: str) -> tuple[int, dict[str, int]]:
    """Parse `vm_stat` -> (page_size, {"Pages free": n, ...})."""
    m = _PAGE_SIZE_RE.search(text)
    if not m:
        raise ValueError("vm_stat output has no page size header")
    page_size = int(m.group(1))
    counts: dict[str, int] = {}
    for line in text.splitlines()[1:]:
        lm = _VM_LINE_RE.match(line.strip())
        if lm:
            counts[lm.group(1).strip()] = int(lm.group(2))
    return page_size, counts


def estimate_available(page_size: int, counts: dict[str, int]) -> int:
    """Estimated available RAM in bytes.

    (free + inactive + speculative + purgeable) x page size. This is an
    *estimate*: macOS can also reclaim file cache counted elsewhere and
    compress active memory, and some inactive pages are dirty and must be
    swapped before reuse. It is a reasonable, conservative-ish proxy.
    """
    keys = ("Pages free", "Pages inactive", "Pages speculative", "Pages purgeable")
    return sum(counts.get(k, 0) for k in keys) * page_size


def compressed_bytes(page_size: int, counts: dict[str, int]) -> int:
    return counts.get("Pages occupied by compressor", 0) * page_size


_SIZE_RE = re.compile(r"(\w+)\s*=\s*([\d.]+)([KMGT])")
_UNIT = {"K": 1024, "M": 1024**2, "G": 1024**3, "T": 1024**4}


def parse_swapusage(text: str) -> dict[str, int]:
    """Parse `sysctl vm.swapusage` -> {"total": bytes, "used": bytes, "free": bytes}."""
    out = {}
    for key, num, unit in _SIZE_RE.findall(text):
        out[key] = int(float(num) * _UNIT[unit])
    if "used" not in out:
        raise ValueError(f"unrecognised vm.swapusage output: {text!r}")
    return out


def parse_pressure(text: str) -> str:
    """Parse `sysctl -n kern.memorystatus_vm_pressure_level` -> level name."""
    try:
        level = int(text.strip())
    except ValueError:
        return "unknown"
    return PRESSURE_LEVELS.get(level, "unknown")


def _run(args: list[str]) -> str:
    return subprocess.run(args, capture_output=True, text=True, check=True).stdout


def read_memory() -> MemoryStats:
    total = parse_memsize(_run(["sysctl", "-n", "hw.memsize"]))
    page_size, counts = parse_vm_stat(_run(["vm_stat"]))
    swap = parse_swapusage(_run(["sysctl", "vm.swapusage"]))
    try:
        pressure = parse_pressure(_run(["sysctl", "-n", "kern.memorystatus_vm_pressure_level"]))
    except subprocess.CalledProcessError:
        pressure = "unknown"
    return MemoryStats(
        total_bytes=total,
        available_bytes=estimate_available(page_size, counts),
        compressed_bytes=compressed_bytes(page_size, counts),
        swap_used_bytes=swap.get("used", 0),
        swap_total_bytes=swap.get("total", 0),
        pressure=pressure,
    )
