"""Menu-bar plugin for SwiftBar (and xbar).

`headroom menubar --install` writes a small stub script into the SwiftBar/xbar
plugin folder. The stub runs this module, which:

- with no arguments, prints the menu (pressure, available RAM, what prep
  could free, Prep / Restore actions) in the BitBar text format;
- with an action argument (prep, restore, dryrun, config), performs it. SwiftBar
  calls the stub again with these arguments when a menu item is clicked.

All memory reading and quitting goes through the normal CLI code paths, so the
same allowlist and protected list apply.
"""

from __future__ import annotations

import fcntl
import os
import shlex
import subprocess
import sys
from pathlib import Path

from . import config as config_mod
from . import state

GB = 1024**3
REFRESH = "30s"
STUB_NAME = f"headroom.{REFRESH}.sh"

PRESSURE_COLOR = {"normal": None, "warning": "#E8A33D", "critical": "#E5484D"}
PRESSURE_DOT = {"normal": "🟢", "warning": "🟠", "critical": "🔴"}


def _esc(text: str) -> str:
    """Menu text can't contain '|' (it starts the parameter section)."""
    return str(text).replace("|", "¦").replace("\n", " ")


def _param(value: str) -> str:
    """Quote a SwiftBar/xbar parameter value (double quotes, as their parsers expect)."""
    if value and not any(c.isspace() or c in "\"'|=" for c in value):
        return value
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


def _action(label: str, plugin: str, *params: str, terminal: bool = False,
            refresh: bool = True) -> str:
    parts = [f"bash={_param(plugin)}"]
    parts += [f"param{i}={_param(p)}" for i, p in enumerate(params, 1)]
    parts += [f"terminal={'true' if terminal else 'false'}",
              f"refresh={'true' if refresh else 'false'}"]
    return f"{_esc(label)} | " + " ".join(parts)


def render(st: dict, plugin: str, busy: bool = False) -> str:
    """Render a status dict (from cli.collect_status) as a SwiftBar/xbar menu."""
    m = st["memory"]
    pressure = m["pressure"]
    avail = m["available_bytes"] / GB
    title = f"{avail:.1f}G"
    params = ["sfimage=memorychip"]
    color = PRESSURE_COLOR.get(pressure)
    if color:
        params.append(f"color={color}")
    if busy:
        title += " …"
    lines = [f"{title} | {' '.join(params)}", "---"]

    lines.append(f"{PRESSURE_DOT.get(pressure, '⚪️')} Memory pressure: {pressure}")
    lines.append(f"Available (est.): {avail:.1f} of {m['total_bytes'] / GB:.0f} GB")
    lines.append(f"Swap used: {m['swap_used_bytes'] / GB:.1f} GB   "
                 f"Compressed: {m['compressed_bytes'] / GB:.1f} GB")
    lines.append("---")

    target = st["target_gb"]
    met = "✓ met" if st["target_met"] else "not met"
    lines.append(f"Profile '{_esc(st['profile'])}': target {target:.1f} GB ({met})")
    for a in st["apps"]:
        lines.append(f"--{_esc(a['name'])}: {a['gb']:.1f} GB")
    if st["docker"] and st.get("stop_docker", True):
        lines.append(f"--Docker Desktop: {st['docker']['gb']:.1f} GB")
    for mo in st["models"]:
        lines.append(f"--{_esc(mo['name'])} ({mo['runtime']}): {mo['gb']:.1f} GB")
    if not (st["apps"] or st["models"] or st["docker"]):
        lines.append("--Nothing on the quit list is running")
    lines.append(f"Could free up to ~{st['freeable_gb']:.1f} GB")
    lines.append("---")

    if busy:
        lines.append("Prep/restore running…")
    else:
        if st["target_met"]:
            lines.append("Prep: target already met")
        else:
            lines.append(_action(f"Prep ({st['profile']})", plugin, "prep", st["profile"]))
        others = [p for p in st["profiles"] if p != st["profile"]]
        if others:
            lines.append("Prep with profile")
            lines += ["--" + _action(p, plugin, "prep", p) for p in others]
        lines.append(_action("Show prep plan in Terminal…", plugin, "dryrun", st["profile"],
                             terminal=True, refresh=False))
        session = st.get("session")
        if session:
            quit_apps = session.get("quit_apps", [])
            what = ", ".join(quit_apps + (["Docker"] if session.get("docker_stopped") else []))
            lines.append(_action(f"Restore ({what or 'nothing to reopen'})", plugin, "restore"))
    lines.append("---")
    lines.append(_action("Edit config…", plugin, "config", refresh=False))
    lines.append("Refresh | refresh=true")
    return "\n".join(lines) + "\n"


def render_error(message: str, plugin: str) -> str:
    return "\n".join([
        "RAM ⚠ | sfimage=exclamationmark.triangle",
        "---",
        f"Headroom: {_esc(message)}",
        _action("Edit config…", plugin, "config", refresh=False),
        "Refresh | refresh=true",
    ]) + "\n"


# ------------------------------------------------------------------ actions

def _lock_path() -> Path:
    return state.session_path().with_name("menubar.lock")


def _busy() -> bool:
    """True if a prep/restore started from the menu bar is still running."""
    path = _lock_path()
    if not path.exists():
        return False
    with open(path) as f:
        try:
            fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return True
        fcntl.flock(f, fcntl.LOCK_UN)
    return False


def notify(title: str, message: str) -> None:
    def q(s: str) -> str:
        return s.replace("\\", "\\\\").replace('"', '\\"')
    subprocess.run(["osascript", "-e",
                    f'display notification "{q(message)}" with title "{q(title)}"'],
                   capture_output=True)


def _summary(output: str) -> str:
    """Pick the most useful lines of CLI output for a notification."""
    keep = [l.strip() for l in output.splitlines()
            if l.strip().startswith(("Available:", "Target", "Skipped", "Nothing", "Restored",
                                     "Some items", "No session", "headroom:"))]
    if keep:
        return " ".join(keep)[:220]
    lines = output.strip().splitlines()
    return lines[-1][:220] if lines else "Done."


def run_locked(cli_args: list[str], title: str) -> int:
    """Run a headroom CLI command under the menu-bar lock and notify the result."""
    path = _lock_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "w") as f:
        try:
            fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            notify("Headroom", "Already running.")
            return 1
        r = subprocess.run([sys.executable, "-m", "headroom", *cli_args],
                           capture_output=True, text=True, env=os.environ.copy())
    notify(title, _summary(r.stdout + r.stderr))
    return r.returncode


def do_action(action: str, args: list[str]) -> int:
    if action == "prep":
        profile = args[0] if args else None
        cli_args = ["prep", "--yes"] + (["--profile", profile] if profile else [])
        return run_locked(cli_args, f"Headroom prep{f' ({profile})' if profile else ''}")
    if action == "restore":
        return run_locked(["restore"], "Headroom restore")
    if action == "dryrun":
        from .cli import main
        profile = args[0] if args else None
        return main(["prep", "--dry-run"] + (["--profile", profile] if profile else []))
    if action == "config":
        from .memory import read_memory
        path, _ = config_mod.ensure_config(total_gb=read_memory().total_gb)
        subprocess.run(["open", "-t", str(path)])
        return 0
    print(f"unknown action: {action}", file=sys.stderr)
    return 1


def plugin_main(argv: list[str]) -> int:
    plugin = os.environ.get("HEADROOM_PLUGIN") or os.environ.get("SWIFTBAR_PLUGIN_PATH") or ""
    if argv:
        return do_action(argv[0], argv[1:])
    from .cli import collect_status
    from .config import ConfigError
    try:
        st = collect_status()
    except ConfigError as e:
        sys.stdout.write(render_error(f"config error: {e}", plugin))
        return 0
    except Exception as e:  # never leave the menu bar blank
        sys.stdout.write(render_error(f"{type(e).__name__}: {e}", plugin))
        return 0
    sys.stdout.write(render(st, plugin, busy=_busy()))
    return 0


# ------------------------------------------------------------------ install

def stub_script() -> str:
    """The plugin file placed in the SwiftBar/xbar folder."""
    pkg_parent = Path(__file__).resolve().parent.parent
    return f"""#!/bin/bash
# <xbar.title>Headroom</xbar.title>
# <xbar.desc>Memory pressure and one-click RAM prep for heavy tasks.</xbar.desc>
# <xbar.dependencies>python3</xbar.dependencies>
# <swiftbar.hideRunInTerminal>true</swiftbar.hideRunInTerminal>
# <swiftbar.hideDisablePlugin>true</swiftbar.hideDisablePlugin>
# Generated by `headroom menubar --install`. Re-run it after moving Headroom.
export HEADROOM_PLUGIN="$0"
# Menu-bar apps get a minimal PATH; add where ollama, lms and docker usually live.
export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$HOME/.lmstudio/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
export PYTHONPATH={shlex.quote(str(pkg_parent))}${{PYTHONPATH:+:$PYTHONPATH}}
exec {shlex.quote(sys.executable)} -m headroom.menubar "$@"
"""


def find_plugin_dir() -> Path | None:
    r = subprocess.run(["defaults", "read", "com.ameba.SwiftBar", "PluginDirectory"],
                       capture_output=True, text=True)
    if r.returncode == 0 and r.stdout.strip():
        return Path(os.path.expanduser(r.stdout.strip()))
    xbar = Path.home() / "Library" / "Application Support" / "xbar" / "plugins"
    if xbar.is_dir():
        return xbar
    return None


def install(plugin_dir: Path | None) -> int:
    plugin_dir = plugin_dir or find_plugin_dir()
    if plugin_dir is None:
        print("headroom: no SwiftBar or xbar plugin folder found. Install SwiftBar "
              "(brew install --cask swiftbar), pick a plugin folder, then re-run, "
              "or pass --dir.", file=sys.stderr)
        return 1
    plugin_dir.mkdir(parents=True, exist_ok=True)
    path = plugin_dir / STUB_NAME
    path.write_text(stub_script())
    path.chmod(0o755)
    print(f"Installed {path}")
    print("SwiftBar/xbar picks it up on its next refresh (or choose 'Refresh all').")
    return 0


def uninstall(plugin_dir: Path | None) -> int:
    plugin_dir = plugin_dir or find_plugin_dir()
    path = plugin_dir / STUB_NAME if plugin_dir else None
    if path is None or not path.exists():
        print("Menu-bar plugin is not installed.")
        return 0
    path.unlink()
    print(f"Removed {path}")
    return 0


if __name__ == "__main__":
    sys.exit(plugin_main(sys.argv[1:]))
