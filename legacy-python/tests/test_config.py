import tempfile
import unittest
from pathlib import Path

from headroom import config
from headroom.config import ConfigError, parse_config


def prof(**kw):
    base = {"target_gb": 12, "quit_apps": ["Slack"]}
    base.update(kw)
    return {"profiles": {"p": base}}


class TestConfig(unittest.TestCase):
    def test_example_parses(self):
        import tomllib
        cfg = parse_config(tomllib.loads(config.EXAMPLE_PATH.read_text()), total_gb=64)
        self.assertEqual(cfg.default_profile, "llm")
        self.assertEqual(cfg.profile(None).target_gb, 24)
        self.assertEqual(cfg.profile("build").quit_apps, ["Slack", "Discord", "Spotify"])
        self.assertFalse(cfg.profile("build").stop_docker)
        self.assertEqual(cfg.warnings, [])

    def test_unknown_keys_warn(self):
        data = prof(colour="red")
        data["extra"] = 1
        cfg = parse_config(data)
        self.assertEqual(len(cfg.warnings), 2)

    def test_protected_app_errors(self):
        with self.assertRaisesRegex(ConfigError, "Finder"):
            parse_config(prof(quit_apps=["Slack", "Finder"]))

    def test_target_validation(self):
        for bad in (0, -1, "12", True):
            with self.assertRaises(ConfigError):
                parse_config(prof(target_gb=bad))
        with self.assertRaisesRegex(ConfigError, "less than total RAM"):
            parse_config(prof(target_gb=16), total_gb=16)
        parse_config(prof(target_gb=15.5), total_gb=16)

    def test_unknown_profile(self):
        cfg = parse_config(prof())
        with self.assertRaises(ConfigError):
            cfg.profile("nope")
        with self.assertRaises(ConfigError):
            parse_config({**prof(), "default_profile": "nope"})

    def test_missing_file_uses_scaled_default(self):
        with tempfile.TemporaryDirectory() as d:
            cfg = config.load_config(total_gb=16, path=Path(d) / "none.toml")
            self.assertIsNone(cfg.path)
            self.assertLess(cfg.profile(None).target_gb, 16)
            cfg = config.load_config(total_gb=128, path=Path(d) / "none.toml")
            self.assertEqual(cfg.profile(None).target_gb, 24)

    def test_created_config_is_valid_on_any_mac(self):
        import tomllib
        for total in (8, 16, 24, 64):
            with tempfile.TemporaryDirectory() as d:
                path = Path(d) / "config.toml"
                config.ensure_config(path, total_gb=total)
                cfg = config.load_config(total_gb=total, path=path)  # must not raise
                self.assertEqual(cfg.warnings, [])
                for p in cfg.profiles.values():
                    self.assertLess(p.target_gb, total)
                self.assertIn("# Only apps listed", path.read_text())  # comments kept

    def test_created_config_only_scales_invalid_targets(self):
        import tomllib
        data = tomllib.loads(config.example_text(16))
        self.assertEqual(data["profiles"]["llm"]["target_gb"], 9.6)   # 24 doesn't fit
        self.assertEqual(data["profiles"]["build"]["target_gb"], 12)  # 12 does
        self.assertEqual(config.example_text(64), config.EXAMPLE_PATH.read_text())
        self.assertEqual(config.example_text(None), config.EXAMPLE_PATH.read_text())

    def test_ensure_config_creates_once(self):
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / "headroom" / "config.toml"
            self.assertEqual(config.ensure_config(path), (path, True))
            self.assertEqual(path.read_text(), config.EXAMPLE_PATH.read_text())
            path.write_text("# mine\n")
            self.assertEqual(config.ensure_config(path), (path, False))
            self.assertEqual(path.read_text(), "# mine\n")


if __name__ == "__main__":
    unittest.main()
