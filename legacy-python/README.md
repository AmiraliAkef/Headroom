# Headroom

Free real, usable RAM on an Apple Silicon Mac before a heavy task (a local LLM, a big
build, a video export), and put things back afterwards.

Headroom is **not** a "RAM cleaner". It never kills system processes, never runs
`purge`, and never needs `sudo`. It only quits apps *you* list, gracefully, and only
as many as it takes to reach your memory target.

## Install

Requires macOS and Python 3.11+. No third-party dependencies.

```sh
pipx install .          # from this directory
# or, without pipx:
python3 -m pip install --user .
# or run it in place:
python3 -m headroom status
```

## Usage

```sh
headroom status              # memory, pressure, what prep could free. Changes nothing.
headroom status --json       # same, for scripts

headroom prep --dry-run      # show the plan only
headroom prep                # quit things until the target is reached (asks first)
headroom prep --profile build --target-gb 16 --yes

headroom restore             # reopen what prep quit, restart Docker
headroom config              # print config path (creates it from the example if missing)

headroom prep --then "ollama run qwen3.6:35b-a3b"   # prep, run the task, restore after
headroom menubar --install   # add the SwiftBar/xbar menu-bar plugin
```

### `--then`: prep, run, restore

`headroom prep --then "<command>"` preps, runs the command through your shell,
and runs `restore` when the command exits. It still restores if the command fails or
you press Ctrl-C: the command gets the interrupt and Headroom waits for it to exit
before restoring. Headroom exits with the command's exit code.

- If the target is already met, the command runs and nothing is restored, so an
  earlier session is left alone.
- If the target can't be reached, the command still runs, with a warning.
- With `--dry-run`, it shows the plan and the command, and runs neither.
- If you decline the confirmation, the command doesn't run (exit 1).

### Menu bar (SwiftBar / xbar)

```sh
brew install --cask swiftbar     # or xbar; pick a plugin folder on first launch
headroom menubar --install       # writes headroom.30s.sh into that folder
headroom menubar --uninstall
headroom menubar --install --dir ~/some/plugins   # explicit folder
```

The menu bar shows estimated available RAM, colored orange or red under warning or
critical pressure. The dropdown lists pressure, swap, what's on the quit list and
how much it uses, and has these actions:

- **Prep** for the default profile, plus a submenu for the other profiles. This runs
  `prep --yes` in the background and sends a notification with the result.
- **Show prep plan in Terminal…**, which runs a dry run.
- **Restore**, shown while a session is active. It lists what it will reopen.
- **Edit config…**

Only one prep or restore from the menu bar runs at a time. The plugin is a small
stub that calls the installed `headroom` package, so it uses the same quit list
and protected list. Re-run `--install` after moving or reinstalling Headroom.
On the first prep, macOS asks to let SwiftBar control the apps it quits
(Automation permission).

### What `prep` does

1. Reads memory. If estimated available RAM already meets the target, it stops.
2. Builds candidates: running apps on the profile's `quit_apps`, loaded Ollama /
   LM Studio models (`unload_models`), and Docker Desktop (`stop_docker`).
3. Sorts them by memory, largest first, shows the plan, and asks for confirmation
   (skip with `--yes`).
4. Quits one at a time with `osascript ... to quit`, waits, re-reads real memory
   stats, and **stops as soon as the target is reached**.
5. Records what it did in `~/.local/state/headroom/session.json`, so `restore` can
   reopen exactly those apps. Running `prep` again merges into the same session.

An app that doesn't quit within 15 s is skipped and reported (it may be showing a
"save changes?" dialog). `--force` force-quits such apps, but only ones on the quit list.

Models are not reloaded by `restore`; load what you need.

### Exit codes

| code | meaning |
| --- | --- |
| 0 | success, or target already met |
| 1 | error (bad config, not macOS, restore failure) |
| 2 | target not reached after quitting everything allowed |
| *n* | with `--then`: the command's own exit code |

## Config

`~/.config/headroom/config.toml` (respects `$XDG_CONFIG_HOME`). Without a file,
a built-in `llm` profile is used, with its target scaled to your RAM.
`headroom config` creates the file from the example. Any target too large for
your Mac is scaled down, with a comment saying so.

```toml
default_profile = "llm"

[profiles.llm]
target_gb = 24            # available RAM wanted before the heavy task
quit_apps = ["Google Chrome", "Slack", "Discord", "Spotify", "Notion", "Microsoft Teams"]
unload_models = true
stop_docker = true

[profiles.build]
target_gb = 12
quit_apps = ["Slack", "Discord", "Spotify"]
unload_models = true
stop_docker = false
```

App names are the bundle names in `/Applications` without `.app`.

Validation: unknown keys warn; `target_gb` must be positive and below total RAM;
listing a protected app is an error.

**Protected (never quit, under any flag):** Finder, WindowServer, Dock,
SystemUIServer, loginwindow, kernel_task, launchd, Terminal, iTerm2, Ghostty, Warp,
and whichever app is running Headroom itself (e.g. VS Code if you run it in its terminal).

## How memory is measured

macOS fills spare RAM with file cache and compressed memory on purpose, so low
"free" memory is normal. Headroom reports what matters, **memory pressure** and
**swap**, and estimates available RAM as:

```
(free + inactive + speculative + purgeable pages) × page size    # from vm_stat
```

This is an estimate. Per-app memory is the sum of RSS across the app's processes
(helpers included). RSS counts shared memory more than once, so the "could free"
figures are upper bounds. They are good enough for ranking, and prep re-measures
after every quit instead of trusting them.

## Development

```sh
python3 -m unittest discover -s tests -t .
```

Parsers are pure functions tested against captured output in `tests/fixtures/`;
every quit/open/unload call is mocked.
