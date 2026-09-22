import AppKit
import Foundation

/// Installs a verified package and brings the new version up.
protocol UpdateInstalling: Sendable {
    /// Installs `package` with administrator rights. Throws `InstallCancelled`
    /// when the user dismisses the password prompt, `UpdateError.verification`
    /// when the root step refuses its copy of the package, and
    /// `UpdateError.install` for any other failure.
    func install(_ package: VerifiedPackage) async throws

    /// Starts the installed copy once this process has exited, then quits.
    /// Throws `UpdateError.relaunch` when the relauncher could not be started,
    /// in which case the app keeps running.
    @MainActor func relaunch() throws
}

/// Production installer: the standard macOS administrator prompt, through
/// `osascript` and `do shell script ... with administrator privileges`.
///
/// The root shell never trusts the file the user-level app verified. It
/// copies at most the verified size into a fresh root-owned directory, then
/// requires that copy to have exactly the verified size and SHA-256, the
/// Developer ID Installer signature of the running app's team, Apple's
/// notarization, a Distribution naming Throttle at exactly the version being
/// installed, and no install scripts. Only then does `installer` read it, so
/// nothing running as the user can swap in other bytes, another product signed
/// by the same team, or an older Throttle.
struct UpdateInstaller: UpdateInstalling {
    static let osascriptPath = "/usr/bin/osascript"
    /// Where `scripts/package.sh` installs the app, and so what gets relaunched.
    /// Not `Bundle.main.bundlePath`: a copy running from elsewhere would
    /// relaunch itself, the old version, instead of the one just installed.
    static let installedAppPath = "/Applications/Throttle.app"

    /// The exit status the root script uses for every refusal, so the app can
    /// tell "the copy failed a check" from "installer failed".
    static let refusalStatus: Int32 = 65

    /// Runs the root script with an empty environment apart from `PATH`, so no
    /// variable inherited from the user's session (for example one that loads
    /// code into `shasum`'s Perl) reaches anything running as root.
    static let rootCommandPrefix = "/usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin /bin/sh -c "

    let runner: any CommandRunning

    init(runner: any CommandRunning = ProcessCommandRunner()) {
        self.runner = runner
    }

    func install(_ package: VerifiedPackage) async throws {
        let script = try Self.appleScript(for: package)
        let result: CommandResult
        do {
            result = try await runner.run(Self.osascriptPath, ["-e", script])
        } catch {
            throw UpdateError.install("the administrator prompt could not be opened (\(error.localizedDescription))")
        }
        try Self.interpret(result)
    }

    /// Maps `osascript`'s exit to success, `InstallCancelled`, a root-side
    /// `UpdateError.verification`, or a trimmed `UpdateError.install`.
    static func interpret(_ result: CommandResult) throws {
        if result.status == 0 { return }
        let output = result.combinedOutput
        if output.contains("(-128)") || output.localizedCaseInsensitiveContains("User canceled") {
            throw InstallCancelled()
        }
        // `do shell script` ends its error with the script's exit status.
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasSuffix("(\(refusalStatus))") {
            throw UpdateError.verification(conciseFailure(output, status: result.status))
        }
        throw UpdateError.install(conciseFailure(output, status: result.status))
    }

    /// `0:312: execution error: installer: Error - ... (1)` -> `installer: Error - ...`.
    static func conciseFailure(_ output: String, status: Int32) -> String {
        var text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = text.range(of: "execution error: ") {
            text = String(text[range.upperBound...])
        }
        if let trailing = text.range(of: #"\s*\(-?[0-9]+\)$"#, options: .regularExpression) {
            text.removeSubrange(trailing)
        }
        text = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        if text.isEmpty { return "the installer exited with status \(status)" }
        return text.count > 300 ? String(text.prefix(300)) + "…" : text
    }

    // MARK: Building the script

    /// The AppleScript handed to `osascript -e`.
    static func appleScript(for package: VerifiedPackage) throws -> String {
        let shell = try rootShellScript(
            packagePath: package.url.path,
            teamID: package.teamID,
            version: package.version,
            size: package.size,
            sha256: package.sha256
        )
        let command = rootCommandPrefix + shellQuote(shell)
        let prompt = "Throttle needs an administrator password to install version \(package.version.text)."
        return "do shell script \(appleScriptStringLiteral(command)) with prompt \(appleScriptStringLiteral(prompt)) with administrator privileges"
    }

    /// The `sh` script root runs. Every pin is validated before it is
    /// embedded, and every embedded value is single-quoted.
    static func rootShellScript(
        packagePath: String,
        teamID: String,
        version: SemanticVersion,
        size: Int,
        sha256: String
    ) throws -> String {
        guard PackageVerifier.isValidTeamID(teamID) else {
            throw UpdateError.install("the developer team could not be confirmed")
        }
        guard SemanticVersion.isValid(version.text) else {
            throw UpdateError.install("the update's version number is not a plain version")
        }
        guard PackageVerifier.isValidSHA256(sha256) else {
            throw UpdateError.install("the package's checksum is not a SHA-256")
        }
        guard size > 0, size <= ReleaseFeed.maxPackageBytes else {
            throw UpdateError.install("the package size is out of range")
        }
        guard packagePath.hasPrefix("/"), !packagePath.contains("\u{0}") else {
            throw UpdateError.install("the package path is not absolute")
        }

        func refuse(_ reason: String) -> String {
            "{ echo \(shellQuote(reason)) >&2; exit \(refusalStatus); }"
        }
        let q = shellQuote
        let product = PackageVerifier.productIdentifier
        let productQuery = "count(//pkg-ref) > 0 and count(//pkg-ref[not(@id=\"\(product)\")]) = 0"
        let versionQuery = "count(//pkg-ref[@version]) = 1 and count(//pkg-ref[@id=\"\(product)\"][@version=\"\(version.text)\"]) = 1"

        return [
            "set -e",
            "src=\(q(packagePath))",
            "if [ -L \"$src\" ] || [ ! -f \"$src\" ]; then \(refuse("the downloaded package is not a regular file")); fi",
            "dir=$(/usr/bin/mktemp -d /private/tmp/throttle-update.XXXXXX)",
            "trap '/bin/rm -rf \"$dir\"' EXIT",
            "copy=\"$dir/Throttle.pkg\"",
            "/usr/bin/head -c \(size + 1) \"$src\" > \"$copy\"",
            "[ \"$(/usr/bin/stat -f %z \"$copy\")\" = \(q(String(size))) ] || \(refuse("the package copy is not the size that was verified"))",
            "sum=$(/usr/bin/shasum -a 256 \"$copy\") || \(refuse("the package copy could not be checksummed"))",
            "[ \"${sum%% *}\" = \(q(sha256)) ] || \(refuse("the package copy does not match the bytes that were verified"))",
            "sig=$(/usr/sbin/pkgutil --check-signature \"$copy\") || \(refuse("the package copy has no valid signature"))",
            "case \"$sig\" in *\(q(PackageVerifier.developerIDStatus))*) ;; *) \(refuse("the package copy is not Developer ID signed")) ;; esac",
            "leaf=$(printf '%s\\n' \"$sig\" | /usr/bin/sed -n 's/^[[:space:]]*1\\.[[:space:]]*//p' | /usr/bin/head -n 1)",
            "case \"$leaf\" in \(q(PackageVerifier.installerCertificatePrefix))*\(q(" (\(teamID))"))) ;; *) \(refuse("the package copy is not signed by the same developer as Throttle")) ;; esac",
            "gk=$(/usr/sbin/spctl --assess --type install -vv \"$copy\" 2>&1) || \(refuse("Gatekeeper rejected the package copy"))",
            "case \"$gk\" in *\(q(PackageVerifier.notarizedSource))*) ;; *) \(refuse("the package copy is not notarized")) ;; esac",
            "entries=$(/usr/bin/xar -tf \"$copy\") || \(refuse("the package copy could not be read"))",
            "if printf '%s\\n' \"$entries\" | /usr/bin/grep -q 'Scripts$'; then \(refuse("the package copy contains install scripts")); fi",
            "/usr/bin/xar -xf \"$copy\" -C \"$dir\" Distribution || \(refuse("the package copy could not be read"))",
            "isthrottle=$(/usr/bin/xmllint --nonet --xpath \(q(productQuery)) \"$dir/Distribution\") || \(refuse("the package copy's Distribution could not be read"))",
            "[ \"$isthrottle\" = 'true' ] || \(refuse("the package copy is not Throttle"))",
            "isversion=$(/usr/bin/xmllint --nonet --xpath \(q(versionQuery)) \"$dir/Distribution\") || \(refuse("the package copy's Distribution could not be read"))",
            "[ \"$isversion\" = 'true' ] || \(refuse("the package copy is not Throttle \(version.text)"))",
            "/usr/sbin/installer -pkg \"$copy\" -target / 1>&2",
        ].joined(separator: "\n")
    }

    /// Wraps `s` in single quotes for `sh`. Inside single quotes nothing is
    /// special except the closing quote, which becomes `'\''`.
    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    /// Wraps `s` in an AppleScript string literal. Only the backslash and the
    /// double quote are special there; the backslash is escaped first so the
    /// quote's escape is not itself doubled.
    static func appleScriptStringLiteral(_ s: String) -> String {
        let escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"" + escaped + "\""
    }

    // MARK: After the install

    /// The relauncher: a detached `sh` that waits for `$1` (this process) to
    /// exit, then opens `$2`. Both arrive as positional parameters, never
    /// interpolated into the script text.
    static let relaunchScript = #"while /bin/kill -0 "$1" 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open "$2""#

    static func relaunchArguments(pid: Int32) -> [String] {
        ["-c", relaunchScript, "sh", String(pid), installedAppPath]
    }

    @MainActor
    func relaunch() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = Self.relaunchArguments(pid: ProcessInfo.processInfo.processIdentifier)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw UpdateError.relaunch(error.localizedDescription)
        }
        NSApplication.shared.terminate(nil)
    }
}
