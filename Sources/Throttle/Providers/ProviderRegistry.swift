import Foundation

/// The one place that knows which concrete adapter, login flow, and import
/// source belong to each `Provider` case.
///
/// `App/` and `UI/` ask the registry by case and never name an adapter, so a
/// third provider is added here and in `Providers/` only (ISC-39, ISC-41).
struct ProviderRegistry: Sendable {
    private let anthropic: AnthropicProvider
    private let openAI: OpenAIProvider

    init(client: HTTPClient = URLSessionHTTPClient()) {
        anthropic = AnthropicProvider(client: client)
        openAI = OpenAIProvider(client: client)
    }

    /// The usage adapter for a provider.
    func usageProvider(for provider: Provider) -> any UsageProvider {
        switch provider {
        case .anthropic: return anthropic
        case .openai: return openAI
        }
    }

    /// Every adapter keyed by case, for the poll scheduler.
    var usageProviders: [Provider: any UsageProvider] {
        Dictionary(uniqueKeysWithValues: Provider.allCases.map { ($0, usageProvider(for: $0)) })
    }

    /// The browser login flow for a provider.
    func login(for provider: Provider, client: HTTPClient) -> any OAuthLogin {
        switch provider {
        case .anthropic: return AnthropicLogin(client: client, provider: anthropic)
        case .openai: return OpenAILogin(client: client, provider: openAI)
        }
    }

    /// Whether the provider's import source could exist on this Mac. A
    /// file-existence check at most; nothing is read until the user imports
    /// (ISC-137). The Claude Code source lives in the Keychain, where checking
    /// is the same as reading, so it is always offered.
    func importSourceExists(for provider: Provider) -> Bool {
        switch provider {
        case .anthropic:
            return true
        case .openai:
            let file = CredentialImport.codexAuthFile(
                environment: ProcessInfo.processInfo.environment,
                home: FileManager.default.homeDirectoryForCurrentUser
            )
            return FileManager.default.fileExists(atPath: file.path)
        }
    }

    /// Reads the other tool's login now. Called only from the import action.
    func importCandidates(for provider: Provider) -> [ImportCandidate] {
        switch provider {
        case .anthropic: return CredentialImport.claudeCodeCandidates()
        case .openai: return CredentialImport.codexCandidates()
        }
    }
}
