import XCTest

/// ISC-87 and ISC-137: Throttle owns one Keychain service and writes nowhere
/// else. The credential import reads another app's store exactly once and never
/// writes back; two stores racing on a refresh-token rotation is what bricks an
/// account, which is why this is asserted statically rather than left to review.
final class NoForeignWritesTests: XCTestCase {
    /// The only Keychain service Throttle may add to or update.
    private let ownService = "ai.parslee.throttle"

    /// Credential stores that belong to other apps. Reading them is the
    /// user-initiated import; writing them is the bug.
    private let foreignStoreMarkers = ["auth.json", "Claude Code-credentials"]

    private let writeMarkers = ["write(", "createFile", "SecItemAdd", "SecItemUpdate", "SecItemDelete"]

    func testNoWriteTouchesAnotherAppsCredentialStore() throws {
        var offenders: [String] = []
        for line in try RepoAudit.sourceLines() {
            guard line.containsAny(foreignStoreMarkers) else { continue }
            let writes = writeMarkers.filter(line.text.contains)
            guard !writes.isEmpty else { continue }
            offenders.append("\(line.location): \(writes.joined(separator: ", ")) in \(line.trimmed)")
        }
        XCTAssertTrue(
            offenders.isEmpty,
            RepoAudit.report(
                "ISC-87: a write reaches another app's credential store:",
                offenders
            )
        )
    }

    /// A file that writes to the Keychain may not name any service but ours.
    /// Service names reach `SecItem*` through a variable, so the audit checks
    /// every string literal that the file binds to a service-shaped symbol or
    /// hands to `kSecAttrService` directly.
    func testKeychainWritesOnlyNameThrottlesOwnService() throws {
        var offenders: [String] = []
        for file in try RepoAudit.swiftFiles() {
            let lines = try RepoAudit.lines(in: file)
            let writesToKeychain = lines.contains { $0.contains("SecItemAdd") || $0.contains("SecItemUpdate") }
            guard writesToKeychain else { continue }

            for line in lines {
                guard !line.isComment else { continue }
                let lowered = line.text.lowercased()
                let namesAService = lowered.contains("service")
                guard namesAService else { continue }
                for literal in RepoAudit.stringLiterals(in: line.text) where literal != ownService {
                    offenders.append("\(line.location): service literal \"\(literal)\" in a file that writes the Keychain")
                }
            }
        }
        XCTAssertTrue(
            offenders.isEmpty,
            RepoAudit.report(
                "ISC-137: Keychain-writing file names a service other than \(ownService):",
                offenders
            )
        )
    }
}
