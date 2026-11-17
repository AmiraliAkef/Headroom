import Foundation

public enum DisplayMode: String, CaseIterable, Sendable {
    case full, compact, percent

    public var label: String {
        switch self {
        case .full: return "Full"
        case .compact: return "Compact"
        case .percent: return "Percent"
        }
    }
}

/// The menu bar label, split so the app can tint only the RAM parts.
public struct MenuBarText: Equatable, Sendable {
    public var cpu: String
    public var separator: String
    public var ram: String
    /// Optional available-RAM segment, including its leading separator ("" when hidden).
    public var available: String = ""
    public var suffix: String

    public var string: String { cpu + separator + ram + available + suffix }

    /// U+2007 FIGURE SPACE is as wide as a digit in a monospaced-digit font, so
    /// padding with it keeps the label width from jittering as values change.
    static let figureSpace = "\u{2007}"

    static func pad(_ s: String, to width: Int) -> String {
        s.count >= width ? s : String(repeating: figureSpace, count: width - s.count) + s
    }

    public static func render(cpu: CPUUsage?, memory: MemorySnapshot?, mode: DisplayMode,
                              restorePending: Bool, showAvailable: Bool = false) -> MenuBarText {
        var text = renderBase(cpu: cpu, memory: memory, mode: mode, restorePending: restorePending)
        if showAvailable { text.available = availableSegment(memory: memory, mode: mode) }
        return text
    }

    /// The available-RAM segment, styled to match each mode:
    /// Full ` Avail 9.8 GB`, Compact ` · 9.8G free`, Percent `  Avail 41%`.
    static func availableSegment(memory: MemorySnapshot?, mode: DisplayMode) -> String {
        guard let m = memory else {
            switch mode {
            case .full: return "  Avail --"
            case .compact: return " · -- free"
            case .percent: return "  Avail --%"
            }
        }
        let width = String(format: "%.1f", m.totalGB).count
        let avail = pad(String(format: "%.1f", m.availableGB), to: width)
        switch mode {
        case .full: return "  Avail \(avail) GB"
        case .compact: return " · \(avail)G free"
        case .percent:
            let pct = m.total > 0 ? Int((Double(m.available) / Double(m.total) * 100).rounded()) : 0
            return "  Avail \(pad(String(pct), to: 3))%"
        }
    }

    static func renderBase(cpu: CPUUsage?, memory: MemorySnapshot?, mode: DisplayMode,
                           restorePending: Bool) -> MenuBarText {
        let cpuPct = cpu.map { String(Int(($0.total * 100).rounded())) } ?? "--"
        let cpuStr = pad(cpuPct, to: 3)
        let suffix = restorePending ? " ↺" : ""
        guard let m = memory else {
            switch mode {
            case .compact: return .init(cpu: "\(cpuStr)%", separator: " · ", ram: "--", suffix: suffix)
            default: return .init(cpu: "CPU \(cpuStr)%", separator: "  ", ram: "RAM --", suffix: suffix)
            }
        }
        let totalGB = m.totalGB
        let totalStr = abs(totalGB - totalGB.rounded()) < 0.05
            ? String(format: "%.0f", totalGB) : String(format: "%.1f", totalGB)
        let usedWidth = String(format: "%.1f", totalGB).count
        let used = pad(String(format: "%.1f", m.usedGB), to: usedWidth)
        switch mode {
        case .full:
            return .init(cpu: "CPU \(cpuStr)%", separator: "  ", ram: "RAM \(used)/\(totalStr) GB",
                         suffix: suffix)
        case .compact:
            return .init(cpu: "\(cpuStr)%", separator: " · ", ram: "\(used)G", suffix: suffix)
        case .percent:
            let pct = m.total > 0 ? Int((Double(m.used) / Double(m.total) * 100).rounded()) : 0
            return .init(cpu: "CPU \(cpuStr)%", separator: "  ", ram: "RAM \(pad(String(pct), to: 3))%",
                         suffix: suffix)
        }
    }
}
