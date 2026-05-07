//
//  TelemetryConfigTests.swift
//  MLXAudioTests
//
//  Sortie 2 of OPERATION LEAK BLOODHOUND — env-var resolution & level
//  clamping for the MLXAudio telemetry surface.
//
//  These tests exercise the pure resolver `Telemetry.resolveLevel(...)`
//  and the parser `Telemetry.parseLevel(...)` directly. The cached
//  `Telemetry.level` static accessor is intentionally NOT poked from
//  here — it resolves once-per-process from the actual environment, and
//  the parent test process inherits its own env. Touching it would make
//  tests order-dependent and would burn the one-shot warning. The pure
//  resolver gives us deterministic coverage of every parse / clamp /
//  warning path without that fragility.
//
//  Test targets are compiled with `MLXAUDIO_TELEMETRY_FULL` (debug),
//  so `Telemetry.ceiling` is `.verbose` here. The tests still
//  parameterize ceiling explicitly so the clamp behaviour is exercised
//  even when the compile ceiling is `.verbose`.
//

import Foundation
import Testing

@testable import MLXAudioCore

@Suite("TelemetryConfigTests")
struct TelemetryConfigTests {

    // MARK: - parseLevel

    @Test("parseLevel: nil → nil (signals default)")
    func parseLevel_nil_isNil() {
        #expect(Telemetry.parseLevel(nil) == nil)
    }

    @Test("parseLevel: empty / whitespace → nil")
    func parseLevel_empty_isNil() {
        #expect(Telemetry.parseLevel("") == nil)
        #expect(Telemetry.parseLevel("   ") == nil)
        #expect(Telemetry.parseLevel("\n\t") == nil)
    }

    @Test("parseLevel: every valid name parses, case-insensitive")
    func parseLevel_validNames() {
        #expect(Telemetry.parseLevel("off") == .off)
        #expect(Telemetry.parseLevel("OFF") == .off)
        #expect(Telemetry.parseLevel("Off") == .off)

        #expect(Telemetry.parseLevel("lifecycle") == .lifecycle)
        #expect(Telemetry.parseLevel("LifeCycle") == .lifecycle)

        #expect(Telemetry.parseLevel("operations") == .operations)
        #expect(Telemetry.parseLevel("OPERATIONS") == .operations)

        #expect(Telemetry.parseLevel("memory") == .memory)
        #expect(Telemetry.parseLevel("Memory") == .memory)

        #expect(Telemetry.parseLevel("verbose") == .verbose)
        #expect(Telemetry.parseLevel("VERBOSE") == .verbose)
    }

    @Test("parseLevel: leading/trailing whitespace tolerated")
    func parseLevel_whitespaceTolerated() {
        #expect(Telemetry.parseLevel("  memory  ") == .memory)
        #expect(Telemetry.parseLevel("\toperations\n") == .operations)
    }

    @Test("parseLevel: unknown name → nil")
    func parseLevel_unknown_isNil() {
        #expect(Telemetry.parseLevel("debug") == nil)
        #expect(Telemetry.parseLevel("trace") == nil)
        #expect(Telemetry.parseLevel("0") == nil)
        #expect(Telemetry.parseLevel("3") == nil)
        #expect(Telemetry.parseLevel("verbosee") == nil)
    }

    // MARK: - resolveLevel — defaults

    @Test("resolveLevel: env unset → .lifecycle (no warn)")
    func resolveLevel_unset_defaultsToLifecycle() {
        var warnCount = 0
        let resolved = Telemetry.resolveLevel(
            rawValue: nil,
            ceiling: .verbose,
            warn: { _ in warnCount += 1 }
        )
        #expect(resolved == .lifecycle)
        #expect(warnCount == 0)
    }

    @Test("resolveLevel: env set to garbage → .lifecycle (no warn)")
    func resolveLevel_unparseable_defaultsToLifecycle() {
        var warnCount = 0
        let resolved = Telemetry.resolveLevel(
            rawValue: "not-a-level",
            ceiling: .verbose,
            warn: { _ in warnCount += 1 }
        )
        #expect(resolved == .lifecycle)
        #expect(warnCount == 0)
    }

    @Test("resolveLevel: every valid name resolves under .verbose ceiling")
    func resolveLevel_validNames_underFullCeiling() {
        var warnCount = 0
        let warn: (Telemetry.Level) -> Void = { _ in warnCount += 1 }

        #expect(Telemetry.resolveLevel(rawValue: "off",        ceiling: .verbose, warn: warn) == .off)
        #expect(Telemetry.resolveLevel(rawValue: "lifecycle",  ceiling: .verbose, warn: warn) == .lifecycle)
        #expect(Telemetry.resolveLevel(rawValue: "operations", ceiling: .verbose, warn: warn) == .operations)
        #expect(Telemetry.resolveLevel(rawValue: "memory",     ceiling: .verbose, warn: warn) == .memory)
        #expect(Telemetry.resolveLevel(rawValue: "verbose",    ceiling: .verbose, warn: warn) == .verbose)

        #expect(warnCount == 0)
    }

    // MARK: - resolveLevel — clamp

    @Test("resolveLevel: requested == ceiling does NOT warn")
    func resolveLevel_atCeiling_noWarn() {
        var warnCount = 0
        let resolved = Telemetry.resolveLevel(
            rawValue: "lifecycle",
            ceiling: .lifecycle,
            warn: { _ in warnCount += 1 }
        )
        #expect(resolved == .lifecycle)
        #expect(warnCount == 0)
    }

    @Test("resolveLevel: requested > ceiling clamps and warns once")
    func resolveLevel_overCeiling_clampsAndWarns() {
        var warnCount = 0
        var lastRequested: Telemetry.Level?

        let resolved = Telemetry.resolveLevel(
            rawValue: "verbose",
            ceiling: .lifecycle,
            warn: { requested in
                warnCount += 1
                lastRequested = requested
            }
        )
        #expect(resolved == .lifecycle)
        #expect(warnCount == 1)
        #expect(lastRequested == .verbose)
    }

    @Test("resolveLevel: each over-ceiling level warns exactly once per call")
    func resolveLevel_overCeiling_warnsOncePerCall() {
        var warnCount = 0
        let warn: (Telemetry.Level) -> Void = { _ in warnCount += 1 }

        // Ceiling .lifecycle, request .operations → clamp + warn
        _ = Telemetry.resolveLevel(rawValue: "operations", ceiling: .lifecycle, warn: warn)
        #expect(warnCount == 1)

        // Ceiling .operations, request .memory → clamp + warn
        _ = Telemetry.resolveLevel(rawValue: "memory", ceiling: .operations, warn: warn)
        #expect(warnCount == 2)

        // Ceiling .memory, request .verbose → clamp + warn
        _ = Telemetry.resolveLevel(rawValue: "verbose", ceiling: .memory, warn: warn)
        #expect(warnCount == 3)
    }

    @Test("resolveLevel: requested below ceiling does not warn")
    func resolveLevel_belowCeiling_noWarn() {
        var warnCount = 0
        let warn: (Telemetry.Level) -> Void = { _ in warnCount += 1 }

        _ = Telemetry.resolveLevel(rawValue: "off",        ceiling: .verbose, warn: warn)
        _ = Telemetry.resolveLevel(rawValue: "lifecycle",  ceiling: .verbose, warn: warn)
        _ = Telemetry.resolveLevel(rawValue: "operations", ceiling: .verbose, warn: warn)
        _ = Telemetry.resolveLevel(rawValue: "memory",     ceiling: .verbose, warn: warn)

        #expect(warnCount == 0)
    }

    // MARK: - Public API surface sanity

    @Test("Telemetry.ceiling matches MLXAUDIO_TELEMETRY_FULL build flag")
    func ceiling_matchesBuildFlag() {
        // Test target is built with MLXAUDIO_TELEMETRY_FULL (debug),
        // so ceiling must be .verbose here.
        #expect(Telemetry.ceiling == .verbose)
    }

    @Test("Telemetry.level returns a Level <= ceiling")
    func level_isClampedToCeiling() {
        let level = Telemetry.level
        #expect(level <= Telemetry.ceiling)
    }

    @Test("Telemetry.level is stable across reads (cached)")
    func level_isCached() {
        let first = Telemetry.level
        let second = Telemetry.level
        let third = Telemetry.level
        #expect(first == second)
        #expect(second == third)
    }

    // MARK: - Cached one-shot warning (process-level)
    //
    // We can't directly inspect the os.Logger output from Swift Testing
    // without scaffolding a custom log handler. We instead verify the
    // semantic invariant: the cached `Telemetry.level` (which is the
    // ONLY accessor that fires the production warning) is stable and
    // bounded by the ceiling. The pure resolver tests above verify that
    // each invocation of the warning closure happens exactly once per
    // call when the requested level exceeds the ceiling — combined with
    // Swift's static-let one-shot initialization, this gives us the
    // "warn at most once per process" semantic.

    @Test("ResolvedLevel singleton survives many reads without re-firing")
    func resolvedLevel_isOneShot() {
        // Read .level 100 times; if the implementation accidentally
        // re-resolved on each read, this loop would either be O(n)
        // env reads or — worse — re-fire any clamp warning. The test
        // can't measure side effects on os.Logger, but it CAN insist
        // that the returned value is deterministic and ≤ ceiling on
        // every iteration.
        let ceiling = Telemetry.ceiling
        let firstRead = Telemetry.level
        for _ in 0..<100 {
            let read = Telemetry.level
            #expect(read == firstRead)
            #expect(read <= ceiling)
        }
    }
}
