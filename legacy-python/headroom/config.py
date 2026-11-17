"""Loading and validating the TOML config."""

from __future__ import annotations

import os
import re
import tomllib
from dataclasses import dataclass, field
from pathlib import Path

from .apps import PROTECTED_APPS

PROFILE_KEYS = {"target_gb", "quit_apps", "unload_models", "stop_docker"}
TOP_KEYS = {"default_profile", "profiles"}

EXAMPLE_PATH = Path(__file__).with_name("config.example.toml")


class ConfigError(Exception):
    pass


@dataclass
class Profile:
    name: str
    target_gb: float
    quit_apps: list[str] = field(default_factory=list)
    unload_models: bool = True
    stop_docker: bool = False


@dataclass
class Config:
    default_profile: str
    profiles: dict[str, Profile]
    path: Path | None = None
    warnings: list[str] = field(default_factory=list)

    def profile(self, name: str | None) -> Profile:
        name = name or self.default_profile
        if name not in self.profiles:
            known = ", ".join(sorted(self.profiles)) or "none"
            raise ConfigError(f"unknown profile {name!r} (known: {known})")
        return self.profiles[name]


# Used when no config file exists: status works, and prep has a sensible default.
DEFAULT_CONFIG = {
    "default_profile": "llm",
    "profiles": {
        "llm": {
            "target_gb": 24,
            "quit_apps": ["Google Chrome", "Slack", "Discord", "Spotify", "Notion",
                          "Microsoft Teams"],
            "unload_models": True,
            "stop_docker": True,
        },
    },
}


def fit_target(target_gb: float, total_gb: float | None) -> float:
    """Cap a default target at 60% of total RAM so it is valid on smaller Macs."""
    if total_gb is None:
        return target_gb
    return min(target_gb, round(total_gb * 0.6, 1))


def default_config(total_gb: float | None) -> dict:
    """Built-in config, with the target scaled down on smaller machines."""
    import copy
    data = copy.deepcopy(DEFAULT_CONFIG)
    for prof in data["profiles"].values():
        prof["target_gb"] = fit_target(prof["target_gb"], total_gb)
    return data


_TARGET_LINE = re.compile(r"^(\s*target_gb\s*=\s*)([\d.]+)(.*)$", re.MULTILINE)


def example_text(total_gb: float | None = None) -> str:
    """The example config, with any target_gb too big for this Mac scaled down.

    Edits the text rather than re-serialising so the comments survive.
    """
    text = EXAMPLE_PATH.read_text()
    if total_gb is None:
        return text

    def fix(m: re.Match) -> str:
        old = float(m.group(2))
        if old < total_gb:  # already valid here; leave the user's example alone
            return m.group(0)
        new = fit_target(old, total_gb)
        shown = f"{new:g}"
        note = f"  # scaled from {m.group(2)} for this Mac's {total_gb:.0f} GB"
        rest = m.group(3)
        if "#" in rest:  # keep the original comment after ours
            rest = rest[:rest.index("#")].rstrip() + note + ";" + rest[rest.index("#") + 1:]
        else:
            rest = rest.rstrip() + note
        return m.group(1) + shown + rest

    return _TARGET_LINE.sub(fix, text)


def config_path() -> Path:
    base = os.environ.get("XDG_CONFIG_HOME") or str(Path.home() / ".config")
    return Path(base) / "headroom" / "config.toml"


def parse_config(data: dict, total_gb: float | None = None, path: Path | None = None) -> Config:
    """Validate a parsed TOML dict. Raises ConfigError; collects warnings."""
    warnings: list[str] = []
    for k in data:
        if k not in TOP_KEYS:
            warnings.append(f"unknown key {k!r}")
    raw_profiles = data.get("profiles", {})
    if not isinstance(raw_profiles, dict) or not raw_profiles:
        raise ConfigError("config needs at least one [profiles.<name>] table")

    profiles: dict[str, Profile] = {}
    for name, raw in raw_profiles.items():
        if not isinstance(raw, dict):
            raise ConfigError(f"profiles.{name} must be a table")
        for k in raw:
            if k not in PROFILE_KEYS:
                warnings.append(f"unknown key {k!r} in profiles.{name}")
        if "target_gb" not in raw:
            raise ConfigError(f"profiles.{name}.target_gb is required")
        target = raw["target_gb"]
        if isinstance(target, bool) or not isinstance(target, (int, float)) or target <= 0:
            raise ConfigError(f"profiles.{name}.target_gb must be a positive number")
        if total_gb is not None and target >= total_gb:
            raise ConfigError(
                f"profiles.{name}.target_gb ({target}) must be less than total RAM "
                f"({total_gb:.1f} GB)")
        quit_apps = raw.get("quit_apps", [])
        if not isinstance(quit_apps, list) or not all(isinstance(a, str) for a in quit_apps):
            raise ConfigError(f"profiles.{name}.quit_apps must be a list of app names")
        for app in quit_apps:
            if app in PROTECTED_APPS:
                raise ConfigError(f"profiles.{name}.quit_apps contains protected app {app!r}")
        for key in ("unload_models", "stop_docker"):
            if key in raw and not isinstance(raw[key], bool):
                raise ConfigError(f"profiles.{name}.{key} must be true or false")
        profiles[name] = Profile(
            name=name,
            target_gb=float(target),
            quit_apps=list(dict.fromkeys(quit_apps)),
            unload_models=raw.get("unload_models", True),
            stop_docker=raw.get("stop_docker", False),
        )

    default = data.get("default_profile", next(iter(profiles)))
    if default not in profiles:
        raise ConfigError(f"default_profile {default!r} is not a defined profile")
    return Config(default, profiles, path, warnings)


def load_config(total_gb: float | None = None, path: Path | None = None) -> Config:
    """Load the user's config, or the built-in default if the file doesn't exist."""
    path = path or config_path()
    if not path.exists():
        return parse_config(default_config(total_gb), total_gb, None)
    try:
        data = tomllib.loads(path.read_text())
    except tomllib.TOMLDecodeError as e:
        raise ConfigError(f"{path}: {e}") from e
    return parse_config(data, total_gb, path)


def ensure_config(path: Path | None = None,
                  total_gb: float | None = None) -> tuple[Path, bool]:
    """Create the config from the example if missing. Returns (path, created).

    With ``total_gb``, targets that wouldn't fit this Mac are scaled down, so
    the created file is always valid here.
    """
    path = path or config_path()
    if path.exists():
        return path, False
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(example_text(total_gb))
    return path, True
