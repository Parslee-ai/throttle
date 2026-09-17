import Foundation
import XCTest

/// Fixture access for every test. Files under `Tests/Fixtures` are resources
/// of the test bundle, so they are read from the bundle, never from the
/// repository checkout: the host app reading `~/Documents` raises a privacy
/// prompt that a headless run cannot answer, and the suite hangs on it.
enum TestFixtures {
    private final class Marker {}

    static func url(_ name: String, extension ext: String = "json") throws -> URL {
        let bundle = Bundle(for: Marker.self)
        guard let url = bundle.url(forResource: name, withExtension: ext) else {
            throw NSError(domain: "TestFixtures", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "fixture \(name).\(ext) is not in the test bundle; is Tests/Fixtures still a synchronized group on ThrottleTests?",
            ])
        }
        return url
    }

    static func data(_ name: String, extension ext: String = "json") throws -> Data {
        try Data(contentsOf: url(name, extension: ext))
    }
}
