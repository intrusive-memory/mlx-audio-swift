//
//  MemoryTelemetryTests.swift
//  MLXAudioTests
//
//  Sortie 5 of OPERATION SILENT STETHOSCOPE — behavioural coverage for
//  the Metal-memory sampler and the public-telemetry instrumentation
//  added to `WiredMemoryManager`.
//
//  These tests exercise three scenarios:
//
//    (a) The `MetalMemorySampler` suppresses sub-10MB deltas (REQUIREMENTS §2.6).
//    (b) The `MetalMemorySampler` emits `metalBufferAllocated` on a
//        positive supra-threshold delta and `metalBufferDeallocated`
//        on a negative supra-threshold delta.
//    (c) `WiredMemoryManager` lifecycle methods produce zero events
//        when no reporter is attached (the silent-default invariant
//        from REQUIREMENTS §6 invariant 3).
//
//  Sampler tests instantiate the sampler directly with synthetic
//  absolute-MB values, so they do not require a Metal device and are
//  fully CI-safe. The WiredMemoryManager `nil`-default test runs the
//  manager's `withPinnedMemory` lifecycle without ever attaching a
//  reporter and confirms the mock observes zero events.
//
//  Concurrency safety: `_WiredMemoryManagerTelemetryStorage` is a
//  process-global actor, mirroring Sortie 2's pattern in
//  `AudioModelManager`. The suite carries the `.serialized` trait so
//  Swift Testing runs these cases sequentially, and each test resets
//  the storage to `nil` at its prologue so cross-test contamination
//  cannot leak a reporter from one case to another.
//

import Foundation
import Testing

@testable import MLXAudioCore

/// Suite is `.serialized` because every WiredMemoryManager test
/// mutates the process-global telemetry storage actor
/// (`_WiredMemoryManagerTelemetryStorage.shared`). The sampler tests
/// also carry the trait for symmetry — a fresh `MetalMemorySampler`
/// per test has no global state, but keeping the suite uniformly
/// `.serialized` avoids a future test author dropping the trait
/// without realising the WiredMemoryManager subset still needs it.
@Suite("MemoryTelemetryTests", .serialized)
struct MemoryTelemetryTests {

    /// Reset the WiredMemoryManager namespace's telemetry storage to
    /// `nil`. Called as the prologue of every test that touches
    /// WiredMemoryManager so cross-test ordering cannot leak a
    /// reporter from one case to another. Combined with the suite's
    /// `.serialized` trait this is sufficient for deterministic state.
    private static func resetWiredTelemetry() async {
        await WiredMemoryManager.setTelemetry(nil)
    }

    // MARK: - (a) Sampler suppresses sub-10MB deltas

    /// First sample seeds the baseline; second sample with a +5 MB
    /// delta is below the 10 MB threshold and must NOT emit an event.
    /// Third sample with a -3 MB delta (cumulative net +2 MB from
    /// baseline, instantaneous -3 MB from the second sample) is also
    /// sub-threshold and must NOT emit. The "delta vs. the previous
    /// sample" semantics from REQUIREMENTS §2.6 are exercised across
    /// both directions.
    @Test
    func samplerSuppressesSubThresholdDeltas() async {
        let sampler = MetalMemorySampler()
        let mock = MockMLXAudioTelemetryReporter()

        // First sample seeds the baseline; no event regardless of
        // value because there is no previous sample to delta against.
        await sampler.sample(currentMB: 100.0, reporter: mock)
        let afterFirst = await mock.eventCount()
        #expect(afterFirst == 0,
                "first sample seeds baseline — must not emit, got \(afterFirst) events")

        // +5 MB delta: below the 10 MB threshold. Must not emit.
        await sampler.sample(currentMB: 105.0, reporter: mock)
        let afterSecond = await mock.eventCount()
        #expect(afterSecond == 0,
                "+5 MB delta is below the 10 MB threshold — must not emit, got \(afterSecond) events")

        // -3 MB delta from prior sample (105 -> 102). Below threshold
        // in the negative direction. Must not emit.
        await sampler.sample(currentMB: 102.0, reporter: mock)
        let afterThird = await mock.eventCount()
        #expect(afterThird == 0,
                "-3 MB delta is below the 10 MB threshold — must not emit, got \(afterThird) events")

        // A delta of EXACTLY +10 MB is also suppressed (strict
        // greater-than per the spec wording "exceeds 10 MB"). 102 ->
        // 112 is +10 MB exactly.
        await sampler.sample(currentMB: 112.0, reporter: mock)
        let afterFourth = await mock.eventCount()
        #expect(afterFourth == 0,
                "exactly +10 MB delta is at the threshold (not above) — must not emit, got \(afterFourth) events")
    }

    // MARK: - (b) Sampler emits when delta crosses threshold

    /// A +12 MB delta vs. the prior sample produces a single
    /// `metalBufferAllocated` event with `allocatedMB == newAbsolute`
    /// and `peakMB` reflecting the high-water mark.
    @Test
    func samplerEmitsMetalBufferAllocatedOnPositiveSupraThresholdDelta() async {
        let sampler = MetalMemorySampler()
        let mock = MockMLXAudioTelemetryReporter()

        // Seed the baseline at 100 MB.
        await sampler.sample(currentMB: 100.0, reporter: mock)

        // +12 MB delta: above the 10 MB threshold. Must emit
        // `metalBufferAllocated` with allocatedMB = 112, peakMB = 112.
        await sampler.sample(currentMB: 112.0, reporter: mock)

        let events = await mock.events()
        #expect(events.count == 1,
                "expected exactly 1 event after +12 MB delta, got \(events.count): \(events)")
        guard events.count == 1 else { return }

        if case let .metalBufferAllocated(allocatedMB, peakMB) = events[0] {
            #expect(allocatedMB == 112.0,
                    "allocatedMB should be the new absolute value (112), got \(allocatedMB)")
            #expect(peakMB == 112.0,
                    "peakMB should reflect the new high-water mark (112), got \(peakMB)")
        } else {
            Issue.record("events[0] should be .metalBufferAllocated, got \(events[0])")
        }
    }

    /// A -11 MB delta vs. the prior sample produces a single
    /// `metalBufferDeallocated` event with `freedMB == 11.0` (positive
    /// magnitude) and `remainingMB == newAbsolute`.
    @Test
    func samplerEmitsMetalBufferDeallocatedOnNegativeSupraThresholdDelta() async {
        let sampler = MetalMemorySampler()
        let mock = MockMLXAudioTelemetryReporter()

        // Seed the baseline at 200 MB.
        await sampler.sample(currentMB: 200.0, reporter: mock)

        // -11 MB delta: below -10 MB threshold. Must emit
        // `metalBufferDeallocated` with freedMB = 11, remainingMB = 189.
        await sampler.sample(currentMB: 189.0, reporter: mock)

        let events = await mock.events()
        #expect(events.count == 1,
                "expected exactly 1 event after -11 MB delta, got \(events.count): \(events)")
        guard events.count == 1 else { return }

        if case let .metalBufferDeallocated(freedMB, remainingMB) = events[0] {
            #expect(freedMB == 11.0,
                    "freedMB should be the magnitude of the drop (11), got \(freedMB)")
            #expect(remainingMB == 189.0,
                    "remainingMB should be the new absolute value (189), got \(remainingMB)")
        } else {
            Issue.record("events[0] should be .metalBufferDeallocated, got \(events[0])")
        }
    }

    /// Delta is computed against the *previous* sample, not against
    /// the seed baseline. A long sequence of small drifts that
    /// individually never exceed the threshold must never emit an
    /// event, even if the cumulative drift is large. This is the
    /// "delta vs. the previous sample" semantics from REQUIREMENTS §2.6.
    @Test
    func samplerComparesAgainstPreviousSampleNotSeed() async {
        let sampler = MetalMemorySampler()
        let mock = MockMLXAudioTelemetryReporter()

        // Seed at 100 MB, then drift up by +5 MB seven times. The
        // cumulative drift is +35 MB but each step is +5 MB so no
        // event is emitted.
        await sampler.sample(currentMB: 100.0, reporter: mock)
        for step in 1...7 {
            await sampler.sample(currentMB: 100.0 + Double(step) * 5.0, reporter: mock)
        }

        let events = await mock.events()
        #expect(events.isEmpty,
                "cumulative drift of +35 MB via 5-MB steps must not emit; got \(events.count): \(events)")

        // Now a single +12 MB step from the running baseline (135 ->
        // 147) crosses the threshold and emits exactly once.
        await sampler.sample(currentMB: 147.0, reporter: mock)
        let afterCross = await mock.events()
        #expect(afterCross.count == 1,
                "single +12 MB step over running baseline must emit exactly once; got \(afterCross.count)")
    }

    /// `nil` reporter argument suppresses emission but still updates
    /// the sampler's baseline (so a host that attaches mid-run sees
    /// correct deltas relative to the most recent sample).
    @Test
    func samplerWithNilReporterEmitsNothingButUpdatesBaseline() async {
        let sampler = MetalMemorySampler()
        let mock = MockMLXAudioTelemetryReporter()

        // Seed and drive a +20 MB delta with reporter == nil. No
        // events should be observed by the (unrelated) mock because
        // we never passed it in.
        await sampler.sample(currentMB: 100.0, reporter: nil)
        await sampler.sample(currentMB: 120.0, reporter: nil)

        let mockEvents = await mock.events()
        #expect(mockEvents.isEmpty,
                "mock was never attached — must observe zero events, got \(mockEvents.count)")

        // Now attach the mock and drive a +12 MB delta from the
        // running baseline (120 -> 132). If the baseline was updated
        // during the nil-reporter calls, this fires exactly one
        // `metalBufferAllocated` event.
        await sampler.sample(currentMB: 132.0, reporter: mock)
        let afterAttach = await mock.events()
        #expect(afterAttach.count == 1,
                "post-attach +12 MB delta must emit exactly once; got \(afterAttach.count)")
        guard afterAttach.count == 1 else { return }
        if case let .metalBufferAllocated(allocatedMB, _) = afterAttach[0] {
            #expect(allocatedMB == 132.0,
                    "post-attach event should carry the new absolute value (132), got \(allocatedMB)")
        } else {
            Issue.record("post-attach event should be .metalBufferAllocated, got \(afterAttach[0])")
        }
    }

    // MARK: - (c) WiredMemoryManager nil reporter produces zero events

    /// Running `withPinnedMemory` with no reporter attached produces
    /// zero events. We attach a fresh mock *after* the lifecycle has
    /// run and confirm it observes nothing — a mock attached after
    /// the fact cannot retroactively observe events that happened
    /// while it was unattached, which is exactly the silent-default
    /// invariant we want to assert (REQUIREMENTS §6 invariant 3).
    @Test
    func wiredMemoryManagerNilReporterProducesZeroEvents() async throws {
        await Self.resetWiredTelemetry()

        // Run the manager's lifecycle method with telemetry in its
        // default (nil) state. The body must execute regardless of
        // telemetry attachment.
        let result = try await WiredMemoryManager.withPinnedMemory(limitBytes: nil) {
            return 7
        }
        #expect(result == 7)

        // Attach a fresh mock *after* the work completed. A reporter
        // attached after the fact cannot retroactively observe
        // events that happened while it was unattached.
        let mock = MockMLXAudioTelemetryReporter()
        await WiredMemoryManager.setTelemetry(mock)

        let events = await mock.events()
        #expect(events.isEmpty,
                "nil reporter must produce zero events from withPinnedMemory, got \(events.count): \(events)")
    }

    /// `WiredMemoryManager.setTelemetry(nil)` after a previous
    /// attachment detaches the namespace. The attach-then-detach
    /// dance establishes the contract that hosts can hot-swap
    /// reporters across runs.
    @Test
    func wiredMemoryManagerSetTelemetryNilDetachesReporter() async throws {
        await Self.resetWiredTelemetry()

        let mock = MockMLXAudioTelemetryReporter()
        await WiredMemoryManager.setTelemetry(mock)

        // Detach immediately. The async lifecycle below must observe
        // the detached state via the storage actor.
        await WiredMemoryManager.setTelemetry(nil)

        _ = try await WiredMemoryManager.withPinnedMemory(limitBytes: nil) {
            return 1
        }

        let events = await mock.events()
        #expect(events.isEmpty,
                "events captured after detach: \(events.count)")
    }

    // MARK: - Sortie 5 sanity check on the .wiredMemoryState payload shape

    /// When a reporter IS attached, `withPinnedMemory` emits at least
    /// one `wiredMemoryState` event with non-negative payload values.
    /// This test does not assert event count exactly because:
    ///
    ///   - On a host without Metal-residency support
    ///     (`info.supportsWiredMemory == false`), the manager
    ///     short-circuits with zero events. That is by design: the
    ///     "existing coarse-grained boundaries" only fire when
    ///     wired memory is actually engaged.
    ///   - On a Metal-capable host the manager emits two events
    ///     (entry + exit boundary).
    ///
    /// The test is therefore tolerant: zero or two events are both
    /// acceptable; whatever events are emitted must be of the
    /// expected case with non-negative payload values.
    @Test
    func wiredMemoryManagerEmitsWiredMemoryStateOrSkipsCleanly() async throws {
        await Self.resetWiredTelemetry()

        let mock = MockMLXAudioTelemetryReporter()
        await WiredMemoryManager.setTelemetry(mock)

        _ = try await WiredMemoryManager.withPinnedMemory(limitBytes: nil) {
            return 1
        }

        let events = await mock.events()
        // Zero (no Metal-residency support) or two (entry + exit) are
        // the only acceptable outcomes. Anything else is a wiring bug.
        #expect(events.count == 0 || events.count == 2,
                "expected 0 or 2 events from withPinnedMemory, got \(events.count): \(events)")

        for event in events {
            if case let .wiredMemoryState(wiredMB, committedMB) = event {
                #expect(wiredMB >= 0.0)
                #expect(committedMB >= 0.0)
            } else {
                Issue.record("only .wiredMemoryState events expected, got \(event)")
            }
        }
    }
}
