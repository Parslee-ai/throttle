import Foundation

/// Fake credentials for tests, assembled at runtime. The values are
/// token-shaped when the tests run, so redaction and paste-rejection tests
/// exercise the real shape, but no source file holds a token-shaped literal
/// that a secret scanner on this public repository would flag.
enum FakeToken {
    private static let anthropicPrefix = "sk-" + "ant-"

    static let anthropicAccess = anthropicPrefix + "oat01-access"
    static let anthropicRefresh = anthropicPrefix + "ort01-refresh"
    static let anthropicSecret = anthropicPrefix + "oat01-secret-value-1234567890"
    static let anthropicLeak = anthropicPrefix + "oat01-leak"
    static let anthropicSetupToken = anthropicPrefix + "oat01-abcdef"
    static let anthropicAPIKey = anthropicPrefix + "api03-abcdef"
    static let anthropicBareSecret = anthropicPrefix + "secret-value-1234567890"
}
