import XCTest
@testable import Throttle

final class CredentialImportTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ThrottleImportTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: Claude Code blob

    func testParsesClaudeCodeBlob() throws {
        let blob = """
        {"claudeAiOauth":{"accessToken":"sk-ant-oat01-x","refreshToken":"sk-ant-ort01-y",\
        "expiresAt":1800000000000,"scopes":["user:inference","user:profile"],"subscriptionType":"max"}}
        """
        let parsed = try XCTUnwrap(CredentialImport.parseClaudeCodeBlob(Data(blob.utf8)))
        XCTAssertEqual(parsed.credential.accessToken, "sk-ant-oat01-x")
        XCTAssertEqual(parsed.credential.refreshToken, "sk-ant-ort01-y")
        XCTAssertEqual(parsed.credential.expiresAt, Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertEqual(parsed.credential.scopes, ["user:inference", "user:profile"])
        XCTAssertNil(parsed.credential.accountID)
        XCTAssertEqual(parsed.subscriptionType, "max")
    }

    func testRejectsBlobWithoutAccessToken() {
        XCTAssertNil(CredentialImport.parseClaudeCodeBlob(Data(#"{"claudeAiOauth":{"refreshToken":"r"}}"#.utf8)))
        XCTAssertNil(CredentialImport.parseClaudeCodeBlob(Data("not json".utf8)))
    }

    func testHashedServiceNameMatching() {
        XCTAssertTrue(CredentialImport.isHashedClaudeCodeService("Claude Code-credentials-1a2b3c4d"))
        XCTAssertFalse(CredentialImport.isHashedClaudeCodeService("Claude Code-credentials"))
        XCTAssertFalse(CredentialImport.isHashedClaudeCodeService("Claude Code-credentials-1a2b3c"))
        XCTAssertFalse(CredentialImport.isHashedClaudeCodeService("Claude Code-credentials-zzzzzzzz"))
        XCTAssertFalse(CredentialImport.isHashedClaudeCodeService("ai.parslee.throttle"))
    }

    // MARK: Codex auth.json

    private func writeAuth(_ json: String, in home: URL) throws -> URL {
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let file = home.appendingPathComponent("auth.json")
        try Data(json.utf8).write(to: file)
        return file
    }

    private func authJSON(idToken: String, accountID: String? = "acct_from_file") -> String {
        var tokens: [String: Any] = ["id_token": idToken, "access_token": AuthTestSupport.unsignedJWT(["exp": 1_800_003_600]), "refresh_token": "rt"]
        if let accountID { tokens["account_id"] = accountID }
        let root: [String: Any] = ["auth_mode": "chatgpt", "OPENAI_API_KEY": NSNull(), "tokens": tokens, "last_refresh": "2026-01-01T00:00:00Z"]
        return String(decoding: try! JSONSerialization.data(withJSONObject: root), as: UTF8.self)
    }

    private var idToken: String {
        AuthTestSupport.unsignedJWT([
            "email": "codex@example.com",
            "https://api.openai.com/auth": ["chatgpt_account_id": "acct_from_jwt", "chatgpt_plan_type": "pro"],
        ])
    }

    func testReadsCodexHomeWhenSet() throws {
        let codexHome = directory.appendingPathComponent("custom-codex")
        let written = authJSON(idToken: idToken)
        let file = try writeAuth(written, in: codexHome)
        let before = try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date

        let candidates = CredentialImport.codexCandidates(environment: ["CODEX_HOME": codexHome.path], home: directory)
        XCTAssertEqual(candidates.count, 1)
        let candidate = try XCTUnwrap(candidates.first)
        XCTAssertEqual(candidate.provider, .openai)
        XCTAssertEqual(candidate.label, "codex@example.com (pro)")
        XCTAssertEqual(candidate.credential.accountID, "acct_from_file", "tokens.account_id wins over the JWT claim")
        XCTAssertEqual(candidate.credential.refreshToken, "rt")
        XCTAssertEqual(candidate.credential.expiresAt, Date(timeIntervalSince1970: 1_800_003_600))
        XCTAssertEqual(candidate.credential.scopes, OpenAIEndpoints.scopes)

        // ISC-87: reading never touches the file.
        let after = try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date
        XCTAssertEqual(before, after)
        XCTAssertEqual(try Data(contentsOf: file), Data(written.utf8))
    }

    func testFallsBackToDotCodexUnderHome() throws {
        _ = try writeAuth(authJSON(idToken: idToken, accountID: nil), in: directory.appendingPathComponent(".codex"))
        let candidates = CredentialImport.codexCandidates(environment: [:], home: directory)
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates.first?.credential.accountID, "acct_from_jwt", "falls back to the id_token claim")
    }

    func testMissingFileYieldsNoCandidates() {
        XCTAssertTrue(CredentialImport.codexCandidates(environment: [:], home: directory).isEmpty)
        XCTAssertTrue(CredentialImport.codexCandidates(environment: ["CODEX_HOME": directory.appendingPathComponent("nope").path], home: directory).isEmpty)
    }

    func testAPIKeyOnlyAuthFileIsSkipped() throws {
        _ = try writeAuth(#"{"auth_mode":"apikey","OPENAI_API_KEY":"sk-x","tokens":null}"#, in: directory.appendingPathComponent(".codex"))
        XCTAssertTrue(CredentialImport.codexCandidates(environment: [:], home: directory).isEmpty)
    }

    func testCodexPathResolution() {
        let home = URL(fileURLWithPath: "/Users/example")
        XCTAssertEqual(CredentialImport.codexAuthFile(environment: [:], home: home).path, "/Users/example/.codex/auth.json")
        XCTAssertEqual(CredentialImport.codexAuthFile(environment: ["CODEX_HOME": "/opt/codex"], home: home).path, "/opt/codex/auth.json")
        XCTAssertEqual(CredentialImport.codexAuthFile(environment: ["CODEX_HOME": ""], home: home).path, "/Users/example/.codex/auth.json")
    }
}
