import XCTest
@testable import HeadroomCore

final class CPUMathTests: XCTestCase {
    func testUsageFromDeltas() throws {
        let a = CPUTicks(user: 1000, system: 500, idle: 8000, nice: 0)
        let b = CPUTicks(user: 1060, system: 520, idle: 8320, nice: 20)
        let u = try XCTUnwrap(CPUMath.usage(from: a, to: b))
        // busy = 60 + 20 + 20 = 100 of 420 total
        XCTAssertEqual(u.total, 100.0 / 420, accuracy: 1e-9)
        XCTAssertEqual(u.user, 80.0 / 420, accuracy: 1e-9)  // nice counts as user
        XCTAssertEqual(u.system, 20.0 / 420, accuracy: 1e-9)
        XCTAssertEqual(u.user + u.system, u.total, accuracy: 1e-9)
    }

    func testIdleAndFullyBusy() throws {
        let a = CPUTicks(user: 0, system: 0, idle: 0, nice: 0)
        XCTAssertEqual(try XCTUnwrap(CPUMath.usage(from: a, to: .init(user: 0, system: 0, idle: 100, nice: 0))).total, 0)
        XCTAssertEqual(try XCTUnwrap(CPUMath.usage(from: a, to: .init(user: 50, system: 50, idle: 0, nice: 0))).total, 1)
    }

    func testNoElapsedTicksOrBackwardsIsNil() {
        let a = CPUTicks(user: 10, system: 10, idle: 10, nice: 0)
        XCTAssertNil(CPUMath.usage(from: a, to: a))
        XCTAssertNil(CPUMath.usage(from: a, to: .init(user: 5, system: 20, idle: 20, nice: 0)))
    }

    func testMonitorFirstSampleIsNilThenValue() throws {
        let m = CPUMonitor()
        XCTAssertNil(m.sample())
        // Burn a little CPU so ticks advance.
        var x = 0.0
        let end = Date().addingTimeInterval(0.1)
        while Date() < end { x += sin(x) }
        let u = try XCTUnwrap(m.sample())
        XCTAssert((0...1).contains(u.total))
        m.reset()
        XCTAssertNil(m.sample())
    }

    func testReadTicksRepeatedlyDoesNotLeak() {
        // host_processor_info's array must be vm_deallocate'd; this would grow otherwise.
        for _ in 0..<10_000 { XCTAssertNotNil(CPUMonitor.readTicks()) }
    }
}
