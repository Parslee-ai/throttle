import XCTest
@testable import Throttle

/// ISC-99 across relaunches: `rate-limits.json` holds provider ids and dates,
/// nothing else, and a bad file is treated as empty.
final class BackoffPersistenceTests: XCTestCase {
    private var directory: URL!
    private var paths: AppPaths!
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ThrottleBackoffPersistenceTests-\(UUID().uuidString)", isDirectory: true)
        paths = AppPaths(applicationSupportDirectory: directory)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testRoundTripsProviderHorizons() throws {
        let store = BackoffPersistence(paths: paths)
        store.save([.anthropic: t0.addingTimeInterval(3_600)])
        XCTAssertEqual(store.load(), [.anthropic: t0.addingTimeInterval(3_600)])

        let attributes = try FileManager.default.attributesOfItem(atPath: paths.rateLimitsFile.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testFileHoldsOnlyProviderKeysAndDates() throws {
        let data = try BackoffPersistence.encode([.anthropic: t0, .openai: t0.addingTimeInterval(60)])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), Set(Provider.allCases.map(\.rawValue)))
        for value in object.values {
            let string = try XCTUnwrap(value as? String, "every value is an ISO-8601 string")
            XCTAssertNotNil(try? Date.ISO8601FormatStyle().parse(string))
        }
    }

    func testMissingFileLoadsEmpty() {
        XCTAssertEqual(BackoffPersistence(paths: paths).load(), [:])
    }

    func testUnknownKeysAreSkippedAndGarbageIsEmpty() throws {
        try paths.ensureDirectoryExists()
        try #"{"anthropic":"2023-11-14T22:13:20Z","gemini":"2023-11-14T22:13:20Z"}"#
            .write(to: paths.rateLimitsFile, atomically: true, encoding: .utf8)
        XCTAssertEqual(BackoffPersistence(paths: paths).load(), [.anthropic: t0])

        try "not json".write(to: paths.rateLimitsFile, atomically: true, encoding: .utf8)
        XCTAssertEqual(BackoffPersistence(paths: paths).load(), [:])
    }

    func testSavingEmptyClearsTheFile() throws {
        let store = BackoffPersistence(paths: paths)
        store.save([.anthropic: t0.addingTimeInterval(3_600)])
        store.save([:])
        XCTAssertEqual(store.load(), [:])
        XCTAssertEqual(try String(contentsOf: paths.rateLimitsFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), "{\n\n}")
    }
}
