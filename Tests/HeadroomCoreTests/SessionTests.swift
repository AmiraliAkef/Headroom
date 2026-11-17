import XCTest
@testable import HeadroomCore

final class SessionTests: XCTestCase {
    var store: SessionStore!
    var dir: URL!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        store = SessionStore(url: dir.appendingPathComponent("session.json"))
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    let slack = SessionApp(bundleId: "com.tinyspeck.slackmacgap", name: "Slack", bundleURL: "/Applications/Slack.app")
    let spotify = SessionApp(bundleId: "com.spotify.client", name: "Spotify", bundleURL: "/Applications/Spotify.app")

    func testRoundTripMatchesPlanShape() throws {
        let s = Session(createdAt: Date(timeIntervalSince1970: 1_800_000_000), profile: "llm", quitApps: [slack],
                        dockerStopped: true, unloadedModels: ["qwen3.6:35b-a3b"], availableBeforeGB: 9.4,
                        availableAfterGB: 25.1)
        try store.write(s)
        XCTAssertEqual(store.load(), s)
        let obj = try JSONSerialization.jsonObject(with: Data(contentsOf: store.url)) as! [String: Any]
        XCTAssertEqual(Set(obj.keys), ["createdAt", "profile", "quitApps", "dockerStopped", "unloadedModels",
                                       "availableBeforeGB", "availableAfterGB", "claudeSessions"])
        XCTAssert((obj["createdAt"] as! String).hasPrefix("2027-01-15T"))
        let app = (obj["quitApps"] as! [[String: Any]])[0]
        XCTAssertEqual(app as NSDictionary, ["bundleId": "com.tinyspeck.slackmacgap", "name": "Slack",
                                             "bundleURL": "/Applications/Slack.app", "background": false])
    }

    func testOldSessionAppWithoutBackgroundStillLoads() throws {
        let json = #"{"bundleId":"a.b","name":"A","bundleURL":"/Applications/A.app"}"#
        let app = try JSONDecoder().decode(SessionApp.self, from: Data(json.utf8))
        XCTAssertFalse(app.background)
    }

    func testMergeKeepsEverythingForOneRestore() throws {
        let t0 = Date(timeIntervalSince1970: 1000)
        try store.save(merging: Session(createdAt: t0, profile: "llm", quitApps: [slack], dockerStopped: true,
                                        unloadedModels: ["m1"], availableBeforeGB: 5, availableAfterGB: 9))
        let m = try store.save(merging: Session(profile: "build", quitApps: [slack, spotify], unloadedModels: ["m2"],
                                                availableBeforeGB: 9, availableAfterGB: 12))
        XCTAssertEqual(m.quitApps, [slack, spotify])
        XCTAssertEqual(m.unloadedModels, ["m1", "m2"])
        XCTAssertTrue(m.dockerStopped)
        XCTAssertEqual(m.createdAt, t0)
        XCTAssertEqual(m.availableBeforeGB, 5)
        XCTAssertEqual(m.availableAfterGB, 12)
        XCTAssertEqual(m.restoreCount, 3)
        XCTAssertEqual(store.load(), m)
    }

    func testClear() throws {
        XCTAssertNil(store.load())
        try store.write(Session(profile: "p", availableBeforeGB: 1))
        XCTAssertTrue(store.exists)
        store.clear()
        XCTAssertFalse(store.exists)
        XCTAssertNil(store.load())
    }
}
