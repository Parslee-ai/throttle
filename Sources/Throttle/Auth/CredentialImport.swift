import Foundation
import Security

/// A credential found in another tool's login that the user may copy into
/// Throttle.
struct ImportCandidate: Sendable {
    let provider: Provider
    /// What the import row shows: the email when the source carries one, else
    /// the source tool's name and plan.
    let label: String
    let credential: AccountCredential
}

/// Reads the Claude Code and Codex CLI logins so the user can add an account
/// without a second browser sign-in (ISC-69, ISC-86).
///
/// This is a convenience, and a copy, never a move. Both readers run only
/// when the user clicks Import (ISC-137); nothing here is called at launch or
/// from the poll loop. Nothing here writes: not to the Claude Code Keychain
/// item, not to `auth.json` (ISC-87). The copied credential goes into
/// Throttle's own Keychain item and refreshes on its own from then on.
///
/// Caveat, and the reason this is not the primary path (D-17): the source
/// tool keeps rotating its own refresh token. Claude Code files a new
/// Keychain item on every rotation, and the Codex CLI rewrites `auth.json`.
/// Once both sides have refreshed, the two copies share nothing, and if the
/// provider invalidates a refresh token family on rotation the imported copy
/// can stop working before Throttle's own next refresh. The remedy is a
/// normal browser login, which the account row offers when it needs one.
enum CredentialImport {
    /// The Keychain service Claude Code stores its OAuth blob under. Newer
    /// builds append `-<8 hex>` derived from the user's home directory.
    static let claudeCodeService = "Claude Code-credentials"

    /// The Codex CLI config directory, overridable with `CODEX_HOME`.
    static let codexAuthFileName = "auth.json"

    // MARK: Claude Code

    /// Every Claude Code login found in the login Keychain. The exact service
    /// name is queried directly; the hashed variants are found by listing
    /// generic-password attributes (which needs no access approval) and
    /// filtering by prefix, then reading each match's data (which the user
    /// approves in the Keychain prompt).
    static func claudeCodeCandidates() -> [ImportCandidate] {
        var candidates: [ImportCandidate] = []
        var seen: Set<String> = []

        if let data = keychainData(service: claudeCodeService, account: nil),
           let candidate = claudeCodeCandidate(from: data, service: claudeCodeService) {
            candidates.append(candidate)
            seen.insert(claudeCodeService)
        }

        for (service, account) in claudeCodeServices() where !seen.contains(service) {
            seen.insert(service)
            if let data = keychainData(service: service, account: account),
               let candidate = claudeCodeCandidate(from: data, service: service) {
                candidates.append(candidate)
            }
        }
        return candidates
    }

    /// Parses Claude Code's `claudeAiOauth` blob. Returns `nil` for anything
    /// that does not carry an access token.
    static func parseClaudeCodeBlob(_ data: Data) -> (credential: AccountCredential, subscriptionType: String?)? {
        guard let json = try? JSONSerialization.jsonObject(with: data),
              let root = json as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let accessToken = oauth["accessToken"] as? String, !accessToken.isEmpty else {
            return nil
        }
        var expiresAt: Date?
        if let milliseconds = oauth["expiresAt"] as? NSNumber {
            expiresAt = Date(timeIntervalSince1970: milliseconds.doubleValue / 1000)
        }
        let scopes = (oauth["scopes"] as? [String]) ?? []
        let credential = AccountCredential(
            accessToken: accessToken,
            refreshToken: oauth["refreshToken"] as? String,
            expiresAt: expiresAt,
            accountID: nil,
            scopes: scopes
        )
        return (credential, oauth["subscriptionType"] as? String)
    }

    private static func claudeCodeCandidate(from data: Data, service: String) -> ImportCandidate? {
        guard let parsed = parseClaudeCodeBlob(data) else { return nil }
        var label = "Claude Code login"
        if let plan = parsed.subscriptionType, !plan.isEmpty {
            label += " (\(plan))"
        }
        return ImportCandidate(provider: .anthropic, label: label, credential: parsed.credential)
    }

    /// Whether a service name is `Claude Code-credentials-<8 hex>`.
    static func isHashedClaudeCodeService(_ service: String) -> Bool {
        let prefix = claudeCodeService + "-"
        guard service.hasPrefix(prefix) else { return false }
        let suffix = service.dropFirst(prefix.count)
        return suffix.count == 8 && suffix.allSatisfy { $0.isHexDigit }
    }

    /// `(service, account)` of every hashed-variant item, by attribute listing.
    private static func claudeCodeServices() -> [(String, String?)] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: kCFBooleanTrue!,
            kSecUseDataProtectionKeychain as String: kCFBooleanFalse!,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else {
            return []
        }
        return items.compactMap { attributes in
            guard let service = attributes[kSecAttrService as String] as? String,
                  isHashedClaudeCodeService(service) else { return nil }
            return (service, attributes[kSecAttrAccount as String] as? String)
        }
    }

    private static func keychainData(service: String, account: String?) -> Data? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: kCFBooleanTrue!,
            kSecUseDataProtectionKeychain as String: kCFBooleanFalse!,
        ]
        if let account {
            query[kSecAttrAccount as String] = account
        }
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else {
            return nil
        }
        return result as? Data
    }

    // MARK: Codex CLI

    /// The Codex CLI login, if `auth.json` exists and holds ChatGPT tokens.
    /// `environment` and `home` are injectable so tests never read the real
    /// file.
    static func codexCandidates(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [ImportCandidate] {
        let file = codexAuthFile(environment: environment, home: home)
        guard let data = try? Data(contentsOf: file),
              let candidate = parseCodexAuth(data) else {
            return []
        }
        return [candidate]
    }

    /// `$CODEX_HOME/auth.json` when `CODEX_HOME` is set, else `~/.codex/auth.json`.
    static func codexAuthFile(environment: [String: String], home: URL) -> URL {
        if let codexHome = environment["CODEX_HOME"], !codexHome.isEmpty {
            return URL(fileURLWithPath: (codexHome as NSString).expandingTildeInPath, isDirectory: true)
                .appendingPathComponent(codexAuthFileName)
        }
        return home.appendingPathComponent(".codex", isDirectory: true).appendingPathComponent(codexAuthFileName)
    }

    /// Parses the `tokens` object of `auth.json`. The account id comes from
    /// `tokens.account_id`, falling back to the `id_token` claim; the email
    /// and plan come from the `id_token`.
    static func parseCodexAuth(_ data: Data) -> ImportCandidate? {
        guard let json = try? JSONSerialization.jsonObject(with: data),
              let root = json as? [String: Any],
              let tokens = root["tokens"] as? [String: Any],
              let accessToken = tokens["access_token"] as? String, !accessToken.isEmpty else {
            return nil
        }
        let idClaims = (tokens["id_token"] as? String).flatMap(JWTClaims.decode)
        let accessClaims = JWTClaims.decode(accessToken)
        let accountID = (tokens["account_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? idClaims?.chatgptAccountID
            ?? accessClaims?.chatgptAccountID
        guard let accountID else { return nil }

        let credential = AccountCredential(
            accessToken: accessToken,
            refreshToken: tokens["refresh_token"] as? String,
            expiresAt: accessClaims?.exp,
            accountID: accountID,
            scopes: OpenAIEndpoints.scopes
        )
        var label = idClaims?.email ?? accessClaims?.email ?? "Codex CLI login"
        if let plan = idClaims?.chatgptPlanType ?? accessClaims?.chatgptPlanType, !plan.isEmpty {
            label += " (\(plan))"
        }
        return ImportCandidate(provider: .openai, label: label, credential: credential)
    }
}
