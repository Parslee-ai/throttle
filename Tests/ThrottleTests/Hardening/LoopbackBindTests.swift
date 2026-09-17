import XCTest

/// ISC-135: the OAuth callback listener binds loopback only.
///
/// A listener on `0.0.0.0` puts an authorization code, briefly, on every
/// interface the machine has. The bind address is a one-line decision that no
/// runtime test on a developer laptop would ever notice, so it is pinned here.
final class LoopbackBindTests: XCTestCase {
    private let listenerFile = "Sources/Throttle/Auth/LoopbackCallbackServer.swift"

    /// Wildcard binds, in the spellings Network.framework and BSD sockets accept.
    private let wildcardBindMarkers = ["0.0.0.0", "IPv6.any", "ipv6.any", ".any)", "\"::\"", "in6addr_any", "INADDR_ANY"]

    private func listenerLines() throws -> [RepoAudit.SourceLine] {
        try RepoAudit.lines(in: RepoAudit.root.appendingPathComponent(listenerFile))
    }

    func testListenerNamesLoopback() throws {
        let lines = try listenerLines()
        XCTAssertTrue(
            lines.contains { $0.contains("127.0.0.1") },
            "ISC-135: \(listenerFile) no longer names 127.0.0.1; the loopback bind may have moved or been removed"
        )
    }

    func testListenerNeverBindsAWildcardAddress() throws {
        var offenders: [String] = []
        for line in try listenerLines() {
            let hits = wildcardBindMarkers.filter(line.text.contains)
            guard !hits.isEmpty else { continue }
            offenders.append("\(line.location): \(hits.joined(separator: ", ")) in \(line.trimmed)")
        }
        XCTAssertTrue(
            offenders.isEmpty,
            RepoAudit.report("ISC-135: callback listener binds a non-loopback address:", offenders)
        )
    }
}
