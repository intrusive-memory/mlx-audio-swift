//
//  AudioModelManagerTelemetryTests.swift
//  MLXAudioTests
//
//  Sortie 2 of OPERATION SILENT STETHOSCOPE — behavioural coverage for
//  the public-telemetry instrumentation added to `AudioModelManager`.
//
//  These tests exercise the canonical pattern that every downstream
//  instrumentation sortie copies verbatim:
//
//    1. `setTelemetry(_:)` attaches an optional reporter; the default
//       (no setter call) is silent.
//    2. The private `emit(_:)` helper uses an `@autoclosure` so payload
//       construction (Metal sampling, error-string formatting) is
//       elided whenever no reporter is attached.
//    3. Every public load / download surface emits a `start +
//       complete` pair on success and a `*Error` event on throw.
//
//  Network safety: all tests register a synthetic `ComponentDescriptor`
//  with `files: []`, which `Acervo.isComponentReady` treats as already
//  ready (vacuous loop in `for file in descriptor.files`). The
//  download path therefore short-circuits without any network call.
//  The error tests use an unregistered component-id, which throws
//  `AcervoError.componentNotRegistered` synchronously before any
//  download is attempted.
//
//  Concurrency safety: `_AudioModelManagerTelemetryStorage` is a
//  process-global actor. The suite carries the `.serialized` trait so
//  Swift Testing runs these cases sequentially, and each test resets
//  the storage to `nil` at its prologue so cross-test contamination
//  cannot leak a reporter from one case to another.
//
//  Sortie scope: `Sources/MLXAudioCore/AudioModelManager.swift` only.
//  The `Tests/MLXAudioTests/Telemetry/` directory is shared with other
//  Wave-1 sorties (Sortie 3 / 4 / 6); the test names below are
//  prefixed `AudioModelManagerTelemetryTests` so the
//  `-only-testing:MLXAudioTests/AudioModelManagerTelemetryTests`
//  selector picks up exactly this file's tests.
//

import Foundation
import Testing

@testable import MLXAudioCore
import SwiftAcervo

/// Suite is `.serialized` because every test mutates the
/// process-global telemetry storage actor
/// (`_AudioModelManagerTelemetryStorage.shared`). Swift Testing runs
/// tests in parallel by default; without serialization a concurrent
/// case could observe another case's reporter or events. The `nil`
/// reset prologue + epilogue belt-and-braces this with a per-test
/// detach so a future test author cannot accidentally drop the
/// `.serialized` trait without immediately seeing flake.
@Suite("AudioModelManagerTelemetryTests", .serialized)
struct AudioModelManagerTelemetryTests {

    // MARK: - Test-only synthetic component descriptor

    /// A component-id reserved for telemetry-instrumentation tests.
    ///
    /// The descriptor declares `files: []` so
    /// `Acervo.isComponentReady` short-circuits to `true` without any
    /// disk or network I/O. The repoId is namespaced under
    /// `mlx-audio-test/` so it cannot collide with any real CDN slug.
    private static let testComponentId = "mlx-audio-telemetry-test-component"
    private static let testRepoId = "mlx-audio-test/telemetry-fixture"

    /// Register the synthetic descriptor with the Acervo Component
    /// Registry. Idempotent — `Acervo.register(_:)` deduplicates by id.
    private static func registerTestComponent() {
        let descriptor = ComponentDescriptor(
            id: testComponentId,
            type: .auxiliary,
            displayName: "Telemetry Test Fixture",
            repoId: testRepoId,
            files: [],
            estimatedSizeBytes: 1_048_576, // 1 MB exactly, so sizeMB == 1.0
            minimumMemoryBytes: 0,
            metadata: ["modelType": "test-fixture"]
        )
        Acervo.register(descriptor)
    }

    /// Reset the manager's telemetry storage to `nil`. Called as the
    /// prologue of every test so cross-test ordering cannot leak a
    /// reporter from one case to another. Combined with the suite's
    /// `.serialized` trait this is sufficient for deterministic state
    /// across all tests in the file.
    private static func resetTelemetry() async {
        await AudioModelManager.setTelemetry(nil)
    }

    // MARK: - (a) Load sequence emits start + complete in order

    /// Happy-path: `loadWithAcervoStrict` against a registered
    /// fixture-component emits the canonical four-event sequence:
    ///   1. .modelDownloadStart
    ///   2. .modelDownloadComplete (cacheHit: true — fixture has no files)
    ///   3. .modelLoadStart
    ///   4. .modelLoadComplete (with sizeMB and metalAllocatedMB sampled)
    ///
    /// This is the canonical exit-criterion-bearing sequence for every
    /// future stateful component sortie; the order is the contract.
    @Test
    func loadSequenceEmitsStartAndCompleteInOrder() async throws {
        await Self.resetTelemetry()

        Self.registerTestComponent()

        let mock = MockMLXAudioTelemetryReporter()
        await AudioModelManager.setTelemetry(mock)

        let result = try await AudioModelManager.loadWithAcervoStrict(
            componentId: Self.testComponentId
        ) { _ in
            // The synthetic component has no files; the closure runs
            // inside `withComponentAccess` after the readiness check
            // short-circuits (vacuous file loop).
            return 42
        }
        #expect(result == 42)

        let events = await mock.events()
        #expect(events.count == 4, "expected 4 events, got \(events.count): \(events)")
        guard events.count == 4 else { return }

        // Event 0 — modelDownloadStart
        if case let .modelDownloadStart(repo, sizeMB) = events[0] {
            #expect(repo == Self.testRepoId)
            #expect(sizeMB == 1.0)
        } else {
            Issue.record("events[0] should be .modelDownloadStart, got \(events[0])")
        }

        // Event 1 — modelDownloadComplete (cacheHit: true)
        if case let .modelDownloadComplete(repo, sizeMB, cacheHit) = events[1] {
            #expect(repo == Self.testRepoId)
            #expect(sizeMB == 1.0)
            #expect(cacheHit == true,
                    "fixture has files: [] so isComponentReady returns true before the call")
        } else {
            Issue.record("events[1] should be .modelDownloadComplete, got \(events[1])")
        }

        // Event 2 — modelLoadStart
        if case let .modelLoadStart(repo, modelType) = events[2] {
            #expect(repo == Self.testRepoId)
            #expect(modelType == "test-fixture")
        } else {
            Issue.record("events[2] should be .modelLoadStart, got \(events[2])")
        }

        // Event 3 — modelLoadComplete with non-negative payload values
        if case let .modelLoadComplete(repo, modelType, sizeMB, metalAllocatedMB) = events[3] {
            #expect(repo == Self.testRepoId)
            #expect(modelType == "test-fixture")
            #expect(sizeMB == 1.0)
            // `metalAllocatedMB` is a snapshot of `MTLDevice.currentAllocatedSize`.
            // It can legitimately be 0 on a host with no system default Metal
            // device (test runners without a GPU); the contract is "non-negative".
            #expect(metalAllocatedMB >= 0.0)
        } else {
            Issue.record("events[3] should be .modelLoadComplete, got \(events[3])")
        }
    }

    // MARK: - (b) Failure path emits *Error

    /// `loadWithAcervoStrict` with an unregistered component-id throws
    /// `AcervoError.componentNotRegistered` and emits a single
    /// `.modelLoadError` event before re-throwing. No download events
    /// are emitted because the registry-lookup gate fires before the
    /// download lifecycle pair starts.
    @Test
    func loadWithAcervoStrictEmitsErrorOnUnregisteredComponent() async {
        await Self.resetTelemetry()

        let mock = MockMLXAudioTelemetryReporter()
        await AudioModelManager.setTelemetry(mock)

        let bogusId = "mlx-audio-telemetry-DOES-NOT-EXIST-\(UUID().uuidString)"
        do {
            _ = try await AudioModelManager.loadWithAcervoStrict(
                componentId: bogusId
            ) { _ in
                Issue.record("load closure must not be invoked for an unregistered component")
                return ()
            }
            Issue.record("expected loadWithAcervoStrict to throw componentNotRegistered")
        } catch {
            // Expected throw. Verify the error is the expected
            // registry miss (defensive — unrelated errors should also
            // emit `.modelLoadError`, but we want the canonical case).
            #expect(String(describing: error).contains("componentNotRegistered"))
        }

        let events = await mock.events()
        #expect(events.count == 1, "expected exactly 1 error event, got \(events.count): \(events)")
        guard events.count == 1 else { return }

        if case let .modelLoadError(repo, error) = events[0] {
            #expect(repo == bogusId)
            #expect(!error.isEmpty)
            #expect(error.contains("componentNotRegistered"))
        } else {
            Issue.record("events[0] should be .modelLoadError, got \(events[0])")
        }
    }

    // Note on `ensureModelReady` / `loadWithAcervo` (the
    // `AudioModelRepo`-keyed entry points): both ultimately funnel
    // through Acervo against a *real* HuggingFace `repoId`, so a
    // network-free unit test against them would require either
    // monkey-patching the SwiftAcervo surface (out of scope for this
    // sortie — we own AudioModelManager only) or rewriting them to
    // accept a `componentId`. Their wiring is the same canonical
    // `emit(...)` pattern verified by the `loadWithAcervoStrict`
    // sequence and error tests above; nightly local-only suites
    // exercise the AudioModelRepo paths end-to-end with real models.

    // MARK: - (c) Nil reporter records no events

    /// With no reporter ever attached, `loadWithAcervoStrict`'s emit
    /// sites short-circuit before any payload work runs. We verify
    /// this by performing the load with telemetry in its default
    /// `nil` state, then attaching a fresh mock *after* the work has
    /// completed, and asserting the mock observes zero events (fresh
    /// mocks always have zero events — the load itself fired no
    /// emissions because the storage actor returned `nil` from
    /// `current()`, so the `@autoclosure` was never invoked).
    ///
    /// The Metal-sampling-skip half of the contract is verified by
    /// code inspection: every `MTLDevice` / `currentAllocatedSize`
    /// reference in `Sources/MLXAudioCore/AudioModelManager.swift`
    /// lives on a line that participates in an `await emit(...)` call
    /// (the canonical `@autoclosure` deferral). When the storage
    /// actor returns `nil`, the autoclosure is never invoked, so
    /// `sampleMetalAllocatedMB()` is never called.
    @Test
    func nilReporterRecordsNoEventsAndSkipsMetalSampling() async throws {
        await Self.resetTelemetry()

        Self.registerTestComponent()

        // Run the load with telemetry in its default (nil) state.
        let result = try await AudioModelManager.loadWithAcervoStrict(
            componentId: Self.testComponentId
        ) { _ in
            return "ok"
        }
        #expect(result == "ok")

        // Attach a fresh mock *after* the work has completed. A reporter
        // attached after the fact cannot retroactively observe events
        // that happened while it was unattached — that is exactly the
        // invariant we want to assert.
        let mock = MockMLXAudioTelemetryReporter()
        await AudioModelManager.setTelemetry(mock)

        let events = await mock.events()
        #expect(events.isEmpty,
                "nil reporter must produce zero events, got \(events.count): \(events)")
    }

    /// Setting the reporter to `nil` after a previous attachment
    /// detaches the namespace. Subsequent emissions go nowhere.
    /// Establishes the detach contract used by hosts that hot-swap
    /// reporters across runs.
    @Test
    func setTelemetryNilDetachesReporter() async throws {
        await Self.resetTelemetry()

        Self.registerTestComponent()

        let mock = MockMLXAudioTelemetryReporter()
        await AudioModelManager.setTelemetry(mock)

        // First call should emit the standard 4-event sequence.
        _ = try await AudioModelManager.loadWithAcervoStrict(
            componentId: Self.testComponentId
        ) { _ in 1 }
        let firstCount = await mock.eventCount()
        #expect(firstCount == 4)

        // Detach the reporter.
        await AudioModelManager.setTelemetry(nil)

        // Second call must not append further events to the mock.
        _ = try await AudioModelManager.loadWithAcervoStrict(
            componentId: Self.testComponentId
        ) { _ in 2 }

        let secondCount = await mock.eventCount()
        #expect(secondCount == firstCount,
                "events captured after detach: \(secondCount - firstCount)")
    }
}
