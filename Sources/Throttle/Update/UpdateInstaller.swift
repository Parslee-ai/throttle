import AppKit
import Foundation

/// Installs a verified package and brings the new version up.
protocol UpdateInstalling: Sendable {
    /// Installs the package at `url` with administrator rights. Throws
    /// `InstallCancelled` when the user dismisses the password prompt and
    /// `UpdateError.install` for any other failure.
    func install(packageAt url: URL, version: SemanticVersion, teamID: String) async throws

    /// Starts the installed copy once this process has exited, then quits.
    /// Throws `UpdateError.relaunch` when the relauncher could not be started,
    /// in which case the app keeps running.
    @MainActor func relaunch() throws

    /// Opens the package in Installer so the user can finish by hand.
    @MainActor func openInInstaller(_ url: URL)
}

/// Production installer: the standard macOS administrator prompt, through
/// `osascript` and `do shell script ... with administrator privileges`.
///
/// The root shell never trusts the file the user-level app verified. It copies
/// the package into a fresh root-owned directory and verifies that copy again
/// before `installer` reads it, so nothing running as the user can swap the
/// file between Throttle's check and root's install.
struct UpdateInstaller: UpdateInstalling {
    static let osascriptPath = "/usr/bin/osascript"
    /// Where `scripts/package.sh` installs the app, and so what gets relaunched.
    /// Not `Bundle.main.bundlePath`: a copy running from elsewhere would
    /// relaunch itself, the old version, instead of the one just installed.
    static let installedAppPath = "/Applications/Throttle.app"

    let runner: any CommandRunning

    init(runner: any CommandRunning = ProcessCommandRunner()) {
        self.runner = runner
    }

    func install(packageAt url: URL, version: SemanticVersion, teamID: String) async throws {
        let script = try Self.appleScript(packagePath: url.path, version: version, teamID: teamID)
        let result: CommandResult
        do {
            result = try await runner.run(Self.osascriptPath, ["-e", script])
        } catch {
            throw UpdateError.install("the administrator prompt could not be opened (\(error.localizedDescription))")
        }
        try Self.interpret(result)
    }

    /// Maps `osascript`'s exit to success, `InstallCancelled`, or a trimmed
    /// `UpdateError.install`.
    static func interpret(_ result: CommandResult) throws {
        if result.status == 0 { return }
        let output = result.combinedOutput
        if output.contains("(-128)") || output.localizedCaseInsensitiveContains("User canceled") {
            throw InstallCancelled()
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
    static func appleScript(packagePath: String, version: SemanticVersion, teamID: String) throws -> String {
        guard SemanticVersion.isValid(version.text) else {
            throw UpdateError.install("the update's version number is not a plain version")
        }
        let shell = try rootShellScript(packagePath: packagePath, teamID: teamID)
        let prompt = "Throttle needs an administrator password to install version \(version.text)."
        return "do shell script \(appleScriptStringLiteral(shell)) with prompt \(appleScriptStringLiteral(prompt)) with administrator privileges"
    }

    /// The `sh` script root runs. Every path is single-quoted; the team is
    /// validated before it is embedded; the package is re-verified as a
    /// root-owned copy before `installer` sees it.
    static func rootShellScript(packagePath: String, teamID: String) throws -> String {
        guard PackageVerifier.isValidTeamID(teamID) else {
            throw UpdateError.install("the developer team could not be confirmed")
        }
        guard packagePath.hasPrefix("/"), !packagePath.contains("\u{0}") else {
            throw UpdateError.install("the package path is not absolute")
        }
        let pkg = shellQuote(packagePath)
        let status = shellQuote(PackageVerifier.developerIDStatus)
        let leafPrefix = shellQuote(PackageVerifier.installerCertificatePrefix)
        let team = shellQuote("(\(teamID))")
        let notarized = shellQuote(PackageVerifier.notarizedSource)
        return [
            "set -e",
            "dir=$(/usr/bin/mktemp -d /private/tmp/throttle-update.XXXXXX)",
            "trap '/bin/rm -rf \"$dir\"' EXIT",
            "copy=\"$dir/Throttle.pkg\"",
            "/bin/cp \(pkg) \"$copy\"",
            "sig=$(/usr/sbin/pkgutil --check-signature \"$copy\") || { echo 'The package copy has no valid signature.' >&2; exit 65; }",
            "case \"$sig\" in *\(status)*) ;; *) echo 'The package copy is not Developer ID signed.' >&2; exit 65 ;; esac",
            "leaf=$(printf '%s\\n' \"$sig\" | /usr/bin/sed -n 's/^[[:space:]]*1\\.[[:space:]]*//p' | /usr/bin/head -n 1)",
            "case \"$leaf\" in \(leafPrefix)*\(team)*) ;; *) echo 'The package copy is not signed by the same developer as Throttle.' >&2; exit 65 ;; esac",
            "gk=$(/usr/sbin/spctl --assess --type install -vv \"$copy\" 2>&1) || { echo 'Gatekeeper rejected the package copy.' >&2; exit 65; }",
            "case \"$gk\" in *\(notarized)*) ;; *) echo 'The package copy is not notarized.' >&2; exit 65 ;; esac",
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

    @MainActor
    func openInInstaller(_ url: URL) {
        NSWorkspace.shared.open(url)
    }
}
