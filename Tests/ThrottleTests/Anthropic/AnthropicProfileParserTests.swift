import XCTest
@testable import Throttle

/// The plan under a Claude account comes from the profile's organization
/// type and rate-limit tier, never from the organization's name.
final class AnthropicProfileParserTests: XCTestCase {
    func testCapturedProfileYieldsMax20x() throws {
        let profile = try XCTUnwrap(AnthropicProfileParser.parse(try AnthropicFixtures.data("anthropic-profile")))
        XCTAssertEqual(profile.email, "redacted@example.com")
        XCTAssertEqual(profile.planLabel, "max 20x")
        XCTAssertFalse(profile.planLabel?.contains("Organization") ?? true)
    }

    func testDerivation() {
        XCTAssertEqual(AnthropicProfileParser.planLabel(organizationType: "claude_max", rateLimitTier: "default_claude_max_20x"), "max 20x")
        XCTAssertEqual(AnthropicProfileParser.planLabel(organizationType: "claude_max", rateLimitTier: "default_claude_max_5x"), "max 5x")
        XCTAssertEqual(AnthropicProfileParser.planLabel(organizationType: "claude_pro", rateLimitTier: nil), "pro")
        XCTAssertEqual(AnthropicProfileParser.planLabel(organizationType: "claude_pro", rateLimitTier: "default_claude_ai"), "pro")
        XCTAssertEqual(AnthropicProfileParser.planLabel(organizationType: "claude_team", rateLimitTier: nil), "team")
        XCTAssertEqual(AnthropicProfileParser.planLabel(organizationType: "claude_enterprise", rateLimitTier: nil), "enterprise")
        // An unknown type passes through the same way.
        XCTAssertEqual(AnthropicProfileParser.planLabel(organizationType: "claude_studio_plus", rateLimitTier: "tier_3x"), "studio_plus 3x")
        XCTAssertEqual(AnthropicProfileParser.planLabel(organizationType: "education", rateLimitTier: nil), "education")
        // No type: no plan, whatever else the profile says.
        XCTAssertNil(AnthropicProfileParser.planLabel(organizationType: nil, rateLimitTier: "default_claude_max_20x"))
        XCTAssertNil(AnthropicProfileParser.planLabel(organizationType: "", rateLimitTier: nil))
        XCTAssertNil(AnthropicProfileParser.planLabel(organizationType: "claude_", rateLimitTier: nil))
        // A multiplier already on the type is not repeated.
        XCTAssertEqual(AnthropicProfileParser.planLabel(organizationType: "claude_max_20x", rateLimitTier: "default_claude_max_20x"), "max_20x")
    }

    func testMissingTypeIsNilAndNeverTheOrganizationName() throws {
        let body = #"{"account":{"email":"a@example.com"},"organization":{"name":"a@example.com's Organization","rate_limit_tier":"default_claude_max_20x"}}"#
        let profile = try XCTUnwrap(AnthropicProfileParser.parse(Data(body.utf8)))
        XCTAssertNil(profile.planLabel)
        XCTAssertEqual(profile.email, "a@example.com")
    }

    func testNotAnObjectIsNil() {
        XCTAssertNil(AnthropicProfileParser.parse(Data("[]".utf8)))
        XCTAssertNil(AnthropicProfileParser.parse(Data("<html>".utf8)))
    }
}
