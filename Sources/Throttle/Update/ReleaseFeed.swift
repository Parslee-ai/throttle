import Foundation

/// One downloadable file attached to a release, already pinned: its name and
/// URL are exactly the ones `scripts/release.sh` publishes for its version.
struct ReleaseAsset: Equatable, Sendable {
    let name: String
    let downloadURL: URL
    /// The byte count the release listing reports. The download must match it.
    let size: Int
    /// The lowercase hex SHA-256 GitHub reports for the asset (its `digest`
    /// field), when the listing carries one. The download must match it.
    let sha256: String?
}

/// A published, installable release.
struct AvailableRelease: Equatable, Sendable {
    let version: SemanticVersion
    let asset: ReleaseAsset
}

/// The answer to "is there anything newer than what is running?".
enum UpdateCheckResult: Equatable, Sendable {
    case upToDate
    case available(AvailableRelease)
}

/// Reads the newest published release of Throttle from the project's own
/// GitHub Releases, and refuses anything that does not look exactly like what
/// `scripts/release.sh` publishes.
///
/// It is called only when the user clicks Check for Updates. The request
/// carries no credentials and no cookies.
struct ReleaseFeed: Sendable {
    /// `GET /repos/{owner}/{repo}/releases/latest` returns the newest release
    /// that is neither a draft nor a prerelease.
    static let latestReleaseURL = URL(string: "https://api.github.com/repos/Parslee-ai/throttle/releases/latest")!

    /// Largest release listing read into memory. A real one is a few KB.
    static let maxFeedBytes = 1024 * 1024
    /// Largest package the updater will accept. A real one is under 2 MB.
    static let maxPackageBytes = 200 * 1024 * 1024

    /// GitHub's asset digest: `sha256:` and 64 lowercase hex digits.
    static let digestPattern = #"^sha256:[0-9a-f]{64}$"#

    let client: any HTTPClient
    /// Sent as `User-Agent: Throttle/<version>`, which GitHub's API requires.
    let currentVersion: SemanticVersion

    /// The only URL a release's package may be downloaded from. Built from a
    /// version that has already passed `SemanticVersion.validationPattern`.
    static func expectedDownloadURL(for version: SemanticVersion) -> URL? {
        URL(string: "https://github.com/Parslee-ai/throttle/releases/download/v\(version.text)/\(packageName(for: version))")
    }

    static func packageName(for version: SemanticVersion) -> String {
        "Throttle-\(version.text).pkg"
    }

    /// Fetches the newest release and compares it with `currentVersion`.
    func check() async throws -> UpdateCheckResult {
        let release = try await latestRelease()
        return release.version > currentVersion ? .available(release) : .upToDate
    }

    /// Fetches and pins the newest release.
    func latestRelease() async throws -> AvailableRelease {
        var request = URLRequest(url: Self.latestReleaseURL)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Throttle/\(currentVersion.text)", forHTTPHeaderField: "User-Agent")

        let response: HTTPResponse
        do {
            response = try await client.send(request, maxBodyBytes: Self.maxFeedBytes)
        } catch UsageError.tooLarge {
            throw UpdateError.unreadableFeed("the response was unexpectedly large")
        } catch UsageError.transport(let underlying) {
            throw UpdateError.network(underlying.localizedDescription)
        } catch {
            throw UpdateError.network(error.localizedDescription)
        }

        switch response.statusCode {
        case 200:
            return try Self.parse(response.body)
        case 404:
            throw UpdateError.noInstallableUpdate("No release of Throttle has been published yet.")
        case 403, 429:
            if let retryAt = Self.rateLimitRetryDate(response) {
                throw UpdateError.rateLimited(retryAt: retryAt)
            }
            if response.statusCode == 429 || response.header("x-ratelimit-remaining") == "0" {
                throw UpdateError.rateLimited(retryAt: nil)
            }
            throw UpdateError.server(status: response.statusCode)
        default:
            throw UpdateError.server(status: response.statusCode)
        }
    }

    /// When GitHub says the caller may try again: `Retry-After` seconds for a
    /// secondary limit, or the `x-ratelimit-reset` epoch once the primary
    /// allowance is spent. `nil` when the response carries neither.
    static func rateLimitRetryDate(_ response: HTTPResponse, now: Date = Date()) -> Date? {
        if let text = response.header("retry-after"), let seconds = TimeInterval(text.trimmingCharacters(in: .whitespaces)), seconds >= 0 {
            return now.addingTimeInterval(seconds)
        }
        if response.header("x-ratelimit-remaining") == "0",
           let text = response.header("x-ratelimit-reset"),
           let epoch = TimeInterval(text.trimmingCharacters(in: .whitespaces)) {
            return Date(timeIntervalSince1970: epoch)
        }
        return nil
    }

    // MARK: Parsing and pinning

    private struct Payload: Decodable {
        let tag_name: String
        let draft: Bool
        let prerelease: Bool
        let assets: [Asset]

        struct Asset: Decodable {
            let name: String
            let browser_download_url: String
            let size: Int
            let digest: String?
        }
    }

    /// Decodes a release listing and accepts it only if every field names
    /// exactly what `scripts/release.sh` publishes: a published, non-draft,
    /// non-prerelease release tagged `v<version>` with a plain version number,
    /// carrying `Throttle-<version>.pkg` at its canonical download URL, with a
    /// well-formed SHA-256 digest when GitHub lists one.
    static func parse(_ data: Data) throws -> AvailableRelease {
        let payload: Payload
        do {
            payload = try JSONDecoder().decode(Payload.self, from: data)
        } catch {
            throw UpdateError.unreadableFeed("unexpected format")
        }

        if payload.draft {
            throw UpdateError.noInstallableUpdate("The newest release is still a draft, so there is nothing to install yet.")
        }
        if payload.prerelease {
            throw UpdateError.noInstallableUpdate("The newest release is a pre-release, which Throttle doesn't install automatically.")
        }

        let tag = payload.tag_name
        guard tag.hasPrefix("v"), SemanticVersion.isValid(String(tag.dropFirst())),
              let version = SemanticVersion(tag) else {
            throw UpdateError.noInstallableUpdate("The newest release isn't tagged with a plain version number, so Throttle won't install it.")
        }

        let expectedName = packageName(for: version)
        guard let expectedURL = expectedDownloadURL(for: version) else {
            throw UpdateError.noInstallableUpdate("Throttle couldn't build the download address for \(version.text).")
        }
        guard let asset = payload.assets.first(where: { $0.name == expectedName }) else {
            throw UpdateError.noInstallableUpdate("Release \(version.text) has no \(expectedName) installer package attached.")
        }
        guard asset.browser_download_url == expectedURL.absoluteString,
              let url = URL(string: asset.browser_download_url),
              url.scheme == "https", url.host == "github.com" else {
            throw UpdateError.noInstallableUpdate("Release \(version.text)'s installer package isn't at the expected download address, so Throttle won't install it.")
        }
        guard asset.size > 0, asset.size <= maxPackageBytes else {
            throw UpdateError.noInstallableUpdate("Release \(version.text)'s installer package has an implausible size, so Throttle won't install it.")
        }
        // A listing without a digest is still installable: the app hashes the
        // download itself and root re-checks that hash. A digest in any other
        // shape than GitHub's is refused rather than ignored.
        var sha256: String?
        if let digest = asset.digest {
            guard WholeMatch.matches(digestPattern, digest) else {
                throw UpdateError.noInstallableUpdate("Release \(version.text)'s installer package has a checksum Throttle can't read, so Throttle won't install it.")
            }
            sha256 = String(digest.dropFirst("sha256:".count))
        }
        return AvailableRelease(
            version: version,
            asset: ReleaseAsset(name: asset.name, downloadURL: url, size: asset.size, sha256: sha256)
        )
    }
}
