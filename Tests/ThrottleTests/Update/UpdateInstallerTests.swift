import XCTest
@testable import Throttle

final class UpdateInstallerTests: XCTestCase {
    private let team = UpdateFixtures.team
    private let version = SemanticVersion("0.2.0")!

    /// Inputs that break naive quoting in `sh`, in AppleScript, or both.
    private let hostileInputs = [
        "plain",
        "it's",
        "''",
        #"say "hi""#,
        "$(rm -rf ~)",
        "${HOME}",
        "`id`",
        "back\\slash",
        #"\"\\"#,
        "line\nbreak",
        "carriage\rreturn",
        "tab\there",
        "semi;colon && pipe | amp &",
        "*?[glob]",
        "ünïcødé ☃",
        #"'"'"$(`\`)"'"#,
    ]

    // MARK: sh quoting

    func testShellQuoteShape() {
        XCTAssertEqual(UpdateInstaller.shellQuote("abc"), "'abc'")
        XCTAssertEqual(UpdateInstaller.shellQuote("it's"), #"'it'\''s'"#)
        XCTAssertEqual(UpdateInstaller.shellQuote(""), "''")
        XCTAssertEqual(UpdateInstaller.shellQuote("$(id)"), "'$(id)'")
    }

    /// The real `sh` reads each quoted word back as exactly the original text.
    /// Only `printf` runs; nothing in the input is ever executed.
    func testShellQuoteRoundTripsThroughARealShell() throws {
        for input in hostileInputs {
            let output = try runShell("printf '%s' \(UpdateInstaller.shellQuote(input))")
            XCTAssertEqual(output, input, "sh must read \(input.debugDescription) back verbatim")
        }
    }

    // MARK: AppleScript quoting

    func testAppleScriptLiteralShape() {
        XCTAssertEqual(UpdateInstaller.appleScriptStringLiteral("abc"), #""abc""#)
        XCTAssertEqual(UpdateInstaller.appleScriptStringLiteral(#"a"b"#), #""a\"b""#)
        XCTAssertEqual(UpdateInstaller.appleScriptStringLiteral(#"a\b"#), #""a\\b""#)
        XCTAssertEqual(UpdateInstaller.appleScriptStringLiteral(#"\""#), #""\\\"""#)
    }

    func testAppleScriptLiteralRoundTripsHostileInput() throws {
        for input in hostileInputs {
            let literal = UpdateInstaller.appleScriptStringLiteral(input)
            let (decoded, rest) = try decodeAppleScriptLiteral(literal)
            XCTAssertEqual(decoded, input, "literal \(literal) must decode to the input")
            XCTAssertEqual(rest, "", "the literal must end exactly where it was meant to")
        }
    }

    // MARK: The root script

    func testRootScriptQuotesThePathAndReverifiesACopy() throws {
        let path = "/Users/example/Library/Caches/ai.parslee.throttle/Updates/Throttle-0.2.0.pkg"
        let script = try UpdateInstaller.rootShellScript(packagePath: path, teamID: team)
        let lines = script.components(separatedBy: "\n")

        XCTAssertEqual(lines.first, "set -e")
        XCTAssertTrue(lines.contains("dir=$(/usr/bin/mktemp -d /private/tmp/throttle-update.XXXXXX)"))
        XCTAssertTrue(lines.contains("trap '/bin/rm -rf \"$dir\"' EXIT"))
        XCTAssertTrue(lines.contains("/bin/cp '\(path)' \"$copy\""))
        XCTAssertTrue(script.contains("/usr/sbin/pkgutil --check-signature \"$copy\""))
        XCTAssertTrue(script.contains("'Developer ID Installer: '*'(ABCDE12345)'*"))
        XCTAssertTrue(script.contains("/usr/sbin/spctl --assess --type install -vv \"$copy\""))
        XCTAssertEqual(lines.last, "/usr/sbin/installer -pkg \"$copy\" -target / 1>&2")

        // The install reads the verified copy, never the user-writable original.
        func index(_ fragment: String) -> Int { lines.firstIndex { $0.contains(fragment) } ?? -1 }
        XCTAssertLessThan(index("/bin/cp"), index("pkgutil"))
        XCTAssertLessThan(index("pkgutil"), index("spctl"))
        XCTAssertLessThan(index("spctl"), index("/usr/sbin/installer"))
        XCTAssertFalse(lines.last!.contains(path))
    }

    func testRootScriptParsesAsShellForHostilePaths() throws {
        for input in hostileInputs {
            let script = try UpdateInstaller.rootShellScript(packagePath: "/tmp/\(input).pkg", teamID: team)
            // `sh -n` reads the script without executing a single command.
            XCTAssertNoThrow(try runShell(script, syntaxOnly: true), input.debugDescription)
            XCTAssertTrue(script.contains(UpdateInstaller.shellQuote("/tmp/\(input).pkg")))
        }
    }

    func testRootScriptRefusesAnInvalidTeamOrPath() {
        for badTeam in ["", "abcde12345", "ABCDE12345'; rm -rf /; '", "ABCDE12345\n", "$(id)"] {
            XCTAssertThrowsError(try UpdateInstaller.rootShellScript(packagePath: "/tmp/a.pkg", teamID: badTeam), badTeam.debugDescription)
        }
        XCTAssertThrowsError(try UpdateInstaller.rootShellScript(packagePath: "relative.pkg", teamID: team))
        XCTAssertThrowsError(try UpdateInstaller.rootShellScript(packagePath: "/tmp/a\u{0}b.pkg", teamID: team))
    }

    func testAppleScriptWrapsTheRootScriptExactly() throws {
        let path = #"/tmp/we "quote" and \back\slash $(id) `id` it's.pkg"#
        let appleScript = try UpdateInstaller.appleScript(packagePath: path, version: version, teamID: team)
        XCTAssertTrue(appleScript.hasPrefix("do shell script \""))
        XCTAssertTrue(appleScript.hasSuffix(" with administrator privileges"))

        let afterCommand = String(appleScript.dropFirst("do shell script ".count))
        let (shell, rest) = try decodeAppleScriptLiteral(afterCommand)
        XCTAssertEqual(shell, try UpdateInstaller.rootShellScript(packagePath: path, teamID: team))

        XCTAssertTrue(rest.hasPrefix(" with prompt \""))
        let (prompt, tail) = try decodeAppleScriptLiteral(String(rest.dropFirst(" with prompt ".count)))
        XCTAssertEqual(prompt, "Throttle needs an administrator password to install version 0.2.0.")
        XCTAssertEqual(tail, " with administrator privileges")
    }

    // MARK: Running osascript (scripted, never launched)

    func testInstallHandsTheScriptToOsascriptAsOneArgument() async throws {
        let runner = ScriptedCommandRunner([
            UpdateInstaller.osascriptPath: [CommandResult(status: 0, standardOutput: "", standardError: "")],
        ])
        let installer = UpdateInstaller(runner: runner)
        let url = URL(fileURLWithPath: UpdateFixtures.packagePath)
        try await installer.install(packageAt: url, version: version, teamID: team)

        let calls = runner.calls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].executable, "/usr/bin/osascript")
        XCTAssertEqual(calls[0].arguments, [
            "-e", try UpdateInstaller.appleScript(packagePath: url.path, version: version, teamID: team),
        ])
    }

    func testUserCancelIsNotAnError() {
        let cancelled = CommandResult(status: 1, standardOutput: "", standardError: "0:512: execution error: User canceled. (-128)\n")
        XCTAssertThrowsError(try UpdateInstaller.interpret(cancelled)) { error in
            XCTAssertTrue(error is InstallCancelled, "got \(error)")
        }
    }

    func testOtherFailuresAreTrimmed() {
        let failed = CommandResult(
            status: 1,
            standardOutput: "",
            standardError: "0:512: execution error: installer: Error - the package path specified was invalid.\n (1)\n"
        )
        XCTAssertThrowsError(try UpdateInstaller.interpret(failed)) { error in
            XCTAssertEqual(error as? UpdateError, .install("installer: Error - the package path specified was invalid."))
        }
        let silent = CommandResult(status: 2, standardOutput: "", standardError: "")
        XCTAssertThrowsError(try UpdateInstaller.interpret(silent)) { error in
            XCTAssertEqual(error as? UpdateError, .install("the installer exited with status 2"))
        }
        XCTAssertNoThrow(try UpdateInstaller.interpret(CommandResult(status: 0, standardOutput: "", standardError: "")))
    }

    // MARK: Relaunch

    func testRelaunchPassesThePidAndPathPositionally() {
        let arguments = UpdateInstaller.relaunchArguments(pid: 4242)
        XCTAssertEqual(arguments, ["-c", UpdateInstaller.relaunchScript, "sh", "4242", "/Applications/Throttle.app"])
        XCTAssertFalse(UpdateInstaller.relaunchScript.contains("4242"))
        XCTAssertFalse(UpdateInstaller.relaunchScript.contains("Throttle.app"))
        XCTAssertTrue(UpdateInstaller.relaunchScript.contains(#""$1""#))
        XCTAssertTrue(UpdateInstaller.relaunchScript.contains(#"/usr/bin/open "$2""#))
        XCTAssertNoThrow(try runShell(UpdateInstaller.relaunchScript, syntaxOnly: true))
    }

    // MARK: Helpers

    /// Runs `/bin/sh -c script` (or `-n -c` to only parse it) and returns stdout.
    private func runShell(_ script: String, syntaxOnly: Bool = false) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = (syntaxOnly ? ["-n"] : []) + ["-c", script]
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errorText = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "sh", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: errorText])
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// Reads one AppleScript string literal from the start of `text` the way
    /// the AppleScript compiler does for the two escapes Throttle emits, and
    /// returns the decoded string and whatever follows the closing quote.
    private func decodeAppleScriptLiteral(_ text: String) throws -> (String, String) {
        var iterator = text.makeIterator()
        guard iterator.next() == "\"" else { throw DecodeError.noOpeningQuote }
        var decoded = ""
        var consumed = 1
        while let character = iterator.next() {
            consumed += 1
            switch character {
            case "\\":
                guard let escaped = iterator.next() else { throw DecodeError.danglingEscape }
                consumed += 1
                guard escaped == "\\" || escaped == "\"" else { throw DecodeError.unexpectedEscape(escaped) }
                decoded.append(escaped)
            case "\"":
                return (decoded, String(text.dropFirst(consumed)))
            default:
                decoded.append(character)
            }
        }
        throw DecodeError.unterminated
    }

    private enum DecodeError: Error {
        case noOpeningQuote, danglingEscape, unexpectedEscape(Character), unterminated
    }
}
