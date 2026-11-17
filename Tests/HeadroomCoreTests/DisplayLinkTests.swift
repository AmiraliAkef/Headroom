import XCTest
@testable import HeadroomCore

final class DisplayLinkTests: XCTestCase {
    let dl = app("com.displaylink.DisplayLinkUserAgent", "DisplayLink Manager", pid: 750)
    let profile = Profile(name: "p", targetGB: 20, quitApps: ["com.displaylink.DisplayLinkUserAgent"],
                          unloadModels: false)
    var dir: URL!
    var env: FakeEnvironment!
    var engine: PrepEngine!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        env = FakeEnvironment(apps: [dl], sizes: [dl.bundleId: 200 * 1_048_576], availableGB: [10])
        engine = PrepEngine(env: env, store: SessionStore(url: dir.appendingPathComponent("session.json")))
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    func testParseIoreg() {
        let plugged = """
            +-o USB3.0 Hub@01100000  <class IOUSBHostDevice>
                  "idVendor" = 6121
                  "USB Product Name" = "Dell Universal Dock D6000"
            """
        XCTAssertTrue(DisplayLink.deviceConnected(ioregOutput: plugged))
        XCTAssertFalse(DisplayLink.deviceConnected(ioregOutput: "\"idVendor\" = 1452\n\"idVendor\" = 61210\n"))
        XCTAssertFalse(DisplayLink.deviceConnected(ioregOutput: ""))
    }

    func testQuitWhenMonitorNotConnected() throws {
        env.displayLink = [false]
        XCTAssertEqual(engine.candidates(for: profile).map(\.name), ["DisplayLink Manager"])
        _ = engine.execute(try engine.plan(profile: profile))
        XCTAssertEqual(env.quitCalls.map(\.0), [dl.bundleId])
    }

    func testKeptWhenMonitorConnected() {
        env.displayLink = [true]
        XCTAssertTrue(engine.candidates(for: profile).isEmpty)
    }

    func testPluggedInAfterPlanningIsSpared() throws {
        env.displayLink = [false, true]
        let plan = try engine.plan(profile: profile)
        XCTAssertEqual(plan.items.count, 1)
        let r = engine.execute(plan)
        XCTAssertTrue(env.quitCalls.isEmpty)
        XCTAssertEqual(r.skipped.first?.reason, "a DisplayLink monitor is connected")
    }
}
