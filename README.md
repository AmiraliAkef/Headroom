# Headroom

**Live CPU and RAM in your Mac's menu bar, and one click to free real memory before a heavy task.**

Headroom shows `CPU 12%  RAM 14.2/24 GB` in the menu bar. When you're about to run a local LLM,
a big build or a video export, **Prep** gracefully quits the apps you chose, unloads idle
Ollama / LM Studio models and stops Docker. It stops as soon as you have enough free memory.
**Restore** brings everything back.

<!-- Demo visual goes here -->

It is **not** a "RAM cleaner". It never kills system processes, never runs `purge` and never needs `sudo`.

## Features

- **Live stats in the menu bar.** CPU, RAM used and available memory, in three display styles.
  The label turns yellow or red under memory pressure. It uses a few syscalls per tick, with no `top` or `ps`.
- **Prep for heavy tasks.** Before doing anything, it shows exactly what it will quit and roughly how many GB that frees.
  It re-measures real memory after each step and stops at your target.
- **Restore.** Reopens everything Prep closed, all at once or a selection, without stealing focus.
- **Safe by design.** It only touches apps on your list. Finder, Dock, terminals and other system apps are protected.
  Terminal windows with running commands or Claude Code sessions are never closed.
- **CLI included.** `headroom` does the same from the terminal, including `prep --then "<command>"`.

## Requirements

- Apple Silicon Mac, macOS 14 Sonoma or later
- Swift 5.9+ (Xcode or the Command Line Tools)

## Install

```sh
git clone https://github.com/AmiraliAkef/Headroom.git
cd Headroom
./build.sh install
```

This builds `Headroom.app`, copies it to `/Applications`, links the `headroom` CLI and launches it.
Headroom then appears in the menu bar. It has no Dock icon.

| Command | What it does |
| --- | --- |
| `./build.sh` | Build `build/Headroom.app` only |
| `./build.sh install [-y]` | Build, install, link the CLI and launch (`-y` skips the prompt) |
| `./build.sh install-agent` | Start at login with a LaunchAgent instead of a Login Item |
| `./build.sh uninstall` | Remove the app, login item and CLI link (your config is kept) |

## Usage

**From the menu bar:** click the stats, then choose **Prep for Heavy Task ▸ *profile***.
Review the plan and confirm. When you're done, click **Restore Apps**.

**From the terminal:**

```sh
headroom status                      # CPU, memory, and what prep could free
headroom prep --dry-run              # show the plan, change nothing
headroom prep --profile llm          # free memory up to the profile's target
headroom prep --then "ollama run qwen3"   # prep, run the command, restore when it exits
headroom restore                     # reopen everything
headroom config add-app "Slack" --profile llm
```

## Configuration

Profiles live in `~/Library/Application Support/Headroom/config.json`, which is created on first run.
Open it from the menu with **Edit Profiles…**. Apps are listed by bundle id, and
`headroom config add-app NAME` looks the id up for you.

```json
{
  "defaultProfile": "llm",
  "profiles": {
    "llm": {
      "targetGB": 24,
      "quitApps": ["com.google.Chrome", "com.tinyspeck.slackmacgap", "com.spotify.client"],
      "unloadModels": true,
      "stopDocker": true
    }
  }
}
```

| Key | Meaning |
| --- | --- |
| `targetGB` | Available memory to aim for |
| `quitApps` | Apps Prep may quit, largest first, only as many as needed |
| `unloadModels` | Unload idle Ollama / LM Studio models |
| `stopDocker` | Stop Docker Desktop and its VM |
| `closeIdleClaude` | Also close idle Claude Code sessions. They're resumed on Restore (off by default) |

See [`config.example.json`](config.example.json) for a full example.

## How memory is measured

- **Used** matches Activity Monitor's "Memory Used".
- **Available** estimates what can be used without swapping: free, inactive, speculative and purgeable memory.
- **Per-app memory** is the physical footprint of the app and its helpers, the same figure Activity Monitor shows.

macOS fills spare RAM with cache on purpose, so low "free" memory is normal.
**Memory pressure** and **swap** are the signals that matter.

## Development

```sh
swift build
swift test
HEADROOM_SUPPORT_DIR=/tmp/hr .build/debug/headroom status   # use a scratch config
```

```
Sources/HeadroomCore   monitoring, config, session, PrepEngine (shared logic)
Sources/Headroom       AppKit menu bar app
Sources/headroom-cli   the `headroom` command
```

The tests never quit or open real apps. `PrepEngine` talks to the system through a protocol that the tests replace with a fake.
An earlier Python prototype is kept in `legacy-python/`.
