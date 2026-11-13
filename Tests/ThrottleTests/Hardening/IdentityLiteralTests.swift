import XCTest

/// ISC-525: one type decides where a copy of Throttle keeps its state. A
/// second literal for the Keychain service, the data folder or the update
/// cache would let a development build drift back onto the release's store.
final class IdentityLiteralTests: XCTestCase {
    /// The files allowed to spell the release identifier: the identity
    /// itself, and the package check, which names the product an update must
    /// be whatever copy runs it.
    private let allowedFiles: Set<String> = ["AppIdentity.swift", "PackageVerifier.swift"]

    /// Lines that may carry the identifier without deciding a location.
    private let allowedUses = ["Logger(subsystem:", "DispatchQueue(label:"]

    func testOnlyTheIdentityNamesTheReleaseIdentifier() throws {
        var offenders: [String] = []
        for line in try RepoAudit.sourceLines() where !line.isComment {
            guard line.contains("\"ai.parslee.throttle"),
                  !allowedFiles.contains((line.file as NSString).lastPathComponent),
                  !line.containsAny(allowedUses) else { continue }
            offenders.append("\(line.location): \(line.trimmed)")
        }
        XCTAssertTrue(offenders.isEmpty, RepoAudit.report("ISC-525: the bundle identifier is spelled outside AppIdentity:", offenders))
    }

    func testOnlyTheIdentityNamesTheDataFolder() throws {
        var offenders: [String] = []
        for line in try RepoAudit.sourceLines() where !line.isComment {
            guard line.contains("appendingPathComponent(\"Throttle"),
                  (line.file as NSString).lastPathComponent != "AppIdentity.swift" else { continue }
            offenders.append("\(line.location): \(line.trimmed)")
        }
        XCTAssertTrue(offenders.isEmpty, RepoAudit.report("ISC-525: a data folder is named outside AppIdentity:", offenders))
    }
}
