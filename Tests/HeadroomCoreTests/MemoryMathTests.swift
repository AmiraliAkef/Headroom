import XCTest
@testable import HeadroomCore

final class MemoryMathTests: XCTestCase {
    // Page counts captured from `vm_stat` on a 16 GB Apple Silicon Mac.
    let counts = VMCounts(pageSize: 16384, free: 246_993, active: 277_086, inactive: 226_495,
                          speculative: 57_026, wired: 154_052, purgeable: 21_455,
                          compressor: 32_278, internal: 313_050, external: 243_648)

    func testUsedMatchesActivityMonitorFormula() {
        let expected: UInt64 = (313_050 - 21_455 + 154_052 + 32_278) * 16384
        XCTAssertEqual(MemoryMath.used(counts), expected)
        XCTAssertEqual(Double(expected) / bytesPerGB, 7.29, accuracy: 0.01)
    }

    func testAvailableEstimate() {
        XCTAssertEqual(MemoryMath.available(counts), (246_993 + 226_495 + 57_026 + 21_455) * 16384)
    }

    func testCompressed() {
        XCTAssertEqual(MemoryMath.compressed(counts), 32_278 * 16384)
    }

    func testPurgeableLargerThanInternalDoesNotUnderflow() {
        let c = VMCounts(pageSize: 4096, wired: 10, purgeable: 50, compressor: 5, internal: 20)
        XCTAssertEqual(MemoryMath.used(c), 15 * 4096)
    }

    func testPressureLevels() {
        XCTAssertEqual(MemoryPressure(level: 1), .normal)
        XCTAssertEqual(MemoryPressure(level: 2), .warning)
        XCTAssertEqual(MemoryPressure(level: 4), .critical)
        XCTAssertEqual(MemoryPressure(level: 0), .unknown)
    }

    func testLiveSnapshotIsSane() throws {
        let m = try XCTUnwrap(MemoryMonitor.snapshot())
        XCTAssertEqual(m.total, ProcessInfo.processInfo.physicalMemory)
        XCTAssert(m.used > 0 && m.used < m.total)
        XCTAssert(m.available < m.total)
        XCTAssertNotEqual(m.pressure, .unknown)
    }
}

final class MenuBarTextTests: XCTestCase {
    let mem = MemorySnapshot(total: 24 * 1_073_741_824, used: UInt64(14.2 * 1_073_741_824),
                             available: 0, compressed: 0, swapUsed: 0, swapTotal: 0, pressure: .normal)
    let cpu = CPUUsage(total: 0.12, user: 0.08, system: 0.04)
    let fs = "\u{2007}"

    func testModes() {
        XCTAssertEqual(MenuBarText.render(cpu: cpu, memory: mem, mode: .full, restorePending: false).string,
                       "CPU \(fs)12%  RAM 14.2/24 GB")
        XCTAssertEqual(MenuBarText.render(cpu: cpu, memory: mem, mode: .compact, restorePending: false).string,
                       "\(fs)12% · 14.2G")
        XCTAssertEqual(MenuBarText.render(cpu: cpu, memory: mem, mode: .percent, restorePending: false).string,
                       "CPU \(fs)12%  RAM \(fs)59%")
    }

    func testWidthIsStable() {
        let low = MenuBarText.render(cpu: .init(total: 0.03, user: 0.02, system: 0.01),
                                     memory: { var m = mem; m.used = 3 * 1_073_741_824; return m }(),
                                     mode: .full, restorePending: false)
        let high = MenuBarText.render(cpu: .init(total: 1, user: 0.5, system: 0.5), memory: mem,
                                      mode: .full, restorePending: false)
        XCTAssertEqual(low.string.count, high.string.count)
    }

    func testNoCPUBaselineAndRestoreSuffix() {
        let t = MenuBarText.render(cpu: nil, memory: mem, mode: .full, restorePending: true)
        XCTAssertEqual(t.cpu, "CPU \(fs)--%")
        XCTAssertEqual(t.suffix, " ↺")
        XCTAssertEqual(t.ram, "RAM 14.2/24 GB")
    }

    func testShowAvailable() {
        var m = mem
        m.available = UInt64(9.8 * 1_073_741_824)
        func r(_ mode: DisplayMode) -> MenuBarText {
            MenuBarText.render(cpu: cpu, memory: m, mode: mode, restorePending: true, showAvailable: true)
        }
        XCTAssertEqual(r(.full).string, "CPU \(fs)12%  RAM 14.2/24 GB  Avail \(fs)9.8 GB ↺")
        XCTAssertEqual(r(.compact).string, "\(fs)12% · 14.2G · \(fs)9.8G free ↺")
        XCTAssertEqual(r(.percent).string, "CPU \(fs)12%  RAM \(fs)59%  Avail \(fs)41% ↺")
        XCTAssertEqual(MenuBarText.render(cpu: cpu, memory: m, mode: .full, restorePending: false).available, "")
        XCTAssertEqual(MenuBarText.render(cpu: cpu, memory: nil, mode: .compact, restorePending: false,
                                          showAvailable: true).available, " · -- free")
    }

    func testFractionalTotal() {
        var m = mem
        m.total = UInt64(15.5 * 1_073_741_824)
        XCTAssertEqual(MenuBarText.render(cpu: cpu, memory: m, mode: .full, restorePending: false).ram,
                       "RAM 14.2/15.5 GB")
    }
}
