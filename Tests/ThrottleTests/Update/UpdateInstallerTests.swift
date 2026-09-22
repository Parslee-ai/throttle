import XCTest
@testable import Throttle

final class UpdateInstallerTests: XCTestCase {
    private let team = UpdateFixtures.team
    private let version = SemanticVersion("0.2.0")!
    private var directory: URL!

    override func setUpWithError() throws {
        directory = try UpdateFixtures.temporaryDirectory()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

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

    private func script(
        path: String = UpdateFixtures.packagePath,
        version: String = "0.2.0",
        size: Int = 1_339_213,
        sha256: String = UpdateFixtures.zeroSHA256
    ) throws -> String {
        try UpdateInstaller.rootShellScript(
            packagePath: path, teamID: team, version: SemanticVersion(version)!, size: size, sha256: sha256
        )
    }

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
            let output = try runShell("printf '%s' \(UpdateInstaller.shellQuote(input))").output
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

    // MARK: The root script's shape

    func testRootScriptPinsEverythingBeforeInstallerReadsTheCopy() throws {
        let path = "/Users/example/Library/Caches/ai.parslee.throttle/Updates/Throttle-0.2.0.pkg"
        let script = try script(path: path, size: 1_339_213, sha256: UpdateFixtures.abcSHA256)
        let lines = script.components(separatedBy: "\n")

        XCTAssertEqual(lines.first, "set -e")
        XCTAssertTrue(lines.contains("src='\(path)'"))
        XCTAssertTrue(lines.contains("dir=$(/usr/bin/mktemp -d /private/tmp/throttle-update.XXXXXX)"))
        XCTAssertTrue(lines.contains("trap '/bin/rm -rf \"$dir\"' EXIT"))
        XCTAssertTrue(lines.contains("/usr/bin/head -c 1339214 \"$src\" > \"$copy\""), "copies at most one byte past the size")
        XCTAssertTrue(script.contains("= '1339213' ]"))
        XCTAssertTrue(script.contains("[ \"${sum%% *}\" = '\(UpdateFixtures.abcSHA256)' ]"))
        XCTAssertTrue(script.contains("'Developer ID Installer: '*' (ABCDE12345)') ;;"), "the leaf match is anchored at the end")
        XCTAssertTrue(script.contains("@id=\"ai.parslee.throttle\"][@version=\"0.2.0\"]"))
        XCTAssertEqual(lines.last, "/usr/sbin/installer -pkg \"$copy\" -target / 1>&2")

        // Each check runs on the root-owned copy, in this order, and installer
        // is the only thing after them.
        func index(_ fragment: String) -> Int { lines.firstIndex { $0.contains(fragment) } ?? -1 }
        let order = [
            "[ -L \"$src\" ]", "/usr/bin/mktemp", "/usr/bin/head -c", "/usr/bin/stat -f %z", "/usr/bin/shasum",
            "/usr/sbin/pkgutil", "case \"$leaf\"", "/usr/sbin/spctl", "/usr/bin/xar -tf", "/usr/bin/xar -xf",
            "isthrottle=", "isversion=", "/usr/sbin/installer",
        ]
        let indices = order.map(index)
        XCTAssertFalse(indices.contains(-1), "every step is present: \(zip(order, indices).map { "\($0)=\($1)" })")
        XCTAssertEqual(indices, indices.sorted(), "steps run in order")
        for line in lines.dropFirst(indices[2] + 1) {
            XCTAssertFalse(line.contains("\"$src\""), "after the copy nothing reads the user-writable original: \(line)")
        }
    }

    func testRootScriptParsesAsShellForHostilePaths() throws {
        for input in hostileInputs {
            let script = try script(path: "/tmp/\(input).pkg")
            // `sh -n` reads the script without executing a single command.
            XCTAssertNoThrow(try runShell(script, syntaxOnly: true), input.debugDescription)
            XCTAssertTrue(script.contains(UpdateInstaller.shellQuote("/tmp/\(input).pkg")))
        }
    }

    func testRootScriptRefusesAnInvalidPin() {
        for badTeam in ["", "abcde12345", "ABCDE12345'; rm -rf /; '", "ABCDE12345\n", "$(id)"] {
            XCTAssertThrowsError(try UpdateInstaller.rootShellScript(
                packagePath: "/tmp/a.pkg", teamID: badTeam, version: version, size: 3, sha256: UpdateFixtures.abcSHA256
            ), badTeam.debugDescription)
        }
        for badDigest in ["", UpdateFixtures.abcSHA256.uppercased(), "sha256:" + UpdateFixtures.abcSHA256,
                          String(UpdateFixtures.abcSHA256.dropLast()), UpdateFixtures.abcSHA256 + "'", UpdateFixtures.abcSHA256 + "\n"] {
            XCTAssertThrowsError(try script(sha256: badDigest), badDigest.debugDescription)
        }
        XCTAssertThrowsError(try script(size: 0))
        XCTAssertThrowsError(try script(size: ReleaseFeed.maxPackageBytes + 1))
        XCTAssertThrowsError(try script(path: "relative.pkg"))
        XCTAssertThrowsError(try script(path: "/tmp/a\u{0}b.pkg"))
    }

    // MARK: The root script's checks, run for real as this user

    /// Runs the script's opening lines, from the symlink check through the
    /// checksum, against real files. Nothing is installed: the lines stop
    /// before `pkgutil`, and the root-owned temp dir is this user's here.
    private func runCopyChecks(source: URL, size: Int, sha256: String) throws -> (status: Int32, output: String, error: String) {
        let lines = try script(path: source.path, size: size, sha256: sha256).components(separatedBy: "\n")
        let end = try XCTUnwrap(lines.firstIndex { $0.hasPrefix("[ \"${sum%% *}\"") })
        let prefix = lines[...end].joined(separator: "\n") + "\necho COPY-VERIFIED"
        return try runShell(prefix, allowFailure: true)
    }

    func testRootCopyAcceptsTheVerifiedBytes() throws {
        let file = directory.appendingPathComponent("Throttle-0.2.0.pkg")
        try Data("abc".utf8).write(to: file)
        let result = try runCopyChecks(source: file, size: 3, sha256: UpdateFixtures.abcSHA256)
        XCTAssertEqual(result.status, 0, result.error)
        XCTAssertEqual(result.output, "COPY-VERIFIED\n")
    }

    func testRootCopyRefusesASymlinkSource() throws {
        let file = directory.appendingPathComponent("real.pkg")
        try Data("abc".utf8).write(to: file)
        let link = directory.appendingPathComponent("Throttle-0.2.0.pkg")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        let result = try runCopyChecks(source: link, size: 3, sha256: UpdateFixtures.abcSHA256)
        XCTAssertEqual(result.status, 65)
        XCTAssertEqual(result.error, "the downloaded package is not a regular file\n")
    }

    func testRootCopyRefusesADirectorySource() throws {
        let result = try runCopyChecks(source: directory, size: 3, sha256: UpdateFixtures.abcSHA256)
        XCTAssertEqual(result.status, 65)
    }

    func testRootCopyRefusesAnOversizeSource() throws {
        let file = directory.appendingPathComponent("Throttle-0.2.0.pkg")
        try Data("abcdef".utf8).write(to: file)
        let result = try runCopyChecks(source: file, size: 3, sha256: UpdateFixtures.abcSHA256)
        XCTAssertEqual(result.status, 65)
        XCTAssertEqual(result.error, "the package copy is not the size that was verified\n")
    }

    func testRootCopyRefusesOtherBytesOfTheSameSize() throws {
        let file = directory.appendingPathComponent("Throttle-0.2.0.pkg")
        try Data("abd".utf8).write(to: file)
        let result = try runCopyChecks(source: file, size: 3, sha256: UpdateFixtures.abcSHA256)
        XCTAssertEqual(result.status, 65)
        XCTAssertEqual(result.error, "the package copy does not match the bytes that were verified\n")
    }

    /// The leaf `case` line, run by `sh` against crafted leaves.
    func testRootLeafMatchIsAnchored() throws {
        let caseLine = try XCTUnwrap(script().components(separatedBy: "\n").first { $0.hasPrefix("case \"$leaf\"") })
        func run(_ leaf: String) throws -> Int32 {
            try runShell("leaf=\(UpdateInstaller.shellQuote(leaf))\n\(caseLine)", allowFailure: true).status
        }
        XCTAssertEqual(try run("Developer ID Installer: Example Corp (ABCDE12345)"), 0)
        XCTAssertEqual(try run("Developer ID Installer: Evil (ABCDE12345) Corp (EVILTEAM01)"), 65)
        XCTAssertEqual(try run("Developer ID Installer: Evil (EVILTEAM01) (ABCDE12345)x"), 65)
        XCTAssertEqual(try run("Developer ID Installer: Evil(ABCDE12345)"), 65)
        XCTAssertEqual(try run("Developer ID Application: Example Corp (ABCDE12345)"), 65)
        XCTAssertEqual(try run(""), 65)
    }

    func testRootScriptsCheckRefusesScriptsEntries() throws {
        let line = try XCTUnwrap(script().components(separatedBy: "\n").first { $0.contains("grep -q 'Scripts$'") })
        func run(_ entries: String) throws -> Int32 {
            try runShell("entries=\(UpdateInstaller.shellQuote(entries))\n\(line)", allowFailure: true).status
        }
        XCTAssertEqual(try run(UpdateFixtures.xarListing().standardOutput), 0)
        XCTAssertEqual(try run(UpdateFixtures.xarListing(component: ".other.pkg", scripts: true).standardOutput), 65)
    }

    /// The two `xmllint` checks, run against real Distribution files.
    func testRootDistributionChecksPinProductAndVersion() throws {
        let lines = try script(version: "0.2.0").components(separatedBy: "\n")
        let checks = lines.filter { $0.hasPrefix("isthrottle=") || $0.hasPrefix("isversion=") || $0.hasPrefix("[ \"$is") }
        XCTAssertEqual(checks.count, 4)
        func run(_ distribution: String) throws -> (status: Int32, output: String, error: String) {
            let dir = directory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data(distribution.utf8).write(to: dir.appendingPathComponent("Distribution"))
            return try runShell("dir=\(UpdateInstaller.shellQuote(dir.path))\n" + checks.joined(separator: "\n") + "\necho ok", allowFailure: true)
        }
        XCTAssertEqual(try run(UpdateFixtures.distribution(version: "0.2.0")).status, 0)

        let other = try run(UpdateFixtures.distribution(id: "com.example.other-app"))
        XCTAssertEqual(other.status, 65)
        XCTAssertEqual(other.error, "the package copy is not Throttle\n")

        let bundled = try run(UpdateFixtures.distribution(extraReference: "com.example.helper"))
        XCTAssertEqual(bundled.status, 65)
        XCTAssertEqual(bundled.error, "the package copy is not Throttle\n")

        let downgrade = try run(UpdateFixtures.distribution(version: "0.1.0-rc.1"))
        XCTAssertEqual(downgrade.status, 65)
        XCTAssertEqual(downgrade.error, "the package copy is not Throttle 0.2.0\n")
    }

    // MARK: Wrapping for osascript

    func testAppleScriptRunsTheRootScriptInAnEmptyEnvironment() throws {
        let path = #"/tmp/we "quote" and \back\slash $(id) `id` it's.pkg"#
        let package = UpdateFixtures.verified(path: path)
        let appleScript = try UpdateInstaller.appleScript(for: package)
        XCTAssertTrue(appleScript.hasPrefix("do shell script \""))
        XCTAssertTrue(appleScript.hasSuffix(" with administrator privileges"))

        let afterCommand = String(appleScript.dropFirst("do shell script ".count))
        let (command, rest) = try decodeAppleScriptLiteral(afterCommand)
        let root = try UpdateInstaller.rootShellScript(
            packagePath: package.url.path, teamID: team, version: package.version, size: package.size, sha256: package.sha256
        )
        XCTAssertEqual(command, "/usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin /bin/sh -c " + UpdateInstaller.shellQuote(root))

        XCTAssertTrue(rest.hasPrefix(" with prompt \""))
        let (prompt, tail) = try decodeAppleScriptLiteral(String(rest.dropFirst(" with prompt ".count)))
        XCTAssertEqual(prompt, "Throttle needs an administrator password to install version 0.2.0.")
        XCTAssertEqual(tail, " with administrator privileges")
    }

    /// The command `do shell script` would run, handed to `sh` with the root
    /// script swapped for a harmless one of the same quoting: `sh` must see an
    /// empty environment apart from `PATH`.
    func testTheEnvironmentWrapperClearsTheEnvironment() throws {
        let probe = "printf '%s|' \"$PATH\" \"${PERL5OPT-unset}\" \"${HOME-unset}\""
        let result = try runShell(UpdateInstaller.rootCommandPrefix + UpdateInstaller.shellQuote(probe), environment: ["PERL5OPT": "-Mevil", "HOME": "/tmp"])
        XCTAssertEqual(result.output, "/usr/bin:/bin:/usr/sbin:/sbin|unset|unset|")
    }

    // MARK: Running osascript (scripted, never launched)

    func testInstallHandsTheScriptToOsascriptAsOneArgument() async throws {
        let runner = ScriptedCommandRunner([
            UpdateInstaller.osascriptPath: [CommandResult(status: 0, standardOutput: "", standardError: "")],
        ])
        let package = UpdateFixtures.verified()
        try await UpdateInstaller(runner: runner).install(package)

        let calls = runner.calls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].executable, "/usr/bin/osascript")
        XCTAssertEqual(calls[0].arguments, ["-e", try UpdateInstaller.appleScript(for: package)])
    }

    func testUserCancelIsNotAnError() {
        let cancelled = CommandResult(status: 1, standardOutput: "", standardError: "0:512: execution error: User canceled. (-128)\n")
        XCTAssertThrowsError(try UpdateInstaller.interpret(cancelled)) { error in
            XCTAssertTrue(error is InstallCancelled, "got \(error)")
        }
    }

    func testARootRefusalIsAVerificationFailure() {
        let refused = CommandResult(
            status: 1,
            standardOutput: "",
            standardError: "0:3187: execution error: the package copy is not Throttle 0.2.0 (65)\n"
        )
        XCTAssertThrowsError(try UpdateInstaller.interpret(refused)) { error in
            XCTAssertEqual(error as? UpdateError, .verification("the package copy is not Throttle 0.2.0"))
        }
    }

    func testOtherFailuresAreTrimmedInstallErrors() {
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

    /// Runs `/bin/sh -c script` (or `-n -c` to only parse it).
    @discardableResult
    private func runShell(
        _ script: String,
        syntaxOnly: Bool = false,
        allowFailure: Bool = false,
        environment: [String: String]? = nil
    ) throws -> (status: Int32, output: String, error: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = (syntaxOnly ? ["-n"] : []) + ["-c", script]
        if let environment { process.environment = environment }
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errorText = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        if !allowFailure, process.terminationStatus != 0 {
            throw NSError(domain: "sh", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: errorText])
        }
        return (process.terminationStatus, String(decoding: data, as: UTF8.self), errorText)
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
