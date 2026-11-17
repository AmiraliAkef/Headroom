import Darwin

/// Cumulative CPU tick counts summed across all cores.
public struct CPUTicks: Equatable, Sendable {
    public var user: UInt64
    public var system: UInt64
    public var idle: UInt64
    public var nice: UInt64

    public init(user: UInt64, system: UInt64, idle: UInt64, nice: UInt64) {
        self.user = user
        self.system = system
        self.idle = idle
        self.nice = nice
    }
}

/// CPU usage over an interval, each value in 0...1.
public struct CPUUsage: Equatable, Sendable {
    public let total: Double
    public let user: Double
    public let system: Double
}

public enum CPUMath {
    /// Usage between two samples. Returns nil if no time passed or a counter went
    /// backwards (e.g. a core went offline between samples).
    public static func usage(from a: CPUTicks, to b: CPUTicks) -> CPUUsage? {
        guard b.user >= a.user, b.system >= a.system, b.idle >= a.idle, b.nice >= a.nice else {
            return nil
        }
        let du = Double(b.user - a.user)
        let ds = Double(b.system - a.system)
        let dn = Double(b.nice - a.nice)
        let di = Double(b.idle - a.idle)
        let all = du + ds + dn + di
        guard all > 0 else { return nil }
        // "nice" is user time at lower priority; Activity Monitor counts it as user.
        return CPUUsage(total: (du + ds + dn) / all, user: (du + dn) / all, system: ds / all)
    }
}

/// Live CPU usage from `host_processor_info` tick deltas. Not thread-safe; use from one thread.
public final class CPUMonitor {
    private var previous: CPUTicks?
    private static let host = mach_host_self()  // cached: each call creates a port right

    public init() {}

    /// Usage since the previous call. The first call (and the first after `reset()`)
    /// returns nil because there is no baseline yet.
    public func sample() -> CPUUsage? {
        guard let now = Self.readTicks() else { return nil }
        defer { previous = now }
        guard let prev = previous else { return nil }
        return CPUMath.usage(from: prev, to: now)
    }

    /// Drop the baseline, e.g. after waking from sleep.
    public func reset() { previous = nil }

    public static func readTicks() -> CPUTicks? {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        let kr = host_processor_info(host, PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount)
        guard kr == KERN_SUCCESS, let info else { return nil }
        // The array is allocated in our address space by the kernel; free it every time
        // or the app leaks memory on every tick.
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info),
                          vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }
        var t = CPUTicks(user: 0, system: 0, idle: 0, nice: 0)
        let stride = Int(CPU_STATE_MAX)
        for cpu in 0..<Int(cpuCount) {
            let base = cpu * stride
            t.user += UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_USER)]))
            t.system += UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]))
            t.idle += UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)]))
            t.nice += UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)]))
        }
        return t
    }
}
