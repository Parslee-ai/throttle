import XCTest
@testable import Throttle

final class SemanticVersionTests: XCTestCase {
    private func v(_ s: String, file: StaticString = #filePath, line: UInt = #line) -> SemanticVersion {
        guard let version = SemanticVersion(s) else {
            XCTFail("\(s) should parse", file: file, line: line)
            return SemanticVersion("0.0.0")!
        }
        return version
    }

    func testParsesReleaseAndPrerelease() {
        let release = v("0.1.0")
        XCTAssertEqual([release.major, release.minor, release.patch], [0, 1, 0])
        XCTAssertEqual(release.prerelease, [])
        XCTAssertFalse(release.isPrerelease)
        XCTAssertEqual(release.text, "0.1.0")

        let candidate = v("0.1.0-rc.9")
        XCTAssertEqual(candidate.prerelease, ["rc", "9"])
        XCTAssertTrue(candidate.isPrerelease)
        XCTAssertEqual(candidate.description, "0.1.0-rc.9")
    }

    func testToleratesALeadingV() {
        XCTAssertEqual(v("v0.1.0"), v("0.1.0"))
        XCTAssertEqual(v("v0.1.0").text, "0.1.0", "the v is not part of the version text")
        XCTAssertEqual(v("v1.2.3-beta.2").text, "1.2.3-beta.2")
    }

    func testReleaseOrdering() {
        let chain = ["0.1.0-rc.9", "0.1.0", "0.1.1", "0.2.0", "1.0.0", "1.10.0", "2.0.0"].map { v($0) }
        for (lower, higher) in zip(chain, chain.dropFirst()) {
            XCTAssertLessThan(lower, higher, "\(lower) < \(higher)")
            XCTAssertGreaterThan(higher, lower)
        }
    }

    /// The precedence example from the SemVer 2.0 specification, section 11.
    func testSpecificationPrereleaseOrdering() {
        let chain = [
            "1.0.0-alpha", "1.0.0-alpha.1", "1.0.0-alpha.beta", "1.0.0-beta",
            "1.0.0-beta.2", "1.0.0-beta.11", "1.0.0-rc.1", "1.0.0",
        ].map { v($0) }
        for (lower, higher) in zip(chain, chain.dropFirst()) {
            XCTAssertLessThan(lower, higher, "\(lower) < \(higher)")
        }
    }

    func testNumericIdentifiersCompareNumerically() {
        XCTAssertLessThan(v("0.1.0-rc.9"), v("0.1.0-rc.10"))
        XCTAssertLessThan(v("0.1.0-rc.2"), v("0.1.0-rc.10"))
        XCTAssertLessThan(v("1.0.0-1"), v("1.0.0-alpha"), "numeric ranks below alphanumeric")
        XCTAssertLessThan(v("1.0.0-rc.99999999999999999999"), v("1.0.0-rc.100000000000000000000"),
                          "identifiers longer than Int still order")
    }

    func testFewerPrereleaseFieldsIsLower() {
        XCTAssertLessThan(v("1.0.0-rc"), v("1.0.0-rc.1"))
        XCTAssertLessThan(v("1.0.0-alpha.1"), v("1.0.0-alpha.1.1"))
    }

    func testEqualIsNotNewer() {
        XCTAssertEqual(v("0.1.0"), v("v0.1.0"))
        XCTAssertFalse(v("0.1.0") > v("0.1.0"))
        XCTAssertFalse(v("0.1.0") < v("0.1.0"))
        XCTAssertEqual(v("0.1.0-rc.9"), v("0.1.0-rc.9"))
        XCTAssertEqual(Set([v("0.1.0"), v("v0.1.0")]).count, 1, "hash agrees with ==")
    }

    func testGarbageIsRejected() {
        let garbage = [
            "", "v", "1", "1.2", "1.2.3.4", "a.b.c", "1.2.x", "1.2.3-", "1.2.3-rc..1",
            "1.2.3+build.5", " 1.2.3", "1.2.3 ", "1.2.3\n", "\n1.2.3", "vv1.2.3", "V1.2.3",
            "1.2.3-rc;rm", "../1.2.3", "1.2.3/..", "1.2.3-rc/1", "１.2.3", "1.2.3-ß",
            "99999999999999999999.0.0", "0.2.0';rm -rf ~;'", "-1.2.3",
        ]
        for text in garbage {
            XCTAssertNil(SemanticVersion(text), "\(text.debugDescription) should be rejected")
        }
    }

    func testValidationPatternMatchesWholeString() {
        XCTAssertTrue(SemanticVersion.isValid("0.1.0"))
        XCTAssertTrue(SemanticVersion.isValid("0.1.0-rc.9"))
        XCTAssertFalse(SemanticVersion.isValid("v0.1.0"), "the pattern itself has no v")
        XCTAssertFalse(SemanticVersion.isValid("0.1.0\n"), "a trailing newline cannot slip past $")
        XCTAssertFalse(SemanticVersion.isValid("0.1.0\nrm -rf ~"))
        XCTAssertFalse(SemanticVersion.isValid("0.1.0-rc.1'"))
    }
}
