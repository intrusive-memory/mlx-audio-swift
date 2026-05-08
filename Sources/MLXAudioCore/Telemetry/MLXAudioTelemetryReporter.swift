//
//  MLXAudioTelemetryReporter.swift
//  MLXAudioCore
//
//  Sortie 1 of OPERATION SILENT STETHOSCOPE — public, vendor-neutral
//  telemetry reporter protocol for mlx-audio-swift.
//
//  Hosts (e.g. Produciesta) attach a reporter that conforms to this
//  protocol and forwards events to their own sink. The library itself
//  never imports a host and never depends on a logging framework —
//  the reporter is the only seam between the library and the outside
//  world.
//
//  Invariants (REQUIREMENTS §6):
//    1. Library never imports Produciesta or any host.
//    2. No new dependencies (no swift-log / Logging / OSLog here).
//    3. Default is silent — `nil` reporter has zero runtime cost.
//    4. One enum, one protocol, one library.
//    5. Reporter is `async` non-throwing.
//    6. Every emission site uses `@autoclosure` so payload work runs
//       only when a reporter is attached (see canonical helper below).
//

import Foundation

/// A vendor-neutral sink for ``MLXAudioTelemetryEvent`` values.
///
/// Hosts implement this protocol to observe lifecycle events emitted
/// by mlx-audio-swift components (model managers, TTS / STT models,
/// codecs, and audio I/O helpers). The library itself never inspects
/// or produces a concrete reporter beyond
/// ``NoopMLXAudioTelemetryReporter`` — concrete reporters live in the
/// host repository and translate library events into host vocabulary.
///
/// ## Contract
///
/// - `Sendable`-bound, exactly one method, named ``capture(_:)``.
/// - `async` — reporters may write to disk or hop actors without
///   blocking the workload.
/// - **Non-throwing** — telemetry that can fail the workload is
///   unusable. Reporters swallow their own failures.
///
/// ## Adoption pattern (stateful components)
///
/// Stateful components (`AudioModelManager`, every TTS / STT class,
/// every codec) store an optional reporter and expose a setter:
///
/// ```swift
/// public actor AudioModelManager {
///     private var telemetry: (any MLXAudioTelemetryReporter)? = nil
///
///     public func setTelemetry(_ reporter: (any MLXAudioTelemetryReporter)?) {
///         self.telemetry = reporter
///     }
///
///     // Canonical per-instance emit helper (see below).
/// }
/// ```
///
/// Free / static functions take a defaulted parameter instead so
/// existing call sites compile unchanged:
///
/// ```swift
/// public static func loadAudioArray(
///     _ path: String,
///     telemetry: (any MLXAudioTelemetryReporter)? = nil
/// ) throws -> (MLXArray, Int)
/// ```
///
/// ## Canonical per-instance `emit(_:)` helper
///
/// **Copy this snippet verbatim into every instrumented class.** It is
/// intentionally not extracted into a shared utility — `telemetry` is
/// per-instance state and `@autoclosure` must close over the instance
/// so the payload-construction closure can read members without going
/// through an extra hop.
///
/// ```swift
/// private func emit(_ event: @autoclosure () -> MLXAudioTelemetryEvent) async {
///     guard let telemetry else { return }
///     await telemetry.capture(event())
/// }
/// ```
///
/// The `@autoclosure` is load-bearing: it is what makes invariant 3
/// ("default is silent — `nil` reporter has zero runtime cost") true.
/// When `telemetry` is `nil`, the closure is never invoked, so any
/// expensive payload work — Metal memory snapshots, `String(describing:)`
/// formatting on errors, multiplications for compression ratios — is
/// elided entirely.
///
/// Call sites pass the event directly; the autoclosure wraps it for
/// you:
///
/// ```swift
/// await emit(.modelLoadStart(repo: repo, modelType: modelType))
/// ```
///
/// ## Anti-patterns
///
/// - Do **not** make `capture(_:)` `throws` — the workload must never
///   fail because a reporter's disk filled.
/// - Do **not** introduce a `default:` arm in adapter `switch`
///   statements — new event cases should be compile-time gaps in
///   adapters by design.
/// - Do **not** sample / throttle inside the library — adapters own
///   policy. The library always emits.
/// - Do **not** emit inside per-step decode loops or per-frame
///   playback loops. Sample at coarse-grained boundaries only.
public protocol MLXAudioTelemetryReporter: Sendable {

    /// Capture a single telemetry event.
    ///
    /// Implementations are free to forward, drop, aggregate, or persist
    /// the event. Implementations must not throw and must not mutate
    /// the event payload.
    func capture(_ event: MLXAudioTelemetryEvent) async
}

/// A reporter that drops every event.
///
/// Useful for:
///
/// - Tests that only need to satisfy the protocol's existence.
/// - Hosts that want to satisfy a non-optional reporter API without
///   actually observing anything yet.
///
/// The `nil` storage pattern (`var telemetry: (any MLXAudioTelemetryReporter)? = nil`)
/// is the recommended way to express "no telemetry attached" inside
/// the library — `NoopMLXAudioTelemetryReporter` is for outside the
/// library.
public struct NoopMLXAudioTelemetryReporter: MLXAudioTelemetryReporter {

    /// Create a noop reporter.
    public init() {}

    /// Drops the event. Cost: one async hop, zero side effects.
    public func capture(_ event: MLXAudioTelemetryEvent) async {
        // Intentionally empty.
    }
}
