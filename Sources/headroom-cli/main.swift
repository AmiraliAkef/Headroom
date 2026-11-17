import ArgumentParser
import Darwin
import Foundation
import HeadroomCore

// Exit codes: 0 success / target already met, 1 error, 2 target not reached.
let targetNotReached = ExitCode(2)

func warn(_ message: String) {
    FileHandle.standardError.write(Data("headroom: \(message)\n".utf8))
}

func readMemoryOrFail() throws -> MemorySnapshot {
    guard let m = MemoryMonitor.snapshot() else {
        warn("can't read memory statistics")
        throw ExitCode.failure
    }
    return m
}

func loadConfigOrFail(totalGB: Double) throws -> Config {
    do {
        let cfg = try ConfigLoader.load(totalGB: totalGB)
        cfg.warnings.forEach { warn("warning: \($0)") }
        return cfg
    } catch {
        warn("config error: \(error.localizedDescription)")
        throw ExitCode.failure
    }
}

func pad(_ s: String, _ width: Int) -> String {
    s.count >= width ? s : s + String(repeating: " ", count: width - s.count)
}

func lpad(_ s: String, _ width: Int) -> String {
    s.count >= width ? s : String(repeating: " ", count: width - s.count) + s
}

struct HeadroomCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "headroom",
        abstract: "Free usable RAM on macOS before a heavy task, and put things back after.",
        version: Headroom.version,
        subcommands: [Status.self, Prep.self, Restore.self, ConfigCommand.self])
}

// MARK: - status

struct Status: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show CPU, memory and what prep could free. Changes nothing.")

    @Flag(help: "Machine-readable output.") var json = false
    @Option(help: "Profile to evaluate (default: the config's default).") var profile: String?

    struct JSONOutput: Encodable {
        struct CPU: Encodable { var total: Double; var user: Double; var system: Double }
        var cpu: CPU?
        var status: StatusReport
    }

    func run() throws {
        let cpuMon = CPUMonitor()
        _ = cpuMon.sample()
        let mem = try readMemoryOrFail()
        let cfg = try loadConfigOrFail(totalGB: mem.totalGB)
        let prof: Profile
        do { prof = try cfg.profile(profile) } catch {
            warn(error.localizedDescription)
            throw ExitCode.failure
        }
        // Scanning apps and models takes a moment, which doubles as the CPU sample window.
        let start = Date()
        guard let report = PrepEngine().status(profile: prof) else {
            warn("can't read memory statistics")
            throw ExitCode.failure
        }
        let elapsed = Date().timeIntervalSince(start)
        if elapsed < 0.5 { Thread.sleep(forTimeInterval: 0.5 - elapsed) }
        let cpu = cpuMon.sample()

        if json {
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            enc.dateEncodingStrategy = .iso8601
            let out = JSONOutput(cpu: cpu.map { .init(total: round1($0.total * 100), user: round1($0.user * 100),
                                                      system: round1($0.system * 100)) },
                                 status: report)
            print(String(decoding: try enc.encode(out), as: UTF8.self))
            return
        }

        let m = report.memory
        if let cpu {
            print(String(format: "CPU:              %.0f%% (user %.0f%%, system %.0f%%)",
                         cpu.total * 100, cpu.user * 100, cpu.system * 100))
        } else {
            print("CPU:              --")
        }
        print("Memory used:      \(Format.gb(m.used)) of \(Format.gb(m.total))")
        print("Available (est.): \(Format.gb(m.available))")
        print("Compressed:       \(Format.gb(m.compressed))")
        print("Swap used:        \(Format.gb(m.swapUsed))")
        print("Memory pressure:  \(m.pressure.label)")
        print()
        print("Quit list (profile '\(report.profile)', target \(Format.gb(report.targetGB))\(report.targetMet ? ", met" : "")):")
        if report.apps.isEmpty { print("  none running") }
        for a in report.apps { print("  \(pad(a.name, 30)) \(lpad(Format.gb(a.bytes), 9))") }
        if let d = report.docker {
            let note = report.dockerStoppedByProfile ? "" : "  (not stopped by this profile)"
            print("\nDocker Desktop:   \(Format.gb(d.bytes))\(note)")
        }
        print("\nLoaded local models:")
        if report.models.isEmpty { print("  none") }
        for mo in report.models { print("  \(pad(mo.name, 30)) \(lpad(Format.gb(mo.bytes), 9))  [\(mo.runtime)]") }
        print("\nPrep could free up to ~\(Format.gb(report.reclaimableBytes)) (estimate; usually less).")
        if let s = report.session, s.restoreCount > 0 {
            print("A prep session is active: 'headroom restore' reopens \(s.restoreCount) item(s).")
        }
    }
}

func round1(_ x: Double) -> Double { (x * 10).rounded() / 10 }

// MARK: - prep

struct Prep: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Quit listed apps, unload models and stop Docker until the memory target is reached.")

    @Option(help: "Profile name from the config.") var profile: String?
    @Option(name: .customLong("target-gb"), help: "Override the profile's target (GB available).")
    var targetGB: Double?
    @Flag(help: "Show the plan and change nothing.") var dryRun = false
    @Flag(name: [.long, .customShort("y")], help: "Don't ask for confirmation.") var yes = false
    @Flag(help: "Force-quit quit-list apps that don't quit in time.") var force = false
    @Option(name: .customLong("then"), help: "Run this shell command after prep, then restore when it exits.")
    var thenCommand: String?

    func run() throws {
        let mem = try readMemoryOrFail()
        let cfg = try loadConfigOrFail(totalGB: mem.totalGB)
        let engine = PrepEngine()
        let plan: PrepPlan
        do { plan = try engine.plan(profile: cfg.profile(profile), targetGB: targetGB) } catch {
            warn(error.localizedDescription)
            throw ExitCode.failure
        }

        print("Profile '\(plan.profile.name)': target \(Format.gb(plan.targetGB)) available, currently "
              + "\(Format.gb(plan.before.available)) (pressure: \(plan.before.pressure.label)).")

        var code: Int32 = 0
        var changed = false
        if plan.alreadyMet {
            print("Already have enough headroom. Nothing to do.")
        } else if plan.items.isEmpty {
            print("Nothing on this profile's list is running.")
            code = 2
        } else {
            printPlan(plan)
            if dryRun {
                print("\nDry run: nothing changed.")
                if let thenCommand { print("Would then run: \(thenCommand)") }
                return
            }
            if !yes {
                print("\nProceed? [y/N] ", terminator: "")
                fflush(stdout)
                let answer = readLine()?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
                guard answer == "y" || answer == "yes" else {
                    print("Aborted.")
                    if thenCommand != nil {
                        warn("not running the command")
                        throw ExitCode.failure
                    }
                    return
                }
            }
            print()
            let result = engine.execute(plan, force: force) { event in
                switch event {
                case .started(let c):
                    print("  \(c.verb) \(c.name)… ", terminator: "")
                    fflush(stdout)
                case .finished(_, let now):
                    print("done (available now \(Format.gb(now)))")
                case .skipped(_, let reason):
                    print("skipped: \(reason)")
                }
            }
            changed = !result.handled.isEmpty
            print("\nAvailable: \(Format.gb(result.availableBefore)) → \(Format.gb(result.availableAfter)) "
                  + "(target \(Format.gb(plan.targetGB)))")
            if !result.skipped.isEmpty {
                let names = result.skipped.map(\.candidate.name).joined(separator: ", ")
                print("Skipped: \(names)\(force ? "" : " (use --force to force-quit apps on the quit list)")")
            }
            if changed && thenCommand == nil { print("Run 'headroom restore' afterwards to reopen what was quit.") }
            if !result.targetReached {
                print("Target not reached after everything allowed was handled.")
                code = 2
            }
        }

        if let thenCommand {
            if dryRun {
                print("Would then run: \(thenCommand)")
                if code != 0 { throw ExitCode(code) }
                return
            }
            if code == 2 { print("Running the command anyway.") }
            throw ExitCode(runThen(thenCommand, restoreAfter: changed, engine: engine))
        }
        if code != 0 { throw ExitCode(code) }
    }

    func printPlan(_ plan: PrepPlan) {
        print("\nNeed ~\(Format.gb(plan.neededBytes)) more. Plan (largest first, stops once the target is reached):")
        for item in plan.items {
            let c = item.candidate
            let mark = item.reachesTarget ? "  ← target expected here" : ""
            print("  \(pad(c.verb, 7)) \(pad(c.name, 34)) ~\(lpad(Format.gb(c.estimatedBytes), 8))"
                  + "   total ~\(lpad(Format.gb(item.cumulativeBytes), 8))\(mark)")
        }
        if !plan.expectedToReachTarget { print("  Note: even all of this may not reach the target.") }
    }
}

/// Run the heavy task, then restore what prep quit however it ends. Returns its exit code.
func runThen(_ command: String, restoreAfter: Bool, engine: PrepEngine) -> Int32 {
    print("\n$ \(command)")
    fflush(stdout)
    // The child gets Ctrl-C from the terminal; we keep running so we can restore.
    // (A handler, not SIG_IGN, because ignored signals are inherited across exec.)
    signal(SIGINT) { _ in }
    defer { signal(SIGINT, SIG_DFL) }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sh")
    p.arguments = ["-c", command]
    var rc: Int32 = 1
    do {
        try p.run()
        p.waitUntilExit()
        rc = p.terminationReason == .uncaughtSignal ? 128 + p.terminationStatus : p.terminationStatus
    } catch {
        warn("could not run command: \(error.localizedDescription)")
    }
    if restoreAfter {
        print("\nCommand exited with \(rc). Restoring…")
        _ = doRestore(engine)
    } else {
        print("\nCommand exited with \(rc). Nothing was quit, nothing to restore.")
    }
    return rc
}

// MARK: - restore

@discardableResult
func doRestore(_ engine: PrepEngine, only: Set<RestoreItem>? = nil) -> Bool {
    guard let r = engine.restore(only: only, progress: { print("  \($0)") }) else {
        print("No session to restore.")
        return true
    }
    if !r.modelsNotReloaded.isEmpty {
        print("  Models not reloaded (load what you need): \(r.modelsNotReloaded.joined(separator: ", "))")
    }
    if !r.ok {
        print("Some items failed; they were kept in the session for another 'headroom restore'.")
    } else if let left = SessionStore().load(), left.restoreCount > 0 {
        print("Restored. Still in the list: "
              + left.restoreItems.map(\.label).joined(separator: ", ") + ".")
    } else {
        print("Restored.")
    }
    return r.ok
}

struct Restore: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Reopen what the last prep quit: everything, or just the items named.",
        discussion: """
            Examples:
              headroom restore --list          show what can be restored
              headroom restore Slack Docker    reopen just those; the rest stay listed
              headroom restore --forget        drop the list without reopening anything
            """)

    @Argument(help: "Apps (name or bundle id), 'docker', or Claude sessions (name or folder). Default: all.")
    var items: [String] = []
    @Flag(help: "List what can be restored and change nothing.") var list = false
    @Flag(help: "Forget the session without reopening anything.") var forget = false

    func run() throws {
        let engine = PrepEngine()
        if forget {
            engine.forget()
            print("Forgot the restore list; nothing was reopened.")
            return
        }
        guard let session = SessionStore().load() else {
            print("No session to restore.")
            return
        }
        let all = session.restoreItems
        if list {
            for ri in all {
                print("  \(ri.label)" + (ri.wasInForeground ? "" : "  (had no window open; reopens hidden)"))
            }
            if all.isEmpty { print("  Nothing to reopen.") }
            return
        }
        var only: Set<RestoreItem>?
        if !items.isEmpty {
            var picked = Set<RestoreItem>()
            for q in items {
                let hits = all.filter { $0.matches(q) }
                if hits.isEmpty {
                    warn("'\(q)' isn't in the restore list (see 'headroom restore --list')")
                    throw ExitCode.failure
                }
                picked.formUnion(hits)
            }
            only = picked
        }
        if !doRestore(engine, only: only) { throw ExitCode.failure }
    }
}

// MARK: - config

struct ConfigCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "config",
        abstract: "Show, edit or validate the config.",
        subcommands: [Path.self, AddApp.self, Validate.self],
        defaultSubcommand: Path.self)

    struct Path: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Print the config path, creating it from defaults if missing.")

        func run() throws {
            let mem = try readMemoryOrFail()
            do {
                if try ConfigLoader.ensureExists(totalGB: mem.totalGB) {
                    warn("created \(Paths.config.path) with default profiles")
                }
            } catch {
                warn(error.localizedDescription)
                throw ExitCode.failure
            }
            print(Paths.config.path)
        }
    }

    struct AddApp: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "add-app",
            abstract: "Add an app to a profile's quit list by name (resolved to its bundle id).")

        @Argument(help: "App name as shown in the Dock or Activity Monitor, or a bundle id.") var name: String
        @Option(help: "Profile to add it to (default: the config's default).") var profile: String?

        func run() throws {
            let mem = try readMemoryOrFail()
            let cfg = try loadConfigOrFail(totalGB: mem.totalGB)
            guard let app = RunningApps.resolve(name) else {
                warn("no app named '\(name)' is running or installed in /Applications")
                throw ExitCode.failure
            }
            let target = profile ?? cfg.defaultProfile
            do {
                if try ConfigLoader.addApp(app.bundleId, toProfile: target, totalGB: mem.totalGB) {
                    print("Added \(app.name) (\(app.bundleId)) to profile '\(target)'.")
                } else {
                    print("\(app.name) (\(app.bundleId)) is already in profile '\(target)'.")
                }
            } catch {
                warn(error.localizedDescription)
                throw ExitCode.failure
            }
        }
    }

    struct Validate: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Check the config for errors.")

        func run() throws {
            let mem = try readMemoryOrFail()
            let cfg = try loadConfigOrFail(totalGB: mem.totalGB)
            for p in cfg.orderedProfiles {
                let def = p.name == cfg.defaultProfile ? " (default)" : ""
                print("\(p.name)\(def): target \(Format.gb(p.targetGB)), \(p.quitApps.count) app(s), "
                      + "models \(p.unloadModels ? "unloaded" : "kept"), Docker \(p.stopDocker ? "stopped" : "kept")")
            }
            print(cfg.warnings.isEmpty ? "Config OK." : "Config OK, with \(cfg.warnings.count) warning(s).")
        }
    }
}

HeadroomCLI.main()
