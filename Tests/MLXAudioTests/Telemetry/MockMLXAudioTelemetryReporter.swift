//
//  MockMLXAudioTelemetryReporter.swift
//  MLXAudioTests
//
//  Sortie 1 of OPERATION SILENT STETHOSCOPE — shared test-double for
//  every downstream instrumentation sortie.
//
//  This actor stores a chronologically ordered list of every event
//  captured during a test. It is intentionally a Swift `actor` (not an
//  `@MainActor` class) so:
//
//    1. Concurrent emission from multiple isolation contexts (e.g. a
//       stateful TTS model on a background actor calling `capture(_:)`
//       while a codec on another actor does the same) is serialized
//       safely.
//    2. Tests can read a stable snapshot of recorded events via
//       `events()` without forcing the workload onto the main actor.
//
//  Lives in the test target (not the library) because the library
//  ships only `NoopMLXAudioTelemetryReporter`. Downstream tests in
//  `Tests/MLXAudioTests/Telemetry/` use this mock by simple
//  same-target visibility (no @testable import needed).
//

import Foundation

@testable import MLXAudioCore

/// Test-only telemetry reporter that records every captured event in
/// order. Shared by every instrumentation sortie's tests.
///
/// Usage:
///
/// ```swift
/// let mock = MockMLXAudioTelemetryReporter()
/// await someComponent.setTelemetry(mock)
/// // ... exercise component ...
/// let events = await mock.events()
/// #expect(events.count == 2)
/// ```
///
/// Concurrency: `actor`-isolated. Safe to share across tasks. Reads
/// return a value-type snapshot of the underlying buffer so callers
/// can iterate without holding actor isolation.
actor MockMLXAudioTelemetryReporter: MLXAudioTelemetryReporter {

    /// Backing storage. Mutated only via `capture(_:)`. Read via
    /// ``events()`` (which returns a copy).
    private var captured: [MLXAudioTelemetryEvent] = []

    /// Create an empty mock.
    init() {}

    /// Record an event. Conforms to ``MLXAudioTelemetryReporter``.
    func capture(_ event: MLXAudioTelemetryEvent) async {
        captured.append(event)
    }

    /// Return a snapshot copy of every event recorded so far.
    ///
    /// The returned array is a value-type copy — mutating it does not
    /// affect the actor's internal buffer.
    func events() -> [MLXAudioTelemetryEvent] {
        captured
    }

    /// Number of events recorded so far. Convenience for tests that
    /// only need a count.
    func eventCount() -> Int {
        captured.count
    }

    /// Discard every recorded event. Useful between scenarios within
    /// the same test instance.
    func reset() {
        captured.removeAll(keepingCapacity: true)
    }
}
