import unittest
from unittest import mock

from headroom import apps, docker, models
from tests.helpers import fixture


class TestPs(unittest.TestCase):
    def test_parse_real_ps(self):
        procs = apps.parse_ps(fixture("ps.txt"))
        self.assertGreater(len(procs), 50)
        launchd = procs[0]
        self.assertEqual((launchd.pid, launchd.ppid, launchd.path), (1, 0, "/sbin/launchd"))
        # paths with spaces are kept whole
        self.assertTrue(any(p.path.endswith("/Claude Helper") for p in procs))

    def test_real_ps_groups_helpers(self):
        usage = apps.app_usage(apps.parse_ps(fixture("ps.txt")), ["Claude"])
        claude = usage["Claude"]
        self.assertGreater(len(claude.pids), 3)
        self.assertNotIn("Claude Helper", usage)

    def test_outermost_app(self):
        path = ("/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework"
                ".framework/Helpers/Google Chrome Helper (Renderer).app/Contents/MacOS/x")
        self.assertEqual(apps.outermost_app(path), "Google Chrome")
        self.assertIsNone(apps.outermost_app("/usr/libexec/logd"))

    def test_app_usage_sums_helpers(self):
        procs = apps.parse_ps(fixture("ps_apps.txt"))
        usage = apps.app_usage(procs, ["Google Chrome", "Slack", "Spotify", "Discord"])
        self.assertEqual(usage["Google Chrome"].rss_bytes,
                         (412000 + 180000 + 950000 + 620000) * 1024)
        self.assertEqual(len(usage["Google Chrome"].pids), 4)
        self.assertEqual(usage["Slack"].rss_bytes, (210000 + 340000) * 1024)
        self.assertNotIn("Discord", usage)

    def test_running_apps_sorted(self):
        procs = apps.parse_ps(fixture("ps_apps.txt"))
        names = [u.name for u in apps.running_apps(["Spotify", "Slack", "Google Chrome"], procs)]
        self.assertEqual(names, ["Google Chrome", "Slack", "Spotify"])

    def test_app_usage_without_names_groups_all(self):
        usage = apps.app_usage(apps.parse_ps(fixture("ps_apps.txt")))
        self.assertIn("Finder", usage)
        self.assertIn("Docker", usage)
        self.assertNotIn("Google Chrome Helper (GPU)", usage)

    def test_ancestor_apps(self):
        procs = apps.parse_ps(fixture("ps_apps.txt"))
        self.assertEqual(apps.ancestor_apps(procs, pid=5003), {"Terminal"})

    def test_protected(self):
        for name in ("Finder", "Dock", "Terminal", "iTerm2", "Ghostty", "Warp", "WindowServer"):
            self.assertTrue(apps.is_protected(name))
        self.assertTrue(apps.is_protected("Visual Studio Code", {"Visual Studio Code"}))
        self.assertFalse(apps.is_protected("Slack"))

    def test_quit_refuses_protected(self):
        with mock.patch("subprocess.run") as run:
            with self.assertRaises(ValueError):
                apps.quit_app("Finder")
            with self.assertRaises(ValueError):
                apps.quit_app("Code", self_apps={"Code"})
            run.assert_not_called()

    def test_quit_graceful(self):
        with mock.patch("subprocess.run") as run, \
                mock.patch.object(apps, "is_running", return_value=False):
            self.assertTrue(apps.quit_app('Odd "Name"'))
            args = run.call_args[0][0]
            self.assertEqual(args[:2], ["osascript", "-e"])
            self.assertEqual(args[2], 'tell application "Odd \\"Name\\"" to quit')

    def test_quit_timeout_no_force_never_kills(self):
        with mock.patch("subprocess.run"), \
                mock.patch.object(apps, "is_running", return_value=True), \
                mock.patch("os.kill") as kill, mock.patch("time.sleep"):
            self.assertFalse(apps.quit_app("Slack", timeout=0.01))
            kill.assert_not_called()

    def test_quit_force_kills_only_that_app(self):
        procs = apps.parse_ps(fixture("ps_apps.txt"))
        with mock.patch("subprocess.run"), \
                mock.patch.object(apps, "is_running", side_effect=[True] * 50 + [False]), \
                mock.patch.object(apps, "list_processes", return_value=procs), \
                mock.patch("os.kill") as kill, mock.patch("time.sleep"), \
                mock.patch("time.monotonic", side_effect=[0, 0, 100]):
            apps.quit_app("Slack", timeout=1, force=True)
            self.assertEqual(sorted(c.args[0] for c in kill.call_args_list), [3001, 3002])

    def test_open_app(self):
        with mock.patch("subprocess.run", return_value=mock.Mock(returncode=0)) as run:
            self.assertTrue(apps.open_app("Slack"))
            run.assert_called_once_with(["open", "-a", "Slack"], capture_output=True, text=True)


class TestDocker(unittest.TestCase):
    def test_usage_includes_vm(self):
        du = docker.usage(apps.parse_ps(fixture("ps_apps.txt")))
        self.assertEqual(du.rss_bytes, (300000 + 90000 + 4000000) * 1024)
        self.assertNotIn(554, du.pids)  # vmnetd is a privileged helper, not the VM

    def test_not_running(self):
        self.assertIsNone(docker.usage(apps.parse_ps(fixture("ps.txt"))))


class TestModels(unittest.TestCase):
    def test_ollama_ps(self):
        ms = models.parse_ollama_ps(fixture("ollama_ps.txt"))
        self.assertEqual([m.name for m in ms], ["qwen3.6:35b-a3b", "llama3.2:3b"])
        self.assertEqual(ms[0].size_bytes, 23 * 1000**3)
        self.assertEqual(ms[1].size_bytes, int(3.4 * 1000**3))
        self.assertEqual(ms[0].runtime, "ollama")

    def test_ollama_empty_and_error(self):
        self.assertEqual(models.parse_ollama_ps(fixture("ollama_ps_empty.txt")), [])
        self.assertEqual(models.parse_ollama_ps(
            "Error: could not connect to ollama server, run 'ollama serve' to start it"), [])

    def test_lms_ps_list(self):
        ms = models.parse_lms_ps(fixture("lms_ps.txt"))
        self.assertEqual([m.name for m in ms],
                         ["qwen2.5-7b-instruct", "text-embedding-nomic-embed-text-v1.5"])
        self.assertEqual(ms[0].size_bytes, int(4.68 * 1000**3))
        self.assertEqual(ms[1].size_bytes, int(84.11 * 1000**2))

    def test_lms_ps_table(self):
        ms = models.parse_lms_ps(fixture("lms_ps_table.txt"))
        self.assertEqual([(m.name, m.size_bytes) for m in ms],
                         [("qwen2.5-7b-instruct", int(4.68 * 1000**3))])

    def test_lms_none(self):
        self.assertEqual(models.parse_lms_ps("No models are currently loaded\n"), [])

    def test_missing_clis_skipped(self):
        with mock.patch("shutil.which", return_value=None), mock.patch("subprocess.run") as run:
            self.assertEqual(models.loaded_models(), [])
            run.assert_not_called()


if __name__ == "__main__":
    unittest.main()
