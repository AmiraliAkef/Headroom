import XCTest
@testable import HeadroomCore

final class ConfigTests: XCTestCase {
    func json(_ s: String) -> Data { Data(s.utf8) }

    func profileJSON(_ body: String, extraTop: String = "") -> Data {
        json(#"{"defaultProfile":"p",\#(extraTop)"profiles":{"p":{\#(body)}}}"#)
    }

    func testDefaultsParse() throws {
        let cfg = try ConfigLoader.parse(ConfigLoader.defaultData(totalGB: 64), totalGB: 64)
        XCTAssertEqual(cfg.defaultProfile, "llm")
        let llm = try cfg.profile(nil)
        XCTAssertEqual(llm.targetGB, 24)
        XCTAssertTrue(llm.stopDocker)
        XCTAssertEqual(llm.quitApps.first, "com.google.Chrome")
        XCTAssertFalse(try cfg.profile("build").stopDocker)
        XCTAssertEqual(cfg.warnings, [])
        XCTAssertEqual(cfg.orderedProfiles.map(\.name), ["llm", "build"])
        XCTAssertEqual(llm.displayName, "LLM")
        XCTAssertEqual(try cfg.profile("build").displayName, "Build")
    }

    func testDefaultsAreValidOnEveryMac() throws {
        for total in [8.0, 16, 24, 64] {
            let cfg = try ConfigLoader.parse(ConfigLoader.defaultData(totalGB: total), totalGB: total)
            for p in cfg.profiles.values { XCTAssertLessThan(p.targetGB, total) }
        }
        let cfg16 = try ConfigLoader.parse(ConfigLoader.defaultData(totalGB: 16), totalGB: 16)
        XCTAssertEqual(try cfg16.profile("llm").targetGB, 9.6)  // 24 doesn't fit: scaled
        XCTAssertEqual(try cfg16.profile("build").targetGB, 12)  // fits: untouched
    }

    func testUnknownKeysWarn() throws {
        let cfg = try ConfigLoader.parse(profileJSON(#""targetGB":4,"colour":"red""#, extraTop: #""extra":1,"#))
        XCTAssertEqual(cfg.warnings.count, 2)
    }

    func testProtectedAppErrorsWithName() {
        XCTAssertThrowsError(try ConfigLoader.parse(profileJSON(#""targetGB":4,"quitApps":["com.apple.finder"]"#))) {
            XCTAssert(($0 as! ConfigError).message.contains("com.apple.finder"))
        }
        XCTAssertThrowsError(try ConfigLoader.parse(profileJSON(#""targetGB":4,"quitApps":["com.googlecode.iterm2"]"#)))
    }

    func testTargetValidation() throws {
        for bad in ["0", "-1", #""12""#, "true"] {
            XCTAssertThrowsError(try ConfigLoader.parse(profileJSON(#""targetGB":\#(bad)"#)), bad)
        }
        XCTAssertThrowsError(try ConfigLoader.parse(profileJSON(#""targetGB":16"#), totalGB: 16))
        XCTAssertNoThrow(try ConfigLoader.parse(profileJSON(#""targetGB":15.5"#), totalGB: 16))
    }

    func testUnknownDefaultProfileErrors() {
        XCTAssertThrowsError(try ConfigLoader.parse(json(#"{"defaultProfile":"nope","profiles":{"p":{"targetGB":4}}}"#)))
        XCTAssertThrowsError(try ConfigLoader.parse(profileJSON(#""targetGB":4"#)).profile("nope"))
    }

    func testFlagsMustBeBools() {
        XCTAssertThrowsError(try ConfigLoader.parse(profileJSON(#""targetGB":4,"stopDocker":1"#)))
    }

    func testLoadCreatesOnFirstRunAndAddApp() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("config.json")
        let cfg = try ConfigLoader.load(at: url, totalGB: 16)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(try cfg.profile("llm").targetGB, 9.6)

        XCTAssertTrue(try ConfigLoader.addApp("com.example.App", toProfile: "build", at: url, totalGB: 16))
        XCTAssertFalse(try ConfigLoader.addApp("com.example.App", toProfile: "build", at: url, totalGB: 16))
        XCTAssertEqual(try ConfigLoader.load(at: url, totalGB: 16).profile("build").quitApps.last, "com.example.App")
        XCTAssertThrowsError(try ConfigLoader.addApp("com.apple.finder", toProfile: "build", at: url, totalGB: 16))
        XCTAssertThrowsError(try ConfigLoader.addApp("com.example.B", toProfile: "nope", at: url, totalGB: 16))
    }
}

final class ModelParserTests: XCTestCase {
    func fixture(_ name: String) throws -> String {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "txt", subdirectory: "Fixtures"))
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testOllamaPS() throws {
        let ms = ModelParsers.ollamaPS(try fixture("ollama_ps"))
        XCTAssertEqual(ms.map(\.name), ["qwen3.6:35b-a3b", "llama3.2:3b"])
        XCTAssertEqual(ms[0].sizeBytes, 23_000_000_000)
        XCTAssertEqual(ms[1].sizeBytes, 3_400_000_000)
        XCTAssertEqual(ms[0].runtime, .ollama)
    }

    func testOllamaEmptyAndError() throws {
        XCTAssertEqual(ModelParsers.ollamaPS(try fixture("ollama_ps_empty")), [])
        XCTAssertEqual(ModelParsers.ollamaPS("Error: could not connect to ollama server"), [])
    }

    func testLMStudioListFormat() throws {
        let ms = ModelParsers.lmsPS(try fixture("lms_ps"))
        XCTAssertEqual(ms.map(\.name), ["qwen2.5-7b-instruct", "text-embedding-nomic-embed-text-v1.5"])
        XCTAssertEqual(ms[0].sizeBytes, 4_680_000_000)
        XCTAssertEqual(ms[1].sizeBytes, 84_110_000)
    }

    func testLMStudioTableFormat() throws {
        let ms = ModelParsers.lmsPS(try fixture("lms_ps_table"))
        XCTAssertEqual(ms.map(\.name), ["qwen2.5-7b-instruct"])
        XCTAssertEqual(ms[0].sizeBytes, 4_680_000_000)
    }

    func testLMStudioNone() {
        XCTAssertEqual(ModelParsers.lmsPS("No models are currently loaded\n"), [])
    }

    func testParseSize() {
        XCTAssertEqual(ModelParsers.parseSize("512 MiB"), 536_870_912)
        XCTAssertEqual(ModelParsers.parseSize("n/a"), 0)
    }
}
