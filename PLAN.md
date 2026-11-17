# Headroom — live RAM/CPU menu bar stats + RAM prep for heavy tasks (macOS)

## Goal

One native macOS tool with two faces that share the same core code:

1. **Menu bar app**: always-on, very light, shows live CPU and RAM in the menu bar (e.g. `CPU 12%  RAM 14.2/24 GB`), starts at login, no Dock icon, and has **Prep** / **Restore** actions in its menu.
2. **Command-line tool** (`headroom`): the same status, prep and restore from the terminal, for scripts or for chaining with a heavy task.

**Prep** frees real, usable memory before a heavy task (running a local LLM, a big build, video export) by gracefully quitting apps the user has listed, unloading idle local models and stopping Docker, only as much as needed to hit a memory target. **Restore** puts everything back.

It is **not** a "RAM cleaner". It never kills system processes and never runs `purge`.

## Background the implementer needs

- macOS deliberately fills unused RAM with file cache and compressed memory and reclaims it on demand. Low "free" memory is normal and is **not** the signal to act on.
- The signals that matter are **memory pressure** and **swap usage**.
- System daemons are restarted by `launchd` if killed, and killing some (WindowServer, kernel_task, mds, etc.) breaks the system. So prep works only on user apps from an allowlist.
- The biggest real wins are usually: Docker Desktop's VM, browsers with many tabs, Electron apps (Slack, Discord, VS Code, Notion, Spotify), and idle local models still loaded in Ollama / LM Studio.

## Tech choices

- **Swift 5.9+**, Apple Silicon, **macOS 14 Sonoma or later**.
- **Swift Package Manager** with three targets:
  - `HeadroomCore` (library): all monitoring, app discovery, quitting/reopening, models, Docker, config, session state.
  - `Headroom` (executable → wrapped into `Headroom.app`): AppKit menu bar app.
  - `headroom` (executable): command-line tool.
- **AppKit `NSStatusItem`** for the menu bar (lighter and more controllable than SwiftUI `MenuBarExtra` for a constantly updating label).
- Only allowed dependency: Apple's `swift-argument-parser` for the CLI. Nothing else.
- System stats come from Mach/BSD APIs directly (`host_processor_info`, `host_statistics64`, `sysctlbyname`, `proc_pid_rusage`). **Never spawn `top`, `ps` or `vm_stat` in the live update loop.** Spawning external commands is allowed only during prep (for `ollama`, `lms`, `docker`).
- A `build.sh` script assembles a proper `.app` bundle and ad-hoc signs it, so everything builds from the terminal with no Xcode GUI.

## Project layout

```
headroom/
├── Package.swift
├── build.sh                         # build, bundle, sign, install/uninstall app + CLI
├── Resources/
│   └── Info.plist                   # LSUIElement, bundle id, version, min OS
├── Sources/
│   ├── HeadroomCore/
│   │   ├── CPUMonitor.swift         # CPU % from tick deltas
│   │   ├── MemoryMonitor.swift      # used/total/available, pressure, swap, compressed
│   │   ├── RunningApps.swift        # user apps + their memory, graceful quit, reopen
│   │   ├── ProtectedApps.swift      # hard-coded never-touch list
│   │   ├── LocalModels.swift        # Ollama / LM Studio list + unload
│   │   ├── Docker.swift             # detect, stop, restart Docker Desktop
│   │   ├── Config.swift             # profiles, load/validate/default
│   │   ├── Session.swift            # save/merge/load/clear restore state
│   │   └── PrepEngine.swift         # builds the prep plan, executes it, restore
│   ├── Headroom/                    # menu bar app
│   │   ├── main.swift
│   │   ├── AppDelegate.swift        # status item, timer, sleep/wake handling
│   │   ├── StatusItemController.swift  # menu bar text + dropdown menu
│   │   ├── PrepUI.swift             # confirmation alert, progress, result notification
│   │   ├── Settings.swift           # UserDefaults display preferences
│   │   └── LoginItem.swift          # SMAppService wrapper
│   └── headroom-cli/
│       └── main.swift               # status / prep / restore / config subcommands
├── Tests/HeadroomCoreTests/
│   ├── CPUMathTests.swift
│   ├── MemoryMathTests.swift
│   ├── ConfigTests.swift
│   ├── SessionTests.swift
│   ├── PrepPlanTests.swift          # plan ordering + stop-at-target logic, mocked apps
│   └── Fixtures/                    # captured `ollama ps`, `lms ps` output
├── config.example.json
└── README.md
```

## Core: reading the system (HeadroomCore)

### CPU (CPUMonitor.swift)
- `host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, ...)` gives per-core tick counts (user, system, idle, nice).
- Keep the previous sample. Usage = (Δuser + Δsystem + Δnice) / (Δuser + Δsystem + Δnice + Δidle) across all cores. Also expose user % and system % separately.
- Always `vm_deallocate` the array returned by `host_processor_info`, or the app leaks memory on every tick.
- First sample has no previous value: report `nil` (shown as `--`).
- Delta math is a pure function over two tick structs, for unit tests.

### Memory (MemoryMonitor.swift)
- Total: `ProcessInfo.processInfo.physicalMemory`.
- Pages: `host_statistics64(mach_host_self(), HOST_VM_INFO64, ...)` into `vm_statistics64`; page size `vm_kernel_page_size`.
- **Used** (matches Activity Monitor's "Memory Used"):
  `(internal_page_count − purgeable_count + wire_count + compressor_page_count) × page size`
- **Available estimate** (used by prep): `(free_count + inactive_count + speculative_count + purgeable_count) × page size`. Document it as an estimate.
- Compressed: `compressor_page_count × page size`.
- Swap: `sysctlbyname("vm.swapusage")` into `xsw_usage`.
- Pressure: `sysctlbyname("kern.memorystatus_vm_pressure_level")` → 1 normal, 2 warning, 4 critical.
- Formulas are pure functions over a stats struct, for unit tests.

### Running apps (RunningApps.swift)
- App list: `NSWorkspace.shared.runningApplications`, keeping only `activationPolicy == .regular` apps (real user apps).
- Memory per app: enumerate PIDs with `proc_listallpids`, get each path with `proc_pidpath`, attribute a process to an app when its path is inside that app's bundle (this folds helpers like "Google Chrome Helper (Renderer)" into Chrome). Sum `ri_phys_footprint` from `proc_pid_rusage(pid, RUSAGE_INFO_V4, ...)`, which is the same "Memory" figure Activity Monitor shows. Processes the tool can't read are skipped silently.
- **Quit gracefully**: `NSRunningApplication.terminate()`, then wait up to a timeout (default 15 s) for `isTerminated`. Apps that refuse (e.g. an unsaved-document prompt) are skipped and reported, never forced, unless the user passes `--force` in the CLI, and even then only for apps on the quit list (`forceTerminate()`).
- **Reopen**: `NSWorkspace.shared.openApplication(at: bundleURL, configuration:)`, with `activates = false` so restored apps don't steal focus.
- Apps are identified by **bundle identifier** everywhere (config, session), with the display name kept only for output.

### Protected list (ProtectedApps.swift)
Hard-coded and never overridable by config or flags: Finder, Dock, SystemUIServer, WindowServer, loginwindow, ControlCenter, Terminal, iTerm2, Ghostty, Warp, and Headroom itself. Config validation errors if any of these appear.

### Local models (LocalModels.swift)
- **Ollama**: if `ollama` is on PATH (also check `/opt/homebrew/bin` and `/usr/local/bin`, since apps launched at login don't inherit the shell's PATH), parse `ollama ps` for loaded models and sizes, unload with `ollama stop <model>`.
- **LM Studio**: if `lms` is found (also check `~/.lmstudio/bin`), parse `lms ps`, unload with `lms unload --all`.
- Parsers are pure functions tested against captured fixture output. Missing CLIs are skipped silently.

### Docker (Docker.swift)
- Detect Docker Desktop by bundle id `com.docker.docker` in running apps. Its memory = the app's processes plus the VM process (`com.apple.Virtualization.VirtualMachine` or the `qemu`/`vz` helper under the Docker bundle).
- Stop with `docker desktop stop` if the `docker` CLI is found, otherwise `terminate()` the app.
- Restore with `openApplication` on Docker's bundle URL.

## Core: prep and restore (PrepEngine.swift)

### Plan
1. Read memory. If available ≥ target, the plan is empty ("already have headroom").
2. Candidates = running apps on the active profile's quit list + loaded local models (if `unloadModels`) + Docker (if `stopDocker`).
3. Sort candidates by memory freed, largest first.
4. The plan lists each candidate with its estimated GB and a running total, marking where the target is expected to be reached.

### Execute
- Quit/unload one candidate at a time. After each, wait ~1 s and **re-read real memory stats**; stop as soon as available ≥ target.
- Report each step via a callback (used by the CLI for printed lines and by the app for a progress menu item).
- Record everything actually quit/stopped/unloaded into the session.
- Result: before/after available GB, items handled, items skipped (with reason), and whether the target was reached.

### Session (Session.swift)
Stored at `~/Library/Application Support/Headroom/session.json`, shared by the app and the CLI:

```json
{
  "createdAt": "ISO-8601 timestamp",
  "profile": "llm",
  "quitApps": [
    { "bundleId": "com.tinyspeck.slackmacgap", "name": "Slack", "bundleURL": "/Applications/Slack.app" }
  ],
  "dockerStopped": true,
  "unloadedModels": ["qwen3.6:35b-a3b"],
  "availableBeforeGB": 9.4,
  "availableAfterGB": 25.1
}
```

- If prep runs while a session exists, **merge** into it so one restore brings back everything.
- **Restore** reopens every recorded app, restarts Docker if it was stopped, then deletes the session. It does **not** reload models (the user loads what they need).
- Writes are atomic (write to temp file, then rename), so the app and CLI never see a half-written file.

### Config (Config.swift)
Stored at `~/Library/Application Support/Headroom/config.json`, created from defaults on first run:

```json
{
  "defaultProfile": "llm",
  "profiles": {
    "llm": {
      "targetGB": 24,
      "quitApps": ["com.google.Chrome", "com.tinyspeck.slackmacgap", "com.hnc.Discord",
                   "com.spotify.client", "notion.id", "com.microsoft.teams2"],
      "unloadModels": true,
      "stopDocker": true
    },
    "build": {
      "targetGB": 12,
      "quitApps": ["com.tinyspeck.slackmacgap", "com.hnc.Discord", "com.spotify.client"],
      "unloadModels": true,
      "stopDocker": false
    }
  }
}
```

Validation: unknown keys warn; protected apps error with the app name; `targetGB` must be positive and below total RAM; unknown `defaultProfile` errors. The CLI's `config` subcommand also has `add-app <name>` which resolves a running app's name to its bundle id, so the user never has to look bundle ids up by hand.

## Menu bar app (Headroom.app)

### Menu bar text
- Text-only status item using `NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)` so width doesn't jitter.
- Display modes (menu setting): Full `CPU 12%  RAM 14.2/24 GB`, Compact `12% · 14.2G`, Percent `CPU 12%  RAM 59%`.
- RAM part tinted `.systemYellow` at pressure warning and `.systemRed` at critical; normal label color otherwise (works in light and dark mode).
- A small `↺` suffix appears when a restore session exists, as a reminder that apps are waiting to be reopened.
- Only redraw when the rendered string or color actually changes.

### Dropdown menu

```
CPU            12%
  User          8%
  System        4%
Memory         14.2 / 24.0 GB
  Available    9.4 GB
  Pressure     Normal
  Compressed   1.8 GB
  Swap used    0.0 GB
──────────────────────
Prep for Heavy Task      ▸ LLM (24 GB) / Build (12 GB)
Restore Apps (4)            ← disabled when no session
Edit Profiles…              ← opens config.json in the default editor
──────────────────────
Display        ▸ Full / Compact / Percent
Refresh every  ▸ 1 s / 2 s / 5 s
✓ Launch at login
──────────────────────
Open Activity Monitor
Quit Headroom             ⌘Q
```

- Detail rows are disabled (informational) and refresh while the menu is open.
- **Prep flow**: choosing a profile builds the plan and shows an `NSAlert` listing what will be quit/unloaded/stopped with estimated GB and the expected result, with "Prep" and "Cancel" buttons. If the plan is empty, the alert just says there's already enough headroom.
- During prep, the Prep item is replaced by a disabled "Prepping… quitting Slack" line; prep runs off the main thread so the menu bar keeps updating. When done, post a `UserNotifications` notification: "Freed 15.7 GB — 25.1 GB available" (or that the target wasn't reached and why). Request notification permission the first time prep runs, not at launch.
- **Restore** runs immediately (no confirmation) and posts a notification listing what reopened.
- The app re-reads the session file each time the menu opens, so a prep or restore done from the CLI shows up correctly.
- "Open Activity Monitor" opens `/System/Applications/Utilities/Activity Monitor.app`.

### Update loop (keeping it light)
- One main-run-loop `Timer`, default 2 s, `tolerance` = 20% of the interval so macOS can coalesce wakeups.
- Live loop reads only CPU and memory (a few syscalls). Per-app memory scanning happens **only** when building a prep plan, never on the timer.
- Pause the timer on `NSWorkspace.screensDidSleepNotification` / `willSleepNotification`; resume on wake with a fresh baseline CPU sample.
- No disk logging, no network.
- **Budget**: under 0.5% average CPU and under 30 MB memory while idle in the menu bar.

### Settings (Settings.swift)
`UserDefaults`: `displayMode` (default full), `refreshInterval` (default 2). Launch-at-login state is read live from `SMAppService.mainApp.status`, never stored.

### Launch at login (LoginItem.swift)
- `SMAppService.mainApp.register()` / `.unregister()`; menu checkmark reflects `status == .enabled`.
- Register automatically on first launch.
- If status is `.requiresApproval` or registration throws, show "Allow in Login Items…" calling `SMAppService.openSystemSettingsLoginItems()`.
- Requires the app in `/Applications` (handled by `build.sh install`).
- **Fallback** if `SMAppService` is unreliable with ad-hoc signing: `build.sh install-agent` writes `~/Library/LaunchAgents/com.<user>.headroom.plist` with `RunAtLoad = true`, loaded via `launchctl bootstrap gui/$(id -u)`. README documents both.

### Info.plist essentials
`CFBundleIdentifier` `com.<user>.headroom`, `CFBundleName`/`CFBundleDisplayName` Headroom, `CFBundleExecutable` Headroom, `CFBundlePackageType` APPL, `LSUIElement` true, `LSMinimumSystemVersion` 14.0, version strings.

## Command-line tool (`headroom`)

- `headroom status [--json]`: CPU, memory (used, available, compressed, swap, pressure), quit-list apps running with their GB, loaded models, Docker, estimated reclaimable. Changes nothing.
- `headroom prep [--profile NAME] [--target-gb N] [--dry-run] [--yes] [--force]`: shows the plan, asks for confirmation unless `--yes`, executes with one printed line per step, prints before/after. `--dry-run` shows the plan and exits.
- `headroom prep ... --then "<command>"`: after prep, runs the command, and restores automatically when it exits (even if it fails). Exit code is the command's.
- `headroom restore`: reopens everything from the session. Says so and exits 0 if there's none.
- `headroom config [path | add-app NAME --profile P | validate]`.
- Exit codes: 0 success or target already met, 1 error, 2 target not reached after everything allowed was handled.
- `build.sh install` symlinks the CLI to `/opt/homebrew/bin/headroom` (or `/usr/local/bin` if that's where Homebrew lives), asking before writing outside the project.

## build.sh

- `./build.sh` → `swift build -c release --arch arm64`, assemble `Headroom.app/Contents/{MacOS,Resources}`, copy binary and `Info.plist`, `codesign --force --sign - Headroom.app`.
- `./build.sh install` → build, quit a running Headroom, copy to `/Applications/Headroom.app`, symlink the CLI, launch the app.
- `./build.sh install-agent` → LaunchAgent fallback for start at login.
- `./build.sh uninstall` → quit the app, unregister the login item (launch with `--unregister`) or remove the LaunchAgent, delete the app and CLI symlink. Leaves config and session in Application Support and prints their path.
- `set -euo pipefail`, prints each step.

## Phases

1. **Core monitoring + menu bar**: `CPUMonitor`, `MemoryMonitor`, status item with live text, basic menu with detail rows and Quit, `LSUIElement`, `build.sh` (build + install). Unit tests for CPU and memory math.
2. **CLI read-only**: `headroom status` (+ `--json`), `RunningApps` memory scanning, `LocalModels` and `Docker` detection, `Config` loading/validation with defaults. Nothing is quit yet.
3. **Prep and restore**: `PrepEngine`, `Session`, graceful quit/reopen, models, Docker, CLI `prep`/`restore`/`--dry-run`, then the menu's Prep/Restore items, confirmation alert, progress line, notifications, `↺` indicator. Plan-ordering and stop-at-target tests with mocked apps.
4. **Native feel and polish**: launch at login, sleep/wake pausing, display modes, refresh interval, pressure colors, `--then`, `config add-app`, `install-agent`/`uninstall`, README.
5. **Optional later**: GPU usage via IOKit `IOAccelerator` statistics, network speed, a small sparkline in the dropdown, a global keyboard shortcut for prep, auto-suggest prep when pressure turns red.

## Acceptance criteria

- After `./build.sh install`, Headroom appears in the menu bar with no Dock icon or window, and `headroom status` works in the terminal.
- CPU % roughly matches Activity Monitor's total (user + system); RAM used is within ~0.5 GB of Activity Monitor's "Memory Used".
- Over 10 minutes idle: average CPU under 0.5%, memory under 30 MB and not growing.
- After reboot and login, Headroom starts on its own; unchecking Launch at login stops that.
- `prep --dry-run` and the alert's Cancel never quit anything.
- Prep never touches an app outside the active profile's quit list, never touches the protected list under any flag, and stops once the target is reached.
- Restore reopens exactly the apps prep quit, without stealing focus, whether prep ran from the menu or the CLI.
- An app with unsaved changes that refuses to quit is skipped and reported, not forced (unless `--force` in the CLI).
- Menu bar width stays stable; works in light/dark mode and on any display.

## Out of scope

- Killing system processes or daemons.
- `sudo purge` or anything needing sudo.
- Changing `iogpu.wired_limit_mb` (possible separate opt-in feature later).
- Per-process management beyond the quit list (that's Activity Monitor's job).
- Mac App Store distribution, notarization, sandboxing (the app needs to quit other apps and read their memory, which a sandbox would block).
- Intel Macs and macOS versions before 14.
