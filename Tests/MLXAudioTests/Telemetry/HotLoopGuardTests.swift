//
//  HotLoopGuardTests.swift
//  MLXAudioTests
//
//  Sortie 19 of OPERATION SILENT STETHOSCOPE — cross-cutting hot-loop
//  guard that fails the build if any `await emit(...)` call appears
//  inside the body of a `for` or `while` loop in the TTS / STT /
//  codec source trees.
//
//  REQUIREMENTS-telemetry.md §7 (anti-patterns) forbids emitting
//  events inside per-step decode loops or per-frame playback loops:
//  doing so turns a coarse telemetry hook into a hot-path overhead
//  source and defeats invariant 3. The check below runs at test time
//  via a shell pipeline so it is enforced even if a future contributor
//  forgets the convention.
//
//  # How the check works
//
//  For every `*.swift` file under `Sources/MLXAudioTTS/`,
//  `Sources/MLXAudioSTT/`, and `Sources/MLXAudioCodecs/`:
//
//    1. Strip `//`-style line comments via `sed`. Comments that
//       happen to contain the word "for" or "while" (e.g. an English
//       sentence inside a doc comment) are routinely false-positives
//       for a naive grep — stripping them eliminates that whole
//       class of noise without affecting code correctness.
//
//    2. Use `grep -nE '(for |while )' -A 2` to surface every
//       loop-keyword line plus its two trailing lines (the typical
//       loop body opens on the next or next-next line in Swift).
//
//    3. Filter that output for `await emit(` — the canonical
//       per-instance helper call site.
//
//    4. Empty output → pass. Any line with a code-side `for`/`while`
//       followed within 2 lines by `await emit(` is a violation; the
//       test fails with the offending file name in the message.
//
//  # Working directory
//
//  Swift Testing runs tests from an arbitrary cwd (xcodebuild may run
//  from `/private/var/...`, swift test from the package root). The
//  test resolves the repo root deterministically by walking up from
//  `#filePath` until it finds a directory containing `Package.swift`
//  (the canonical anchor for SPM packages). This is robust against
//  both `swift test` and `xcodebuild test -destination 'platform=macOS'`.
//
//  # Why a Process instead of pure Swift?
//
//  The shell pipeline mirrors the canonical invariant grep documented
//  in `docs/TELEMETRY.md` § "Invariant Verification Greps". Running
//  the same pipeline at test time keeps the test and the doc in sync
//  by construction — if a contributor adds a new TTS / STT / codec
//  package, this test surfaces it without requiring any update.
//
//  # CI safety
//
//  No model downloads, no network. Runs `/bin/bash` against the
//  package's own source tree.
//

import Foundation
import Testing

// MARK: - HotLoopGuardTests

@Suite("HotLoopGuardTests")
struct HotLoopGuardTests {

    // MARK: - Repo-root resolution

    /// Resolve the repository root by walking up from this test file
    /// until we find a directory that contains `Package.swift`. Falls
    /// back to the current working directory if no anchor is found
    /// (in which case the grep below will return an `ls`-style error
    /// and the test will fail loudly — exactly what we want).
    private static func repoRoot() -> URL {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        // Walk up at most 16 levels — every realistic monorepo layout
        // has the package root within a few hops of any test file.
        for _ in 0..<16 {
            let candidate = dir.appendingPathComponent("Package.swift")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return dir
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }   // hit filesystem root
            dir = parent
        }
        // Fallback: cwd. Allows the test to surface a meaningful
        // failure rather than silently passing.
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    }

    /// Run the canonical hot-loop grep pipeline against the package
    /// source tree. Returns stdout (and stderr) as a single trimmed
    /// string. Empty string → no violations.
    ///
    /// The pipeline:
    ///
    ///   1. `find` enumerates every `.swift` file under the three
    ///      candidate source trees.
    ///   2. `xargs sed 's,//.*$,,'` strips line comments, file by
    ///      file, into a single concatenated stream. We use
    ///      `xargs -0`-style `-print0` to be safe against unusual
    ///      filenames (none currently exist in the tree but defensive
    ///      coding is cheap).
    ///   3. `grep -nE '(for |while )' -A 2` surfaces loop-keyword
    ///      lines plus 2 trailing lines.
    ///   4. The trailing `grep 'await emit('` flags any nearby
    ///      emission. Empty result → no violations.
    ///   5. The `|| true` at the end keeps a 1-exit (no matches in
    ///      the final grep) from killing the pipeline.
    ///
    /// Each file is processed independently by `sed -E`; the
    /// concatenation step would lose per-file line numbers. We trade
    /// that small UX cost for the robustness benefit of stripping
    /// comments — the file in violation is still discoverable by
    /// running `grep -RInE '(for |while )' Sources/... -A 2 | grep 'await emit('`
    /// manually after the test fails.
    private static func runGuardPipeline(at root: URL) throws -> (stdout: String, exitCode: Int32) {
        let task = Process()
        task.launchPath = "/bin/bash"
        task.currentDirectoryURL = root
        task.arguments = [
            "-c",
            #"""
            find Sources/MLXAudioTTS Sources/MLXAudioSTT Sources/MLXAudioCodecs \
                 -name '*.swift' -print0 2>/dev/null \
              | xargs -0 sed 's,//.*$,,' 2>/dev/null \
              | grep -nE '(for |while )' -A 2 2>/dev/null \
              | grep 'await emit(' \
              || true
            """#
        ]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe

        try task.run()
        task.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let raw = String(data: data, encoding: .utf8) ?? ""
        return (raw.trimmingCharacters(in: .whitespacesAndNewlines), task.terminationStatus)
    }

    // MARK: - Test 1: hot-loop guard

    /// No `await emit(` call appears within 2 lines after a `for ` or
    /// `while ` loop keyword in any TTS / STT / codec source file
    /// (after stripping `//` line comments).
    @Test
    func noAwaitEmitInsideAnyForOrWhileLoopBody() throws {
        let root = Self.repoRoot()

        // Sanity: the resolved root contains the three target trees.
        // If any is missing, the test fails fast with a useful message
        // instead of silently passing on a wrong-cwd fallback.
        for sub in ["Sources/MLXAudioTTS", "Sources/MLXAudioSTT", "Sources/MLXAudioCodecs"] {
            let path = root.appendingPathComponent(sub).path
            #expect(FileManager.default.fileExists(atPath: path),
                    "Expected source tree at \(path); resolved repoRoot = \(root.path). Test cannot enforce hot-loop guard from this cwd.")
        }

        let (output, exitCode) = try Self.runGuardPipeline(at: root)
        #expect(exitCode == 0,
                "Hot-loop guard pipeline exited with non-zero status \(exitCode); output:\n\(output)")
        #expect(output.isEmpty,
                """
                Found `await emit(` within 2 lines of a `for `/`while ` keyword in TTS/STT/codec sources \
                (after stripping `//` line comments). REQUIREMENTS-telemetry.md §7 forbids emission \
                inside per-step decode loops or per-frame playback loops.

                Offending lines (file paths + line numbers may be partial because the pipeline strips comments \
                file-by-file and concatenates output before grep'ing):

                \(output)

                Fix: move the `await emit(...)` call outside the loop body so it runs only at boundaries \
                (start / complete / error). Re-run this test to verify.
                """)
    }

    // MARK: - Test 2: invariant 1 — library never imports the host

    /// `grep -RIn "import .*Produciesta" Sources/` returns empty.
    /// Mirrors REQUIREMENTS-telemetry.md §6 invariant 1.
    @Test
    func libraryNeverImportsProduciesta() throws {
        let root = Self.repoRoot()

        let task = Process()
        task.launchPath = "/bin/bash"
        task.currentDirectoryURL = root
        task.arguments = [
            "-c",
            "grep -RIn 'import .*Produciesta' Sources/ || true"
        ]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe

        try task.run()
        task.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = (String(data: data, encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        #expect(output.isEmpty,
                """
                MLXAudio sources import Produciesta. Invariant 1 violated:
                the library is vendor-neutral and must never depend on a host.

                Offending lines:
                \(output)
                """)
    }

    // MARK: - Test 3: invariant 2 — no new logging dependencies in public files

    /// The two public telemetry files must not import `swift-log` /
    /// `Logging` / `OSLog`. Mirrors REQUIREMENTS-telemetry.md §6 invariant 2.
    @Test
    func publicTelemetryFilesImportNoLoggingDependencies() throws {
        let root = Self.repoRoot()

        let task = Process()
        task.launchPath = "/bin/bash"
        task.currentDirectoryURL = root
        task.arguments = [
            "-c",
            #"""
            grep -RIn 'import swift_log\|import Logging\|import OSLog' \
                Sources/MLXAudioCore/Telemetry/MLXAudioTelemetryEvent.swift \
                Sources/MLXAudioCore/Telemetry/MLXAudioTelemetryReporter.swift \
                || true
            """#
        ]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe

        try task.run()
        task.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = (String(data: data, encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        #expect(output.isEmpty,
                """
                Public telemetry files import a logging dependency. Invariant 2 violated:
                MLXAudioTelemetryEvent.swift and MLXAudioTelemetryReporter.swift must depend on
                Foundation only.

                Offending lines:
                \(output)
                """)
    }
}
