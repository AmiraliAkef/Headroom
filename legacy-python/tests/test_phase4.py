"""--then and the menu-bar plugin. Quit/open/notify calls are mocked."""

import io
import tempfile
import unittest
from contextlib import redirect_stdout, redirect_stderr
from pathlib import Path
from unittest import mock

from headroom import cli, menubar, state
from tests.test_prep import PrepTestCase, cfg, mem


class TestThen(PrepTestCase):
    def run_then(self, mems, command="true", **kw):
        with mock.patch.object(cli, "load_config", return_value=cfg(**kw.pop("profile", {}))), \
                mock.patch.object(cli, "read_memory", side_effect=mems), \
                redirect_stdout(io.StringIO()) as out, redirect_stderr(io.StringIO()):
            rc = cli.cmd_prep(_args(then=command, **kw))
        return rc, out.getvalue()

    def test_runs_command_then_restores(self):
        rc, out = self.run_then([mem(5), mem(25)], "exit 7", profile={"quit_apps": ["Slack"]})
        self.assertEqual(rc, 7)  # the command's exit code
        self.assertEqual([c.args[0] for c in self.quit.call_args_list], ["Slack"])
        self.assertIn("Restoring", out)
        self.assertIsNone(state.load_session())

    def test_restores_even_if_command_cannot_start(self):
        with mock.patch("subprocess.Popen", side_effect=OSError("boom")):
            rc, out = self.run_then([mem(5), mem(25)], profile={"quit_apps": ["Slack"]})
        self.assertEqual(rc, 1)
        self.assertIsNone(state.load_session())

    def test_target_met_runs_without_restoring_old_session(self):
        state.save_session({"quit_apps": ["Spotify"]})
        rc, out = self.run_then([mem(25)], "exit 0")
        self.assertEqual(rc, 0)
        self.assertIn("nothing to restore", out)
        self.assertEqual(state.load_session()["quit_apps"], ["Spotify"])

    def test_dry_run_does_not_run(self):
        with mock.patch("subprocess.Popen") as popen:
            rc, out = self.run_then([mem(5)], dry_run=True)
        popen.assert_not_called()
        self.assertIn("Would then run", out)
        self.quit.assert_not_called()

    def test_declined_does_not_run(self):
        with mock.patch("subprocess.Popen") as popen, mock.patch("builtins.input", return_value=""):
            rc, _ = self.run_then([mem(5)], yes=False)
        self.assertEqual(rc, 1)
        popen.assert_not_called()

    def test_target_not_reached_still_runs(self):
        rc, out = self.run_then([mem(5), mem(6)], "exit 0", profile={"quit_apps": ["Slack"]})
        self.assertEqual(rc, 0)
        self.assertIn("anyway", out)


def _args(**kw):
    from tests.test_prep import prep_args
    return prep_args(**kw)


def status(**over):
    st = {
        "memory": {"total_bytes": 32 * 1024**3, "available_bytes": int(9.4 * 1024**3),
                   "compressed_bytes": 1024**3, "swap_used_bytes": 2 * 1024**3,
                   "pressure": "warning"},
        "profile": "llm", "profiles": ["build", "llm"], "default_profile": "llm",
        "target_gb": 24.0, "target_met": False, "stop_docker": True, "session": None,
        "apps": [{"name": "Google Chrome", "gb": 2.1}, {"name": "Slack", "gb": 0.5}],
        "docker": {"gb": 4.2}, "models": [{"name": "qwen3", "runtime": "ollama", "gb": 23.0}],
        "freeable_gb": 29.8, "warnings": [],
    }
    st.update(over)
    return st


class TestMenubarRender(unittest.TestCase):
    PLUGIN = "/Users/x/Library/Application Support/xbar/plugins/headroom.30s.sh"

    def test_title_and_items(self):
        out = menubar.render(status(), self.PLUGIN)
        lines = out.splitlines()
        self.assertEqual(lines[0], "9.4G | sfimage=memorychip color=#E8A33D")
        self.assertIn("🟠 Memory pressure: warning", out)
        self.assertIn("--Google Chrome: 2.1 GB", out)
        self.assertIn("--Docker Desktop: 4.2 GB", out)
        self.assertIn("--qwen3 (ollama): 23.0 GB", out)
        prep = next(l for l in lines if l.startswith("Prep (llm)"))
        self.assertIn(f'bash="{self.PLUGIN}" param1=prep param2=llm', prep)
        self.assertIn("terminal=false refresh=true", prep)
        self.assertIn("--build | ", out)  # other profile in submenu
        self.assertNotIn("Restore", out)

    def test_normal_pressure_has_no_color(self):
        out = menubar.render(status(memory={**status()["memory"], "pressure": "normal"}), "p")
        self.assertEqual(out.splitlines()[0], "9.4G | sfimage=memorychip")

    def test_restore_shown_with_session(self):
        out = menubar.render(status(session={"quit_apps": ["Slack"], "docker_stopped": True}),
                             "p")
        self.assertIn("Restore (Slack, Docker) | bash=p param1=restore", out)

    def test_target_met_hides_prep(self):
        out = menubar.render(status(target_met=True), "p")
        self.assertIn("Prep: target already met", out)
        self.assertNotIn("param1=prep param2=llm", out)

    def test_busy_hides_actions(self):
        out = menubar.render(status(session={"quit_apps": ["Slack"]}), "p", busy=True)
        self.assertTrue(out.splitlines()[0].startswith("9.4G … |"))
        self.assertNotIn("param1=prep", out)
        self.assertNotIn("param1=restore", out)

    def test_pipes_in_names_escaped(self):
        out = menubar.render(status(apps=[{"name": "A|B", "gb": 1.0}]), "p")
        self.assertIn("--A¦B: 1.0 GB", out)

    def test_error_menu(self):
        out = menubar.render_error("config error: bad", "p")
        self.assertTrue(out.startswith("RAM ⚠"))
        self.assertIn("param1=config", out)


class TestMenubarActions(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        p = mock.patch.dict("os.environ", {"XDG_STATE_HOME": self.tmp.name})
        p.start()
        self.addCleanup(p.stop)

    def test_prep_runs_cli_with_yes_and_notifies(self):
        done = mock.Mock(returncode=0, stdout="Available: 9.4 GB -> 25.1 GB (target 24.0 GB)\n",
                         stderr="")
        with mock.patch("subprocess.run", return_value=done) as run, \
                mock.patch.object(menubar, "notify") as notify:
            self.assertEqual(menubar.do_action("prep", ["build"]), 0)
        args = run.call_args[0][0]
        self.assertEqual(args[1:], ["-m", "headroom", "prep", "--yes", "--profile", "build"])
        notify.assert_called_once()
        self.assertIn("25.1 GB", notify.call_args[0][1])

    def test_lock_prevents_concurrent_runs(self):
        import fcntl
        path = menubar._lock_path()
        path.parent.mkdir(parents=True, exist_ok=True)
        with open(path, "w") as held:
            fcntl.flock(held, fcntl.LOCK_EX)
            self.assertTrue(menubar._busy())
            with mock.patch("subprocess.run") as run, mock.patch.object(menubar, "notify"):
                self.assertEqual(menubar.do_action("restore", []), 1)
            run.assert_not_called()
        self.assertFalse(menubar._busy())

    def test_install_and_uninstall(self):
        d = Path(self.tmp.name) / "plugins"
        with redirect_stdout(io.StringIO()):
            self.assertEqual(menubar.install(d), 0)
            stub = d / menubar.STUB_NAME
            text = stub.read_text()
            self.assertTrue(text.startswith("#!/bin/bash"))
            self.assertIn("-m headroom.menubar", text)
            self.assertIn("/opt/homebrew/bin", text)  # GUI apps get a minimal PATH
            self.assertTrue(stub.stat().st_mode & 0o100)
            self.assertEqual(menubar.uninstall(d), 0)
        self.assertFalse(stub.exists())

    def test_summary(self):
        self.assertEqual(menubar._summary("x\nRestored.\n"), "Restored.")
        self.assertEqual(menubar._summary("just this\n"), "just this")
        self.assertEqual(menubar._summary(""), "Done.")


if __name__ == "__main__":
    unittest.main()
