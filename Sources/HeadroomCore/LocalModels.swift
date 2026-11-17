import Foundation

public struct LoadedModel: Codable, Equatable, Sendable {
    public enum Runtime: String, Codable, Sendable { case ollama, lmstudio }
    public var name: String
    public var sizeBytes: UInt64
    public var runtime: Runtime

    public init(name: String, sizeBytes: UInt64, runtime: Runtime) {
        self.name = name
        self.sizeBytes = sizeBytes
        self.runtime = runtime
    }
}

/// Runs external tools. Only used during prep/status, never in the live update loop.
public enum Shell {
    /// Apps launched at login don't inherit the shell's PATH, so also look here.
    public static var searchDirs: [String] {
        let env = ProcessInfo.processInfo.environment["PATH"]?.split(separator: ":").map(String.init) ?? []
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var seen = Set<String>()
        return (env + ["/opt/homebrew/bin", "/usr/local/bin", home + "/.lmstudio/bin",
                       "/Applications/Docker.app/Contents/Resources/bin", "/usr/bin", "/bin"])
            .filter { seen.insert($0).inserted }
    }

    public static func which(_ tool: String) -> String? {
        searchDirs.map { "\($0)/\(tool)" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    public struct Result: Sendable {
        public var status: Int32
        public var stdout: String
        public var stderr: String
    }

    /// Run a tool with a timeout. Returns nil if it can't be launched or times out.
    public static func run(_ executable: String, _ args: [String], timeout: TimeInterval = 30)
        -> Result?
    {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = searchDirs.joined(separator: ":")
        p.environment = env
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        // Read concurrently so a chatty tool can't fill the pipe and block.
        var outData = Data(), errData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async { outData = out.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        group.enter()
        DispatchQueue.global().async { errData = err.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < deadline { usleep(50_000) }
        if p.isRunning {
            p.terminate()
            return nil
        }
        group.wait()
        return Result(status: p.terminationStatus,
                      stdout: String(decoding: outData, as: UTF8.self),
                      stderr: String(decoding: errData, as: UTF8.self))
    }
}

public enum ModelParsers {
    private static let units: [String: Double] = [
        "B": 1, "KB": 1e3, "MB": 1e6, "GB": 1e9, "TB": 1e12,
        "KIB": 1024, "MIB": 1_048_576, "GIB": 1_073_741_824, "TIB": 1_099_511_627_776,
    ]

    /// "23 GB", "4.68 GB", "84.11 MB", "512MiB" → bytes. 0 if there's no size.
    public static func parseSize(_ text: String) -> UInt64 {
        let pattern = #"([\d.]+)\s*([KMGT]?i?B)\b"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let numR = Range(m.range(at: 1), in: text), let unitR = Range(m.range(at: 2), in: text),
              let num = Double(text[numR]), let unit = units[text[unitR].uppercased()]
        else { return 0 }
        return UInt64(num * unit)
    }

    /// Fixed-width table: each column starts where its header word starts.
    static func table(_ text: String) -> [[String: String]] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard let header = lines.first else { return [] }
        var cols: [(name: String, start: Int)] = []
        var i = 0
        let chars = Array(header)
        while i < chars.count {
            if chars[i] != " " {
                let start = i
                while i < chars.count, chars[i] != " " { i += 1 }
                cols.append((String(chars[start..<i]).uppercased(), start))
            } else { i += 1 }
        }
        return lines.dropFirst().map { line in
            let lc = Array(line)
            var row: [String: String] = [:]
            for (k, col) in cols.enumerated() {
                let end = k + 1 < cols.count ? cols[k + 1].start : lc.count
                let s = min(col.start, lc.count), e = min(max(end, s), lc.count)
                row[col.name] = String(lc[s..<e]).trimmingCharacters(in: .whitespaces)
            }
            return row
        }
    }

    /// `ollama ps`: NAME  ID  SIZE  PROCESSOR  CONTEXT  UNTIL
    public static func ollamaPS(_ text: String) -> [LoadedModel] {
        let first = text.split(separator: "\n").first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard let first, first.trimmingCharacters(in: .whitespaces).uppercased().hasPrefix("NAME")
        else { return [] }
        return table(text).compactMap { row in
            guard let name = row["NAME"], !name.isEmpty else { return nil }
            return LoadedModel(name: name, sizeBytes: parseSize(row["SIZE"] ?? ""), runtime: .ollama)
        }
    }

    /// `lms ps`: either a table (IDENTIFIER ... SIZE) or "Identifier: x" / "• Size: y" blocks.
    public static func lmsPS(_ text: String) -> [LoadedModel] {
        let lines = text.split(separator: "\n").map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard let header = lines.first, !text.lowercased().contains("no models") else { return [] }
        if header.uppercased().contains("IDENTIFIER"), header.uppercased().contains("SIZE") {
            return table(text).compactMap { row in
                guard let id = row["IDENTIFIER"], !id.isEmpty else { return nil }
                return LoadedModel(name: id, sizeBytes: parseSize(row["SIZE"] ?? ""), runtime: .lmstudio)
            }
        }
        var models: [LoadedModel] = []
        for line in lines {
            let s = line.trimmingCharacters(in: CharacterSet(charactersIn: " \t•-*"))
            let lower = s.lowercased()
            if lower.hasPrefix("identifier:") {
                let name = s.dropFirst("identifier:".count).trimmingCharacters(in: .whitespaces)
                models.append(LoadedModel(name: name, sizeBytes: 0, runtime: .lmstudio))
            } else if lower.hasPrefix("size:"), !models.isEmpty {
                models[models.count - 1].sizeBytes = parseSize(s)
            }
        }
        return models
    }
}

public enum LocalModels {
    /// Loaded models from every runtime that's installed. Missing CLIs or servers are skipped.
    public static func loaded() -> [LoadedModel] {
        var models: [LoadedModel] = []
        if let ollama = Shell.which("ollama"), let r = Shell.run(ollama, ["ps"], timeout: 10),
           r.status == 0 {
            models += ModelParsers.ollamaPS(r.stdout)
        }
        if let lms = Shell.which("lms"), let r = Shell.run(lms, ["ps"], timeout: 10), r.status == 0 {
            models += ModelParsers.lmsPS(r.stdout)
        }
        return models
    }

    public static func unloadOllama(_ name: String) -> Bool {
        guard let ollama = Shell.which("ollama") else { return false }
        return Shell.run(ollama, ["stop", name])?.status == 0
    }

    public static func unloadAllLMStudio() -> Bool {
        guard let lms = Shell.which("lms") else { return false }
        return Shell.run(lms, ["unload", "--all"])?.status == 0
    }
}
