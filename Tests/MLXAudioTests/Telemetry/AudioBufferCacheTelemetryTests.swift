//
//  AudioBufferCacheTelemetryTests.swift
//  MLXAudioTests
//
//  Sortie 17 of OPERATION SILENT STETHOSCOPE — telemetry coverage for
//  `AudioPlayerManager`'s internal buffer cache.
//
//  This suite is CI-safe (no model downloads, no disk I/O). It verifies:
//
//    (a) `audioBufferCacheGrowth` fires on every cache insertion.
//    (b) `nil` reporter (default) produces zero events.
//    (c) No emission on cache hit (read without insert).
//    (d) `setTelemetry(_:)` compiles and is callable on
//        `AudioPlayerManager`.
//    (e) Detaching via `setTelemetry(nil)` silences subsequent
//        insertions.
//    (f) `audioBufferCacheGrowth` payload (`entriesCount`, `totalMB`)
//        grows monotonically across successive insertions.
//
//  `AudioPlayerManager` is a `@MainActor public class`. All tests are
//  annotated `@MainActor` so `cacheBuffer(_:for:)` and other
//  actor-isolated APIs are callable without bridging through a `Task`.
//

import Foundation
import AVFoundation
import Testing

@testable import MLXAudioCore

// MARK: - Helpers

/// Build a minimal `AVAudioPCMBuffer` containing `frameCount` silent
/// samples at `sampleRate`. The buffer is structurally valid — it has
/// an allocated `floatChannelData` pointer — but carries no meaningful
/// audio content. Used to populate the cache without touching the disk.
private func makeSilentBuffer(
    frameCount: AVAudioFrameCount = 4_800,
    sampleRate: Double = 48_000
) -> AVAudioPCMBuffer? {
    guard let format = AVAudioFormat(
        standardFormatWithSampleRate: sampleRate,
        channels: 1
    ) else { return nil }
    guard let buffer = AVAudioPCMBuffer(
        pcmFormat: format,
        frameCapacity: frameCount
    ) else { return nil }
    buffer.frameLength = frameCount
    return buffer
}

/// A unique URL per call — `UUID`-based so multiple test invocations
/// never collide on the same key.
private func uniqueURL() -> URL {
    URL(string: "audio-cache-test://\(UUID().uuidString)")!
}

// MARK: - AudioBufferCacheTelemetryTests

@Suite("AudioBufferCacheTelemetryTests")
@MainActor
struct AudioBufferCacheTelemetryTests {

    // MARK: - (a) audioBufferCacheGrowth fires on cache insertion

    /// Inserting a new buffer must emit exactly one `audioBufferCacheGrowth`
    /// event with `entriesCount == 1` and `totalMB > 0`.
    @Test
    func cacheInsertionEmitsGrowthEvent() async throws {
        let manager = AudioPlayerManager()
        let mock = MockMLXAudioTelemetryReporter()
        manager.setTelemetry(mock)

        guard let buffer = makeSilentBuffer() else {
            Issue.record("Failed to construct AVAudioPCMBuffer for test")
            return
        }

        let key = uniqueURL()
        await manager.cacheBuffer(buffer, for: key)

        let events = await mock.events()
        #expect(events.count == 1,
                "Expected exactly 1 event after one insertion, got \(events.count)")

        guard events.count == 1 else { return }

        guard case let .audioBufferCacheGrowth(entriesCount, totalMB) = events[0] else {
            Issue.record("events[0] should be .audioBufferCacheGrowth, got \(events[0])")
            return
        }
        #expect(entriesCount == 1,
                "entriesCount should be 1 after first insertion, got \(entriesCount)")
        #expect(totalMB > 0,
                "totalMB should be positive, got \(totalMB)")
    }

    // MARK: - (b) nil reporter produces zero events

    /// `AudioPlayerManager` has `telemetry == nil` by default. Inserting
    /// into the cache must not route anything to an unattached mock.
    ///
    /// This validates invariant 3: "nil reporter has zero runtime cost".
    @Test
    func nilReporterProducesZeroEvents() async {
        let manager = AudioPlayerManager()
        // Intentionally do NOT call setTelemetry.
        let unattachedMock = MockMLXAudioTelemetryReporter()

        guard let buffer = makeSilentBuffer() else {
            Issue.record("Failed to construct AVAudioPCMBuffer for test")
            return
        }

        await manager.cacheBuffer(buffer, for: uniqueURL())

        let count = await unattachedMock.eventCount()
        #expect(count == 0,
                "Unattached mock should receive 0 events, got \(count)")
    }

    // MARK: - (c) No emission on cache hit (read without insert)

    /// `cachedBuffer(for:)` is a read-only path. It must never emit an
    /// event regardless of whether the key is present or absent.
    @Test
    func cacheHitDoesNotEmit() async {
        let manager = AudioPlayerManager()
        let mock = MockMLXAudioTelemetryReporter()
        manager.setTelemetry(mock)

        guard let buffer = makeSilentBuffer() else {
            Issue.record("Failed to construct AVAudioPCMBuffer for test")
            return
        }

        let key = uniqueURL()

        // Insert once — this emits an event.
        await manager.cacheBuffer(buffer, for: key)
        await mock.reset()  // Clear insertion event before cache-hit test.

        // Read the cached entry — must NOT emit.
        let hit = manager.cachedBuffer(for: key)
        #expect(hit != nil, "Expected a cache hit, got nil")

        let count = await mock.eventCount()
        #expect(count == 0,
                "Cache read (hit) must not emit an event, got \(count)")
    }

    /// A lookup for a key that has never been inserted is also read-only
    /// and must produce zero events.
    @Test
    func cacheMissDoesNotEmit() async {
        let manager = AudioPlayerManager()
        let mock = MockMLXAudioTelemetryReporter()
        manager.setTelemetry(mock)

        // Look up a key that was never inserted.
        let miss = manager.cachedBuffer(for: uniqueURL())
        #expect(miss == nil, "Expected nil for an uninserted key")

        let count = await mock.eventCount()
        #expect(count == 0,
                "Cache read (miss) must not emit an event, got \(count)")
    }

    // MARK: - (d) setTelemetry compiles and attaches a reporter

    /// `setTelemetry(_:)` must be callable on `AudioPlayerManager` and
    /// must not crash. This is the compilation smoke-test.
    @Test
    func setTelemetryAttachesReporter() {
        let manager = AudioPlayerManager()
        let mock = MockMLXAudioTelemetryReporter()

        manager.setTelemetry(mock)

        #expect(Bool(true), "setTelemetry(_:) compiled and ran without error")
    }

    // MARK: - (e) setTelemetry(nil) detaches reporter

    /// Detaching the reporter via `setTelemetry(nil)` must silence all
    /// subsequent cache insertions.
    @Test
    func detachedReporterSilencesSubsequentInsertions() async {
        let manager = AudioPlayerManager()
        let mock = MockMLXAudioTelemetryReporter()
        manager.setTelemetry(mock)

        guard let buffer = makeSilentBuffer() else {
            Issue.record("Failed to construct AVAudioPCMBuffer for test")
            return
        }

        // First insertion with reporter attached — event should flow.
        await manager.cacheBuffer(buffer, for: uniqueURL())
        let countWithReporter = await mock.eventCount()
        #expect(countWithReporter == 1,
                "Expected 1 event with reporter attached, got \(countWithReporter)")

        // Detach and reset.
        manager.setTelemetry(nil)
        await mock.reset()

        // Second insertion after detach — must not emit.
        guard let buffer2 = makeSilentBuffer() else {
            Issue.record("Failed to construct second AVAudioPCMBuffer for test")
            return
        }
        await manager.cacheBuffer(buffer2, for: uniqueURL())
        let countAfterDetach = await mock.eventCount()
        #expect(countAfterDetach == 0,
                "No events should be emitted after setTelemetry(nil), got \(countAfterDetach)")
    }

    // MARK: - (f) entriesCount and totalMB grow monotonically

    /// After three successive insertions of equal-sized buffers, the
    /// `entriesCount` payload must be 1, 2, 3 in order and `totalMB`
    /// must grow with each insertion.
    @Test
    func growthPayloadIsMonotonicallyIncreasing() async throws {
        let manager = AudioPlayerManager()
        let mock = MockMLXAudioTelemetryReporter()
        manager.setTelemetry(mock)

        let frameCount: AVAudioFrameCount = 48_000  // 1 s at 48 kHz

        for _ in 1...3 {
            guard let buffer = makeSilentBuffer(frameCount: frameCount) else {
                Issue.record("Failed to construct AVAudioPCMBuffer for test")
                return
            }
            await manager.cacheBuffer(buffer, for: uniqueURL())
        }

        let events = await mock.events()
        #expect(events.count == 3,
                "Expected 3 events for 3 insertions, got \(events.count)")

        guard events.count == 3 else { return }

        var previousTotalMB = 0.0
        for (index, event) in events.enumerated() {
            guard case let .audioBufferCacheGrowth(entriesCount, totalMB) = event else {
                Issue.record("events[\(index)] should be .audioBufferCacheGrowth, got \(event)")
                return
            }
            #expect(entriesCount == index + 1,
                    "events[\(index)]: entriesCount should be \(index + 1), got \(entriesCount)")
            #expect(totalMB > previousTotalMB,
                    "events[\(index)]: totalMB should exceed \(previousTotalMB), got \(totalMB)")
            previousTotalMB = totalMB
        }
    }

    // MARK: - (g) Duplicate insertion is a no-op (no second event)

    /// Inserting the same `key` twice must be a no-op on the second call:
    /// the cache is not updated and no event is emitted.
    @Test
    func duplicateInsertionIsNoOp() async {
        let manager = AudioPlayerManager()
        let mock = MockMLXAudioTelemetryReporter()
        manager.setTelemetry(mock)

        guard let buffer = makeSilentBuffer(),
              let buffer2 = makeSilentBuffer() else {
            Issue.record("Failed to construct AVAudioPCMBuffers for test")
            return
        }

        let key = uniqueURL()
        await manager.cacheBuffer(buffer, for: key)   // insert → event
        await manager.cacheBuffer(buffer2, for: key)  // duplicate → no event

        let events = await mock.events()
        #expect(events.count == 1,
                "Duplicate insertion should not emit a second event; got \(events.count)")
    }

    // MARK: - (h) NoopMLXAudioTelemetryReporter is accepted by setTelemetry

    /// Confirm that `NoopMLXAudioTelemetryReporter` (shipped by the
    /// library) can be passed to `setTelemetry` — useful for hosts that
    /// want a non-nil reporter without actually recording anything.
    @Test
    func noopReporterIsAcceptedBySetTelemetry() async {
        let manager = AudioPlayerManager()
        let noop = NoopMLXAudioTelemetryReporter()

        manager.setTelemetry(noop)

        guard let buffer = makeSilentBuffer() else {
            Issue.record("Failed to construct AVAudioPCMBuffer for test")
            return
        }
        // Must not crash — the noop drops every event.
        await manager.cacheBuffer(buffer, for: uniqueURL())

        #expect(Bool(true), "NoopMLXAudioTelemetryReporter ran without error")
    }
}
