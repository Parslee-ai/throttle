import XCTest
@testable import Throttle

final class ReleaseFeedTests: XCTestCase {
    private let current = SemanticVersion("0.1.0")!

    private func feed(_ responses: [HTTPResponse]) -> (ReleaseFeed, AuthMockHTTPClient) {
        let client = AuthMockHTTPClient(responses: responses)
        return (ReleaseFeed(client: client, currentVersion: current), client)
    }

    private func assertNotInstallable(_ json: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try ReleaseFeed.parse(Data(json.utf8)), file: file, line: line) { error in
            guard case UpdateError.noInstallableUpdate(let reason)? = error as? UpdateError else {
                return XCTFail("expected noInstallableUpdate, got \(error)", file: file, line: line)
            }
            XCTAssertFalse(reason.isEmpty, file: file, line: line)
        }
    }

    // MARK: Parsing

    func testParsesTheFixtureListing() throws {
        let release = try ReleaseFeed.parse(TestFixtures.data("github-latest-release"))
        XCTAssertEqual(release.version, SemanticVersion("0.2.0"))
        XCTAssertEqual(release.asset.name, "Throttle-0.2.0.pkg")
        XCTAssertEqual(release.asset.downloadURL.absoluteString,
                       "https://github.com/Parslee-ai/throttle/releases/download/v0.2.0/Throttle-0.2.0.pkg")
        XCTAssertEqual(release.asset.size, 1_339_213)
        XCTAssertEqual(release.asset.sha256, UpdateFixtures.zeroSHA256, "the digest loses its sha256: prefix")
    }

    func testAMissingOrNullDigestIsAllowed() throws {
        XCTAssertNil(try ReleaseFeed.parse(Data(UpdateFixtures.releaseJSON(digest: .none).utf8)).asset.sha256)
        XCTAssertNil(try ReleaseFeed.parse(Data(UpdateFixtures.releaseJSON(digest: .some(nil)).utf8)).asset.sha256)
        let hex = UpdateFixtures.abcSHA256
        XCTAssertEqual(try ReleaseFeed.parse(Data(UpdateFixtures.releaseJSON(digest: "sha256:" + hex).utf8)).asset.sha256, hex)
    }

    func testAMalformedDigestIsRefused() {
        let hex = UpdateFixtures.abcSHA256
        let malformed = [
            "",
            hex,
            "sha256:" + hex.uppercased(),
            "sha512:" + hex,
            "sha1:a9993e364706816aba3e25717850c26c9cd0d89d",
            "sha256:" + String(hex.dropLast()),
            "sha256:" + hex + "0",
            "sha256:" + hex + "\n",
            "sha256: " + hex,
            "sha256:" + String(hex.dropLast()) + "g",
        ]
        for digest in malformed {
            assertNotInstallable(UpdateFixtures.releaseJSON(digest: .some(digest)))
        }
    }

    func testParsesAPrereleaseVersionTagWhenTheReleaseIsPublished() throws {
        let release = try ReleaseFeed.parse(Data(UpdateFixtures.releaseJSON(tag: "v0.3.0-rc.1").utf8))
        XCTAssertEqual(release.version.text, "0.3.0-rc.1")
        XCTAssertEqual(release.asset.name, "Throttle-0.3.0-rc.1.pkg")
    }

    func testRejectsDraftsAndPrereleases() {
        assertNotInstallable(UpdateFixtures.releaseJSON(draft: true))
        assertNotInstallable(UpdateFixtures.releaseJSON(prerelease: true))
    }

    func testRejectsAWrongHost() {
        assertNotInstallable(UpdateFixtures.releaseJSON(
            downloadURL: "https://evil.example.com/Parslee-ai/throttle/releases/download/v0.2.0/Throttle-0.2.0.pkg"))
        assertNotInstallable(UpdateFixtures.releaseJSON(
            downloadURL: "https://github.com.evil.example/Parslee-ai/throttle/releases/download/v0.2.0/Throttle-0.2.0.pkg"))
        assertNotInstallable(UpdateFixtures.releaseJSON(
            downloadURL: "http://github.com/Parslee-ai/throttle/releases/download/v0.2.0/Throttle-0.2.0.pkg"))
    }

    func testRejectsAWrongRepository() {
        assertNotInstallable(UpdateFixtures.releaseJSON(
            downloadURL: "https://github.com/someone-else/throttle/releases/download/v0.2.0/Throttle-0.2.0.pkg"))
        assertNotInstallable(UpdateFixtures.releaseJSON(
            downloadURL: "https://github.com/Parslee-ai/throttle-fork/releases/download/v0.2.0/Throttle-0.2.0.pkg"))
    }

    func testRejectsAWrongAssetName() {
        assertNotInstallable(UpdateFixtures.releaseJSON(assetName: "Throttle.pkg"))
        assertNotInstallable(UpdateFixtures.releaseJSON(assetName: "Throttle-0.2.0.dmg"))
        assertNotInstallable(UpdateFixtures.releaseJSON(assetName: "Throttle-0.3.0.pkg"))
        // Right name, but the URL points at another tag's package.
        assertNotInstallable(UpdateFixtures.releaseJSON(
            downloadURL: "https://github.com/Parslee-ai/throttle/releases/download/v0.1.0/Throttle-0.2.0.pkg"))
    }

    func testRejectsHostileTags() {
        let hostile = [
            "v0.2.0';rm -rf ~;'",
            "v../../0.2.0",
            "v0.2.0/../../x",
            "v0.2.0\n",
            "v0.2.0\nrm -rf ~",
            "v0.2.0 $(touch /tmp/x)",
            "v0.2.0`id`",
            "0.2.0",
            "release-0.2.0",
        ]
        for tag in hostile {
            // Name and URL follow the tag, so only the tag itself can fail.
            assertNotInstallable(UpdateFixtures.releaseJSON(tag: tag))
        }
    }

    func testRejectsImplausibleSizes() {
        assertNotInstallable(UpdateFixtures.releaseJSON(size: 0))
        assertNotInstallable(UpdateFixtures.releaseJSON(size: ReleaseFeed.maxPackageBytes + 1))
    }

    func testMalformedListingIsUnreadable() {
        XCTAssertThrowsError(try ReleaseFeed.parse(Data("{\"message\":\"nope\"}".utf8))) { error in
            guard case UpdateError.unreadableFeed? = error as? UpdateError else {
                return XCTFail("expected unreadableFeed, got \(error)")
            }
        }
    }

    // MARK: The request

    func testRequestIsAnAnonymousGETWithGitHubHeaders() async throws {
        let (feed, client) = feed([AuthTestSupport.json(UpdateFixtures.releaseJSON())])
        _ = try await feed.check()
        XCTAssertEqual(client.requests.count, 1)
        let request = try XCTUnwrap(client.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://api.github.com/repos/Parslee-ai/throttle/releases/latest")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/vnd.github+json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-GitHub-Api-Version"), "2022-11-28")
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "Throttle/0.1.0")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
        XCTAssertFalse(request.httpShouldHandleCookies)
        XCTAssertNil(request.httpBody)
    }

    // MARK: Comparing

    func testNewerReleaseIsAvailable() async throws {
        let (feed, _) = feed([AuthTestSupport.json(UpdateFixtures.releaseJSON(tag: "v0.2.0"))])
        let result = try await feed.check()
        guard case .available(let release) = result else { return XCTFail("expected available, got \(result)") }
        XCTAssertEqual(release.version.text, "0.2.0")
    }

    func testSameOrOlderReleaseIsUpToDate() async throws {
        for tag in ["v0.1.0", "v0.1.0-rc.9", "v0.0.9"] {
            let (feed, _) = feed([AuthTestSupport.json(UpdateFixtures.releaseJSON(tag: tag))])
            let result = try await feed.check()
            XCTAssertEqual(result, .upToDate, tag)
        }
    }

    // MARK: HTTP outcomes

    private func checkError(_ response: HTTPResponse) async -> UpdateError? {
        let (feed, _) = feed([response])
        do {
            _ = try await feed.check()
            return nil
        } catch {
            return error as? UpdateError
        }
    }

    func testNoPublishedReleaseIs404() async {
        let error = await checkError(AuthTestSupport.json(404, #"{"message":"Not Found"}"#))
        guard case .noInstallableUpdate? = error else { return XCTFail("got \(String(describing: error))") }
    }

    func testRateLimitWithRetryAfter() async {
        let before = Date()
        let error = await checkError(HTTPResponse(statusCode: 429, headers: ["retry-after": "120"], body: Data()))
        guard case .rateLimited(let retryAt?)? = error else { return XCTFail("got \(String(describing: error))") }
        XCTAssertEqual(retryAt.timeIntervalSince(before), 120, accuracy: 5)
        XCTAssertTrue(error!.userMessage.contains("Try again in 2 minutes"), error!.userMessage)
    }

    func testPrimaryRateLimitIs403WithZeroRemaining() async {
        let reset = Date().addingTimeInterval(600).timeIntervalSince1970.rounded()
        let error = await checkError(HTTPResponse(
            statusCode: 403,
            headers: ["x-ratelimit-remaining": "0", "x-ratelimit-reset": String(Int(reset))],
            body: Data(#"{"message":"API rate limit exceeded"}"#.utf8)
        ))
        guard case .rateLimited(let retryAt?)? = error else { return XCTFail("got \(String(describing: error))") }
        XCTAssertEqual(retryAt.timeIntervalSince1970, reset, accuracy: 1)
        XCTAssertTrue(error!.userMessage.contains("GitHub is limiting update checks"))
    }

    func testRateLimitWithoutATimeStillReadsWell() async {
        let error = await checkError(HTTPResponse(statusCode: 429, headers: [:], body: Data()))
        XCTAssertEqual(error, .rateLimited(retryAt: nil))
        XCTAssertTrue(error!.userMessage.hasSuffix("Try again later."))
    }

    func testOther403AndServerErrorsAreReported() async {
        let forbidden = await checkError(HTTPResponse(statusCode: 403, headers: ["x-ratelimit-remaining": "42"], body: Data()))
        XCTAssertEqual(forbidden, .server(status: 403))
        let broken = await checkError(HTTPResponse(statusCode: 502, headers: [:], body: Data()))
        XCTAssertEqual(broken, .server(status: 502))
        XCTAssertTrue(broken!.userMessage.contains("HTTP 502"))
    }

    func testTransportFailureIsANetworkError() async {
        let client = AuthMockHTTPClient(results: [.failure(UsageError.transport(URLError(.notConnectedToInternet)))])
        let feed = ReleaseFeed(client: client, currentVersion: current)
        do {
            _ = try await feed.check()
            XCTFail("expected a failure")
        } catch {
            guard case UpdateError.network? = error as? UpdateError else { return XCTFail("got \(error)") }
        }
    }
}
