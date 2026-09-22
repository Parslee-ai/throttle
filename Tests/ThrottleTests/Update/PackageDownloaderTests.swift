import XCTest
@testable import Throttle

/// The downloader against a stub `URLProtocol`: every byte comes from this
/// file, nothing leaves the machine.
final class PackageDownloaderTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        directory = try UpdateFixtures.temporaryDirectory()
        StubPackageProtocol.reset()
    }

    override func tearDown() async throws {
        StubPackageProtocol.reset()
        try? FileManager.default.removeItem(at: directory)
    }

    private func downloader(maxBytes: Int = ReleaseFeed.maxPackageBytes) -> PackageDownloader {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubPackageProtocol.self]
        return PackageDownloader(configuration: configuration, maxBytes: maxBytes)
    }

    // MARK: Redirect policy

    func testOnlyHTTPSToApprovedHostsIsAllowed() {
        let allowed = [
            "https://github.com/Parslee-ai/throttle/releases/download/v0.2.0/Throttle-0.2.0.pkg",
            "https://objects.githubusercontent.com/some/object",
            "https://release-assets.githubusercontent.com/github-production-release-asset/1/2",
            "https://GitHub.com/x",
        ]
        for text in allowed {
            XCTAssertTrue(PackageDownloader.isAllowed(URL(string: text)), text)
        }
        let refused = [
            "http://github.com/x",
            "http://release-assets.githubusercontent.com/x",
            "https://github.com.evil.example/x",
            "https://evilgithub.com/x",
            "https://api.github.com/x",
            "https://example.com/x",
            "ftp://github.com/x",
            "file:///tmp/x.pkg",
            "https://github.com:8443/x",
            "https://github.com:443/x",
            "https://release-assets.githubusercontent.com:444/x",
        ]
        for text in refused {
            XCTAssertFalse(PackageDownloader.isAllowed(URL(string: text)), text)
        }
        XCTAssertFalse(PackageDownloader.isAllowed(nil))
    }

    func testRedirectDelegateFollowsOnlyApprovedHosts() {
        let downloader = downloader()
        let task = URLSession(configuration: .ephemeral).dataTask(with: URL(string: "https://github.com/x")!)
        let response = HTTPURLResponse(url: URL(string: "https://github.com/x")!, statusCode: 302, httpVersion: nil, headerFields: nil)!

        let decisions = Decisions()
        for target in ["https://release-assets.githubusercontent.com/a", "https://evil.example/a", "http://objects.githubusercontent.com/a"] {
            downloader.urlSession(URLSession.shared, task: task, willPerformHTTPRedirection: response,
                                  newRequest: URLRequest(url: URL(string: target)!)) { request in
                decisions.append(request?.url?.absoluteString)
            }
        }
        XCTAssertEqual(decisions.values, ["https://release-assets.githubusercontent.com/a", nil, nil])
    }

    // MARK: Downloading

    func testDownloadsExactlyTheListedBytes() async throws {
        let body = Data((0..<200_000).map { UInt8(truncatingIfNeeded: $0) })
        StubPackageProtocol.respond(status: 200, body: body)
        let asset = UpdateFixtures.release("0.2.0", size: body.count).asset

        let file = try await downloader().download(asset, into: directory)

        XCTAssertEqual(file.lastPathComponent, "Throttle-0.2.0.pkg")
        XCTAssertEqual(file.deletingLastPathComponent().standardizedFileURL, directory.standardizedFileURL)
        XCTAssertEqual(try Data(contentsOf: file), body)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path + ".partial"))
        XCTAssertNil(StubPackageProtocol.lastRequest?.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(StubPackageProtocol.lastRequest?.value(forHTTPHeaderField: "Cookie"))
    }

    func testShortBodyFails() async {
        StubPackageProtocol.respond(status: 200, body: Data(repeating: 1, count: 10), contentLength: false)
        let asset = UpdateFixtures.release("0.2.0", size: 64).asset
        await assertDownloadFails(asset, containing: "received 10 bytes")
    }

    func testAnnouncedLengthMismatchFails() async {
        StubPackageProtocol.respond(status: 200, body: Data(repeating: 1, count: 10))
        let asset = UpdateFixtures.release("0.2.0", size: 64).asset
        await assertDownloadFails(asset, containing: "announced 10 bytes")
    }

    func testLongBodyFails() async {
        StubPackageProtocol.respond(status: 200, body: Data(repeating: 1, count: 100), contentLength: false)
        let asset = UpdateFixtures.release("0.2.0", size: 64).asset
        await assertDownloadFails(asset, containing: "larger than the release lists")
    }

    func testOversizedAssetIsRefusedBeforeAnyRequest() async {
        let asset = UpdateFixtures.release("0.2.0", size: 2048).asset
        do {
            _ = try await downloader(maxBytes: 1024).download(asset, into: directory)
            XCTFail("expected a refusal")
        } catch {
            XCTAssertEqual(error as? UpdateError, .download("the package is larger than Throttle accepts"))
        }
        XCTAssertNil(StubPackageProtocol.lastRequest)
    }

    func testUnapprovedAssetURLIsRefusedBeforeAnyRequest() async {
        let asset = ReleaseAsset(name: "Throttle-0.2.0.pkg", downloadURL: URL(string: "https://example.com/Throttle-0.2.0.pkg")!, size: 64, sha256: nil)
        await assertDownloadFails(asset, containing: "not an approved download host")
        XCTAssertNil(StubPackageProtocol.lastRequest)
    }

    func testHTTPErrorFails() async {
        StubPackageProtocol.respond(status: 404, body: Data("Not Found".utf8))
        let asset = UpdateFixtures.release("0.2.0", size: 9).asset
        await assertDownloadFails(asset, containing: "HTTP 404")
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("Throttle-0.2.0.pkg").path))
    }

    private func assertDownloadFails(
        _ asset: ReleaseAsset,
        containing fragment: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await downloader().download(asset, into: directory)
            XCTFail("expected a failure", file: file, line: line)
        } catch {
            guard case UpdateError.download(let reason)? = error as? UpdateError else {
                return XCTFail("expected a download error, got \(error)", file: file, line: line)
            }
            XCTAssertTrue(reason.contains(fragment), "\(reason) should mention \(fragment)", file: file, line: line)
            let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
            XCTAssertEqual(leftovers, [], "a failed download leaves nothing behind", file: file, line: line)
        }
    }
}

private final class Decisions: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String?] = []
    func append(_ value: String?) { lock.withLock { stored.append(value) } }
    var values: [String?] { lock.withLock { stored } }
}

/// Serves one canned response for every request and remembers the last one.
final class StubPackageProtocol: URLProtocol, @unchecked Sendable {
    private struct Canned {
        let status: Int
        let body: Data
        let contentLength: Bool
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var canned: Canned?
    nonisolated(unsafe) private static var recorded: URLRequest?

    static func respond(status: Int, body: Data, contentLength: Bool = true) {
        lock.withLock { canned = Canned(status: status, body: body, contentLength: contentLength) }
    }

    static func reset() {
        lock.withLock {
            canned = nil
            recorded = nil
        }
    }

    static var lastRequest: URLRequest? { lock.withLock { recorded } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = Self.lock.withLock { () -> Canned? in
            Self.recorded = request
            return Self.canned
        }
        guard let response, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        var headers = ["Content-Type": "application/octet-stream"]
        if response.contentLength {
            headers["Content-Length"] = String(response.body.count)
        }
        let http = HTTPURLResponse(url: url, statusCode: response.status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        // Several chunks, so the streaming path actually streams.
        var offset = 0
        while offset < response.body.count {
            let end = min(offset + 16 * 1024, response.body.count)
            client?.urlProtocol(self, didLoad: response.body.subdata(in: offset..<end))
            offset = end
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
