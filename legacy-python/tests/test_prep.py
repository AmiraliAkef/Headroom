"""prep/restore behaviour with every quit/open/unload call mocked."""

import io
import json
import os
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

from headroom import apps, cli, state
from headroom.config import parse_config
from headroom.memory import GB, MemoryStats
from tests.helpers import fixture

PROCS = apps.parse_ps(fixture("ps_apps.txt"))


def mem(avail_gb):
    return MemoryStats(int(32 * GB), int(avail_gb * GB), 0, 0, 0, "warning")


def cfg(**profile):
    p = {"target_gb": 20, "quit_apps": ["Google Chrome", "Slack", "Spotify", "Discord"],
         "unload_models": False, "stop_docker": False}
    p.update(profile)
    return parse_config({"profiles": {"p": p}}, total_gb=32)


def prep_args(**kw):
    d = dict(profile=None, target_gb=None, dry_run=False, yes=True, force=False, then=None)
    d.update(kw)
    return SimpleNamespace(**d)


class PrepTestCase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        env = mock.patch.dict(os.environ, {"XDG_STATE_HOME": self.tmp.name})
        env.start()
        self.addCleanup(env.stop)
        self.quit = mock.MagicMock(return_value=True)
        self.docker_stop = mock.MagicMock(return_value=True)
        patches = [
            mock.patch.object(apps, "list_processes", return_value=PROCS),
            mock.patch.object(apps, "ancestor_apps", return_value={"Terminal"}),
            mock.patch.object(apps, "quit_app", self.quit),
            mock.patch.object(apps, "open_app", return_value=True),
            mock.patch("headroom.docker.stop", self.docker_stop),
            mock.patch("headroom.docker.start", return_value=True),
            mock.patch("headroom.models.loaded_models", return_value=[]),
            mock.patch("headroom.cli.time.sleep"),
        ]
        for p in patches:
            p.start()
            self.addCleanup(p.stop)

    def run_prep(self, config, mems, **kw):
        with mock.patch.object(cli, "load_config", return_value=config), \
                mock.patch.object(cli, "read_memory", side_effect=mems), \
                redirect_stdout(io.StringIO()) as out:
            rc = cli.cmd_prep(prep_args(**kw))
        return rc, out.getvalue()

    def quit_names(self):
        return [c.args[0] for c in self.quit.call_args_list]


class TestPrep(PrepTestCase):
    def test_target_already_met(self):
        rc, out = self.run_prep(cfg(), [mem(25)])
        self.assertEqual(rc, 0)
        self.assertIn("already met", out)
        self.quit.assert_not_called()

    def test_dry_run_never_quits(self):
        rc, out = self.run_prep(cfg(stop_docker=True), [mem(5)], dry_run=True)
        self.assertEqual(rc, 0)
        self.assertIn("Google Chrome", out)
        self.assertIn("Docker Desktop", out)
        self.quit.assert_not_called()
        self.docker_stop.assert_not_called()
        self.assertIsNone(state.load_session())

    def test_stops_once_target_reached(self):
        # Docker (4.2 GB est.) first, then Chrome; target met after Chrome.
        rc, _ = self.run_prep(cfg(stop_docker=True), [mem(10), mem(15), mem(21)])
        self.assertEqual(rc, 0)
        self.docker_stop.assert_called_once()
        self.assertEqual(self.quit_names(), ["Google Chrome"])
        s = state.load_session()
        self.assertEqual(s["quit_apps"], ["Google Chrome"])
        self.assertTrue(s["docker_stopped"])
        self.assertEqual(s["available_before_gb"], 10.0)
        self.assertEqual(s["available_after_gb"], 21.0)

    def test_only_quit_list_and_never_protected(self):
        config = cfg(quit_apps=["Slack"], stop_docker=False)
        rc, _ = self.run_prep(config, [mem(5), mem(6)])
        self.assertEqual(rc, 2)  # target not reached
        self.assertEqual(self.quit_names(), ["Slack"])
        self.docker_stop.assert_not_called()

    def test_self_app_excluded_even_if_listed(self):
        # "Terminal" can't be in config (validation), but the running app may be
        # e.g. VS Code: listed by the user, yet must be skipped.
        with mock.patch.object(apps, "ancestor_apps", return_value={"Slack"}):
            rc, _ = self.run_prep(cfg(quit_apps=["Slack", "Spotify"]), [mem(5), mem(6)])
        self.assertEqual(self.quit_names(), ["Spotify"])

    def test_failed_quit_is_skipped_and_not_recorded(self):
        self.quit.side_effect = lambda name, **kw: name != "Google Chrome"
        rc, out = self.run_prep(cfg(), [mem(5), mem(7), mem(8)])
        self.assertEqual(rc, 2)
        self.assertIn("skipped", out)
        self.assertEqual(state.load_session()["quit_apps"], ["Slack", "Spotify"])

    def test_force_is_passed_through(self):
        self.run_prep(cfg(quit_apps=["Slack"]), [mem(5), mem(25)], force=True)
        self.assertTrue(self.quit.call_args.kwargs["force"])

    def test_declined_confirmation(self):
        with mock.patch("builtins.input", return_value="n"):
            rc, out = self.run_prep(cfg(), [mem(5)], yes=False)
        self.assertEqual(rc, 0)
        self.quit.assert_not_called()

    def test_merges_into_existing_session(self):
        self.run_prep(cfg(quit_apps=["Slack"]), [mem(5), mem(6)])
        self.run_prep(cfg(quit_apps=["Spotify"]), [mem(6), mem(7)])
        s = state.load_session()
        self.assertEqual(s["quit_apps"], ["Slack", "Spotify"])
        self.assertEqual(s["available_before_gb"], 5.0)


class TestRestore(PrepTestCase):
    def test_restore_reopens_exactly_what_was_quit(self):
        self.run_prep(cfg(stop_docker=True), [mem(10), mem(15), mem(21)])
        with redirect_stdout(io.StringIO()), \
                mock.patch.object(apps, "open_app", return_value=True) as open_app, \
                mock.patch("headroom.docker.start", return_value=True) as start:
            rc = cli.cmd_restore(SimpleNamespace())
        self.assertEqual(rc, 0)
        self.assertEqual([c.args[0] for c in open_app.call_args_list], ["Google Chrome"])
        start.assert_called_once()
        self.assertIsNone(state.load_session())

    def test_no_session(self):
        with redirect_stdout(io.StringIO()) as out:
            self.assertEqual(cli.cmd_restore(SimpleNamespace()), 0)
        self.assertIn("No session", out.getvalue())

    def test_failed_reopen_kept(self):
        state.save_session({"quit_apps": ["Slack", "Spotify"], "docker_stopped": False})
        with redirect_stdout(io.StringIO()), \
                mock.patch.object(apps, "open_app", side_effect=lambda n: n == "Slack"):
            self.assertEqual(cli.cmd_restore(SimpleNamespace()), 1)
        self.assertEqual(state.load_session()["quit_apps"], ["Spotify"])


class TestState(unittest.TestCase):
    def test_merge(self):
        a = {"created_at": "t0", "profile": "llm", "quit_apps": ["Slack"],
             "docker_stopped": True, "unloaded_models": ["m1"],
             "available_before_gb": 5.0, "available_after_gb": 9.0}
        b = {"profile": "build", "quit_apps": ["Slack", "Spotify"], "docker_stopped": False,
             "unloaded_models": ["m2"], "available_before_gb": 9.0, "available_after_gb": 12.0}
        m = state.merge_session(a, b)
        self.assertEqual(m["quit_apps"], ["Slack", "Spotify"])
        self.assertEqual(m["unloaded_models"], ["m1", "m2"])
        self.assertTrue(m["docker_stopped"])
        self.assertEqual(m["created_at"], "t0")
        self.assertEqual(m["available_before_gb"], 5.0)
        self.assertEqual(m["available_after_gb"], 12.0)

    def test_roundtrip(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "s" / "session.json"
            state.save_session({"quit_apps": ["Slack"]}, p)
            self.assertIn("created_at", json.loads(p.read_text()))
            state.clear_session(p)
            self.assertIsNone(state.load_session(p))


class TestStatus(PrepTestCase):
    def test_status_changes_nothing(self):
        with mock.patch.object(cli, "load_config", return_value=cfg(stop_docker=True)), \
                mock.patch.object(cli, "read_memory", return_value=mem(8)), \
                redirect_stdout(io.StringIO()) as out:
            self.assertEqual(cli.cmd_status(SimpleNamespace(json=True, profile=None)), 0)
        data = json.loads(out.getvalue())
        self.assertEqual([a["name"] for a in data["apps"]], ["Google Chrome", "Slack", "Spotify"])
        self.assertIsNotNone(data["docker"])
        self.quit.assert_not_called()
        self.docker_stop.assert_not_called()
        self.assertIsNone(state.load_session())


if __name__ == "__main__":
    unittest.main()
