import Darwin
import Foundation

public let bytesPerGB: Double = 1_073_741_824

public enum MemoryPressure: String, Codable, Sendable {
    case normal, warning, critical, unknown

    /// `kern.memorystatus_vm_pressure_level`: 1 normal, 2 warning, 4 critical.
    public init(level: Int) {
        switch level {
        case 1: self = .normal
        case 2: self = .warning
        case 4: self = .critical
        default: self = .unknown
        }
    }

    public var label: String { rawValue.capitalized }
}

/// The page counts we use from `vm_statistics64`.
public struct VMCounts: Equatable, Sendable {
    public var pageSize: UInt64
    public var free: UInt64
    public var active: UInt64
    public var inactive: UInt64
    public var speculative: UInt64
    public var wired: UInt64
    public var purgeable: UInt64
    public var compressor: UInt64  // pages occupied by the compressor
    public var `internal`: UInt64  // anonymous (app) pages
    public var external: UInt64  // file-backed pages

    public init(pageSize: UInt64, free: UInt64 = 0, active: UInt64 = 0, inactive: UInt64 = 0,
                speculative: UInt64 = 0, wired: UInt64 = 0, purgeable: UInt64 = 0,
                compressor: UInt64 = 0, internal: UInt64 = 0, external: UInt64 = 0) {
        self.pageSize = pageSize
        self.free = free
        self.active = active
        self.inactive = inactive
        self.speculative = speculative
        self.wired = wired
        self.purgeable = purgeable
        self.compressor = compressor
        self.internal = `internal`
        self.external = external
    }
}

public enum MemoryMath {
    /// Matches Activity Monitor's "Memory Used":
    /// (internal − purgeable + wired + compressor) × page size.
    public static func used(_ c: VMCounts) -> UInt64 {
        let app = c.internal > c.purgeable ? c.internal - c.purgeable : 0
        return (app + c.wired + c.compressor) * c.pageSize
    }

    /// Estimated memory available without swapping:
    /// (free + inactive + speculative + purgeable) × page size.
    ///
    /// This is an *estimate*. macOS can also reclaim other file cache and compress
    /// active memory, and some inactive pages are dirty and must be written out first.
    public static func available(_ c: VMCounts) -> UInt64 {
        (c.free + c.inactive + c.speculative + c.purgeable) * c.pageSize
    }

    public static func compressed(_ c: VMCounts) -> UInt64 {
        c.compressor * c.pageSize
    }
}

public struct MemorySnapshot: Codable, Equatable, Sendable {
    public var total: UInt64
    public var used: UInt64
    public var available: UInt64
    public var compressed: UInt64
    public var swapUsed: UInt64
    public var swapTotal: UInt64
    public var pressure: MemoryPressure

    public init(total: UInt64, used: UInt64, available: UInt64, compressed: UInt64,
                swapUsed: UInt64, swapTotal: UInt64, pressure: MemoryPressure) {
        self.total = total
        self.used = used
        self.available = available
        self.compressed = compressed
        self.swapUsed = swapUsed
        self.swapTotal = swapTotal
        self.pressure = pressure
    }

    public init(total: UInt64, counts: VMCounts, swapUsed: UInt64, swapTotal: UInt64,
                pressure: MemoryPressure) {
        self.init(total: total, used: MemoryMath.used(counts),
                  available: MemoryMath.available(counts),
                  compressed: MemoryMath.compressed(counts),
                  swapUsed: swapUsed, swapTotal: swapTotal, pressure: pressure)
    }

    public var totalGB: Double { Double(total) / bytesPerGB }
    public var usedGB: Double { Double(used) / bytesPerGB }
    public var availableGB: Double { Double(available) / bytesPerGB }
    public var compressedGB: Double { Double(compressed) / bytesPerGB }
    public var swapUsedGB: Double { Double(swapUsed) / bytesPerGB }
}

/// Reads memory stats with a handful of syscalls; cheap enough for a 1 s timer.
public enum MemoryMonitor {
    private static let host = mach_host_self()

    public static func snapshot() -> MemorySnapshot? {
        guard let counts = readCounts() else { return nil }
        let swap = readSwap()
        return MemorySnapshot(total: ProcessInfo.processInfo.physicalMemory, counts: counts,
                              swapUsed: swap.used, swapTotal: swap.total,
                              pressure: readPressure())
    }

    public static func readCounts() -> VMCounts? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        return VMCounts(
            pageSize: UInt64(vm_kernel_page_size),
            free: UInt64(stats.free_count),
            active: UInt64(stats.active_count),
            inactive: UInt64(stats.inactive_count),
            speculative: UInt64(stats.speculative_count),
            wired: UInt64(stats.wire_count),
            purgeable: UInt64(stats.purgeable_count),
            compressor: UInt64(stats.compressor_page_count),
            internal: UInt64(stats.internal_page_count),
            external: UInt64(stats.external_page_count))
    }

    public static func readSwap() -> (used: UInt64, total: UInt64) {
        var xsw = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &xsw, &size, nil, 0) == 0 else { return (0, 0) }
        return (xsw.xsu_used, xsw.xsu_total)
    }

    public static func readPressure() -> MemoryPressure {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0
        else { return .unknown }
        return MemoryPressure(level: Int(level))
    }
}
