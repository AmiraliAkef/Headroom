"""headroom: free usable RAM on macOS before a heavy task, and put things back after."""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
import time
from dataclasses import dataclass
from typing import Callable

from . import __version__, apps, docker, models, state
from .config import Config, ConfigError, Profile, ensure_config, load_config
from .memory import GB, MemoryStats, read_memory

EXIT_OK, EXIT_ERROR, EXIT_TARGET_NOT_REACHED = 0, 1, 2
SETTLE_SECONDS = 2.0


def gb(n_bytes: float) -> str:
    return f"{n_bytes / GB:.1f} GB"


@dataclass
class Candidate:
    kind: str  # "app" | "docker" | "model"
    name: str  # display name
    est_bytes: int
    action: Callable[[], bool]
    record: tuple[str, object]  # (session key, value) recorded on success


def build_candidates(profile: Profile, procs: list[apps.Process], loaded: list[models.LoadedModel],
                     self_apps: set[str], force: bool = False) -> list[Candidate]:
    """Everything prep may act on for this profile, largest first.

    Only apps on the profile's quit list are considered, and protected apps
    (including the app running this tool) are always excluded.
    """
    cands: list[Candidate] = []
    quit_names = [n for n in profile.quit_apps if not apps.is_protected(n, self_apps)]
    docker_handled = profile.stop_docker
    if docker_handled:
        quit_names = [n for n in quit_names if n != docker.APP_NAME]

    for u in apps.running_apps(quit_names, procs):
        cands.append(Candidate(
            "app", u.name, u.rss_bytes,
            (lambda n=u.name: apps.quit_app(n, force=force, self_apps=self_apps)),
            ("quit_apps", u.name)))

    if docker_handled:
        du = docker.usage(procs)
        if du is not None:
            cands.append(Candidate("docker", "Docker Desktop", du.rss_bytes, docker.stop,
                                   ("docker_stopped", True)))

    if profile.unload_models:
        lms = [m for m in loaded if m.runtime == "lmstudio"]
        for m in loaded:
            if m.runtime == "ollama":
                cands.append(Candidate("model", f"{m.name} (Ollama)", m.size_bytes,
                                       (lambda m=m: models.unload(m)),
                                       ("unloaded_models", m.name)))
        if lms:
            names = ", ".join(m.name for m in lms)
            cands.append(Candidate("model", f"LM Studio: {names}",
                                   sum(m.size_bytes for m in lms), models.unload_all_lmstudio,
                                   ("unloaded_models", [m.name for m in lms])))

    cands.sort(key=lambda c: c.est_bytes, reverse=True)
    return cands


# ---------------------------------------------------------------- status

def collect_status(profile_name: str | None = None) -> dict:
    """Everything `status` reports, as a JSON-ready dict. Read-only.

    Raises ConfigError for a bad config or unknown profile; config warnings
    are returned under "warnings".
    """
    mem = read_memory()
    cfg = load_config(total_gb=mem.total_gb)
    profile = cfg.profile(profile_name)
    procs = apps.list_processes()
    self_apps = apps.ancestor_apps(procs)
    loaded = models.loaded_models()
    running = [u for u in apps.running_apps(profile.quit_apps, procs)
               if not apps.is_protected(u.name, self_apps)]
    du = docker.usage(procs)
    freeable = sum(c.est_bytes for c in build_candidates(profile, procs, loaded, self_apps))
    return {
        "memory": mem.to_dict(),
        "profile": profile.name,
        "profiles": sorted(cfg.profiles),
        "default_profile": cfg.default_profile,
        "target_gb": profile.target_gb,
        "target_met": mem.available_bytes >= profile.target_gb * GB,
        "stop_docker": profile.stop_docker,
        "session": state.load_session(),
        "apps": [{"name": u.name, "rss_bytes": u.rss_bytes, "gb": round(u.gb, 2)}
                 for u in running],
        "docker": None if du is None else {"rss_bytes": du.rss_bytes, "gb": round(du.gb, 2)},
        "models": [{"name": m.name, "runtime": m.runtime, "size_bytes": m.size_bytes,
                    "gb": round(m.gb, 2)} for m in loaded],
        "freeable_bytes": freeable,
        "freeable_gb": round(freeable / GB, 2),
        "warnings": cfg.warnings,
    }


def cmd_status(args) -> int:
    try:
        st = collect_status(args.profile)
    except ConfigError as e:
        print(f"headroom: config error: {e}", file=sys.stderr)
        return EXIT_ERROR
    for w in st["warnings"]:
        print(f"headroom: warning: {w}", file=sys.stderr)
    if args.json:
        print(json.dumps(st, indent=2))
        return EXIT_OK

    m = st["memory"]
    print(f"Total RAM:        {gb(m['total_bytes'])}")
    print(f"Available (est.): {gb(m['available_bytes'])}")
    print(f"Compressed:       {gb(m['compressed_bytes'])}")
    print(f"Swap used:        {gb(m['swap_used_bytes'])}")
    print(f"Memory pressure:  {m['pressure']}")
    print()
    print(f"Quit list (profile '{st['profile']}', target {st['target_gb']:.1f} GB):")
    for a in st["apps"] or [None]:
        print(f"  {a['name']:<28} {gb(a['rss_bytes']):>9}" if a else "  none running")
    if st["docker"]:
        note = "" if st["stop_docker"] else "  (not stopped by this profile)"
        print(f"\nDocker Desktop: {gb(st['docker']['rss_bytes'])}{note}")
    print("\nLoaded local models:")
    for mo in st["models"] or [None]:
        print(f"  {mo['name']:<28} {gb(mo['size_bytes']):>9}  [{mo['runtime']}]" if mo
              else "  none")
    print(f"\nPrep could free up to ~{gb(st['freeable_bytes'])} (RSS-based estimate; usually less).")
    if st["session"]:
        print("A prep session is active: 'headroom restore' reopens what was quit.")
    return EXIT_OK


def _load_config(mem: MemoryStats) -> Config | None:
    try:
        cfg = load_config(total_gb=mem.total_gb)
    except ConfigError as e:
        print(f"headroom: config error: {e}", file=sys.stderr)
        return None
    for w in cfg.warnings:
        print(f"headroom: warning: {w}", file=sys.stderr)
    return cfg


# ---------------------------------------------------------------- prep

@dataclass
class PrepResult:
    rc: int
    changed: bool = False  # something was quit/stopped/unloaded in this run
    aborted: bool = False  # user declined the confirmation


def cmd_prep(args) -> int:
    result = _prep(args)
    if not args.then:
        return result.rc
    if args.dry_run:
        print(f"Would then run: {args.then}")
        return result.rc
    if result.rc == EXIT_ERROR or result.aborted:
        print("Not running the command.", file=sys.stderr)
        return EXIT_ERROR
    if result.rc == EXIT_TARGET_NOT_REACHED:
        print("Running the command anyway.")
    return run_then(args.then, restore_after=result.changed)


def run_then(command: str, restore_after: bool) -> int:
    """Run the heavy task, then restore what prep quit, however the task ends."""
    print(f"\n$ {command}", flush=True)
    rc = EXIT_ERROR
    try:
        proc = subprocess.Popen(command, shell=True)
        while True:
            try:
                rc = proc.wait()
                break
            except KeyboardInterrupt:
                # The child got the same Ctrl-C; wait for it to exit, then restore.
                continue
        if rc < 0:
            rc = 128 - rc  # killed by a signal, shell convention
    except OSError as e:
        print(f"headroom: could not run command: {e}", file=sys.stderr)
    finally:
        if restore_after:
            print(f"\nCommand exited with {rc}. Restoring...")
            cmd_restore(argparse.Namespace())
        else:
            print(f"\nCommand exited with {rc}. Nothing was quit, nothing to restore.")
    return rc


def _confirm(prompt: str) -> bool:
    try:
        return input(prompt).strip().lower() in ("y", "yes")
    except EOFError:
        return False


def _prep(args) -> PrepResult:
    mem = read_memory()
    cfg = _load_config(mem)
    if cfg is None:
        return PrepResult(EXIT_ERROR)
    try:
        profile = cfg.profile(args.profile)
    except ConfigError as e:
        print(f"headroom: {e}", file=sys.stderr)
        return PrepResult(EXIT_ERROR)
    target_gb = args.target_gb if args.target_gb is not None else profile.target_gb
    if target_gb <= 0 or target_gb >= mem.total_gb:
        print(f"headroom: target must be between 0 and total RAM ({mem.total_gb:.1f} GB)",
              file=sys.stderr)
        return PrepResult(EXIT_ERROR)
    target = target_gb * GB

    print(f"Profile '{profile.name}': target {target_gb:.1f} GB available, "
          f"currently {gb(mem.available_bytes)} (pressure: {mem.pressure}).")
    if mem.available_bytes >= target:
        print("Target already met. Nothing to do.")
        return PrepResult(EXIT_OK)

    procs = apps.list_processes()
    self_apps = apps.ancestor_apps(procs)
    cands = build_candidates(profile, procs, models.loaded_models(), self_apps, force=args.force)
    if not cands:
        print("Nothing on this profile's list is running.")
        return PrepResult(EXIT_TARGET_NOT_REACHED)

    needed = target - mem.available_bytes
    print(f"\nNeed ~{gb(needed)} more. Plan (largest first, stops once target is reached):")
    for c in cands:
        verb = {"app": "quit", "docker": "stop", "model": "unload"}[c.kind]
        print(f"  {verb:<7} {c.name:<36} ~{gb(c.est_bytes):>9}")
    total_est = sum(c.est_bytes for c in cands)
    print(f"  {'':<7} {'expected total (upper bound)':<36} ~{gb(total_est):>9}")
    if total_est < needed:
        print("  Note: even all of this may not reach the target.")

    if args.dry_run:
        print("\nDry run: nothing changed.")
        return PrepResult(EXIT_OK)
    if not args.yes and not _confirm("\nProceed? [y/N] "):
        print("Aborted.")
        return PrepResult(EXIT_OK, aborted=True)

    before = mem.available_bytes
    state.save_session({"profile": profile.name, "available_before_gb": round(before / GB, 1),
                        "quit_apps": [], "unloaded_models": [], "docker_stopped": False})
    skipped: list[str] = []
    changed = False
    print()
    for c in cands:
        if mem.available_bytes >= target:
            break
        print(f"  {c.name} ... ", end="", flush=True)
        ok = c.action()
        if not ok:
            print("did not stop in time, skipped")
            skipped.append(c.name)
            continue
        changed = True
        key, value = c.record
        if key == "docker_stopped":
            state.save_session({"docker_stopped": True})
        else:
            state.save_session({key: value if isinstance(value, list) else [value]})
        time.sleep(SETTLE_SECONDS)
        mem = read_memory()
        print(f"done (available now {gb(mem.available_bytes)})")

    state.save_session({"available_after_gb": round(mem.available_bytes / GB, 1),
                        "profile": profile.name})
    print(f"\nAvailable: {gb(before)} -> {gb(mem.available_bytes)} "
          f"(target {target_gb:.1f} GB, pressure: {mem.pressure})")
    if skipped:
        hint = "" if args.force else " (use --force to force-quit apps on the quit list)"
        print(f"Skipped: {', '.join(skipped)}{hint}")
    if not args.then:
        print("Run 'headroom restore' afterwards to reopen what was quit.")
    if mem.available_bytes < target:
        print("Target not reached after quitting everything allowed.")
        return PrepResult(EXIT_TARGET_NOT_REACHED, changed)
    return PrepResult(EXIT_OK, changed)


# ---------------------------------------------------------------- restore

def cmd_restore(args) -> int:
    session = state.load_session()
    if session is None:
        print("No session to restore.")
        return EXIT_OK
    failed_apps = []
    for name in session.get("quit_apps", []):
        if apps.open_app(name):
            print(f"  reopened {name}")
        else:
            print(f"  could not reopen {name}")
            failed_apps.append(name)
    docker_failed = False
    if session.get("docker_stopped"):
        if docker.start():
            print("  started Docker Desktop")
        else:
            print("  could not start Docker Desktop")
            docker_failed = True
    if session.get("unloaded_models"):
        print(f"  models not reloaded (load what you need): "
              f"{', '.join(session['unloaded_models'])}")
    state.clear_session()
    if failed_apps or docker_failed:
        state.save_session({"profile": session.get("profile"), "quit_apps": failed_apps,
                            "docker_stopped": docker_failed, "unloaded_models": []})
        print("Some items failed; they were kept in the session for another 'restore'.")
        return EXIT_ERROR
    print("Restored.")
    return EXIT_OK


# ---------------------------------------------------------------- config

def cmd_config(args) -> int:
    path, created = ensure_config(total_gb=read_memory().total_gb)
    print(path)
    if created:
        print("Created from config.example.toml. Edit it to set your profiles.",
              file=sys.stderr)
    return EXIT_OK


def cmd_menubar(args) -> int:
    from pathlib import Path

    from . import menubar
    plugin_dir = Path(args.dir).expanduser() if args.dir else None
    if args.uninstall:
        return menubar.uninstall(plugin_dir)
    if args.install:
        return menubar.install(plugin_dir)
    sys.stdout.write(menubar.stub_script())
    return EXIT_OK


# ---------------------------------------------------------------- main

def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="headroom", description=__doc__)
    p.add_argument("--version", action="version", version=f"headroom {__version__}")
    sub = p.add_subparsers(dest="command", required=True)

    s = sub.add_parser("status", help="show memory and what prep could free (read-only)")
    s.add_argument("--json", action="store_true", help="machine-readable output")
    s.add_argument("--profile", help="profile to evaluate (default: the config's default)")
    s.set_defaults(func=cmd_status)

    s = sub.add_parser("prep", help="quit listed apps until the memory target is reached")
    s.add_argument("--profile", help="profile name from the config")
    s.add_argument("--target-gb", type=float, help="override the profile's target")
    s.add_argument("--dry-run", action="store_true", help="show the plan, change nothing")
    s.add_argument("--yes", "-y", action="store_true", help="don't ask for confirmation")
    s.add_argument("--force", action="store_true",
                   help="force-quit quit-list apps that don't quit in time")
    s.add_argument("--then", metavar="COMMAND",
                   help="run COMMAND (via the shell) after prep, then restore when it exits")
    s.set_defaults(func=cmd_prep)

    s = sub.add_parser("restore", help="reopen what the last prep quit")
    s.set_defaults(func=cmd_restore)

    s = sub.add_parser("config", help="print the config path, creating it if missing")
    s.set_defaults(func=cmd_config)

    s = sub.add_parser("menubar", help="install the SwiftBar/xbar menu-bar plugin")
    g = s.add_mutually_exclusive_group()
    g.add_argument("--install", action="store_true", help="write the plugin into the plugin folder")
    g.add_argument("--uninstall", action="store_true", help="remove the plugin")
    s.add_argument("--dir", help="plugin folder (default: SwiftBar's, else xbar's)")
    s.set_defaults(func=cmd_menubar)
    return p


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    if sys.platform != "darwin":
        print("headroom: macOS only.", file=sys.stderr)
        return EXIT_ERROR
    try:
        return args.func(args)
    except KeyboardInterrupt:
        print("\nInterrupted. Run 'headroom restore' to reopen anything already quit.",
              file=sys.stderr)
        return EXIT_ERROR


if __name__ == "__main__":
    sys.exit(main())
