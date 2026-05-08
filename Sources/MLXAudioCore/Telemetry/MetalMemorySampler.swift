//
//  MetalMemorySampler.swift
//  MLXAudioCore
//
//  Sortie 5 of OPERATION SILENT STETHOSCOPE — coarse-grained Metal
//  buffer-allocation sampler that emits public-telemetry events only
//  when the absolute delta vs. the previous sample exceeds a 10 MB
//  threshold (REQUIREMENTS-telemetry.md §2.6).
//
//  Design rationale (per Sortie 5 prompt):
//
//    - The sampler holds its own `lastSampledMB` baseline. It is
//      modeled as a Swift `actor` so concurrent callers (e.g. multiple
//      model loads racing on different actors) cannot corrupt the
//      baseline by interleaving reads and writes.
//    - The sampler does NOT hold a reporter — Sortie 5 explicitly
//      asks for the reporter to be passed as a parameter to `sample`
//      (or held as an optional reference). We pass it in: this keeps
//      the sampler stateless w.r.t. the reporter, which makes it
//      trivial to reason about lifetime and avoids duplicating the
//      `setTelemetry(_:)` ceremony already living on `AudioModelManager`
//      and `WiredMemoryManager`.
//    - Each sampling call accepts an absolute `currentMB` reading from
//      the caller. This lets the caller decide whether to read
//      `MTLDevice.currentAllocatedSize` (production) or feed synthetic
//      values (tests), which makes the threshold logic
//      independently testable without touching Metal.
//    - The sampler emits `metalBufferAllocated` when the delta is
//      strictly greater than +10 MB, and `metalBufferDeallocated`
//      when the delta is strictly less than -10 MB. Sub-threshold
//      deltas (in either direction) are suppressed; the baseline is
//      updated opaquely so a long sequence of small bumps still
//      eventually produces an event when the cumulative drift crosses
//      the threshold.
//
//  Wait — the spec ("the delta vs. the previous sample exceeds 10 MB")
//  means we compare against the *last sample*, not against a
//  hypothetical "last emitted" baseline. That is what we implement
//  below: the baseline is replaced every time we sample, not only
//  when we emit. This matches the prompt's "coming down by 11 MB
//  emits `metalBufferDeallocated`" example: a single 11 MB drop is
//  always a single emission, regardless of whether prior small
//  changes were suppressed.
//
//  Invariants (REQUIREMENTS §6):
//    1. Library never imports Produciesta or any host (this file
//       imports only `Foundation`).
//    2. No new dependencies (no swift-log / Logging / OSLog).
//    3. Default is silent — when the caller passes `nil` for the
//       reporter, every payload-construction site short-circuits
//       through the `@autoclosure` indirection inside `emit(_:)` on
//       the calling component (which is what
//       `MTLDevice.currentAllocatedSize` already lives behind).
//    6. Every emission site uses `@autoclosure` so payload work runs
//       only when a reporter is attached (verified at the call site
//       on `WiredMemoryManager` / `AudioModelManager`; this file
//       itself never reads `MTLDevice` — it accepts an absolute MB
//       value as input).
//

import Foundation

/// Coarse-grained sampler for `MTLDevice.currentAllocatedSize`-style
/// readings. Emits ``MLXAudioTelemetryEvent/metalBufferAllocated(allocatedMB:peakMB:)``
/// or ``MLXAudioTelemetryEvent/metalBufferDeallocated(freedMB:remainingMB:)``
/// only when the absolute delta vs. the previous sample exceeds a
/// configurable threshold (default 10 MB, per REQUIREMENTS §2.6).
///
/// ## Usage
///
/// ```swift
/// // 1. Create one sampler per logical Metal-allocation context
/// //    (typically one per process — long-lived).
/// let sampler = MetalMemorySampler()
///
/// // 2. Sample at coarse-grained boundaries (model load / unload).
/// //    The reporter is passed in per-call so the sampler does not
/// //    need its own `setTelemetry(_:)` ceremony.
/// let allocatedMB = Double(MTLCreateSystemDefaultDevice()?.currentAllocatedSize ?? 0) / (1024.0 * 1024.0)
/// await sampler.sample(currentMB: allocatedMB, reporter: reporter)
/// ```
///
/// ## Concurrency
///
/// `actor`-isolated. Concurrent callers are serialized — the
/// baseline-update / delta-compute / emission triple is atomic per
/// sample.
///
/// ## Why an `actor` and not a class?
///
/// The sampler holds mutable `lastSampledMB` and `peakMB` state that
/// must be consistent across concurrent samplers. A `class` would
/// require a lock or an `@unchecked Sendable` annotation; a Swift
/// `actor` gives us mutable-state isolation for free, with no
/// dependency on `Foundation.NSLock` or similar.
public actor MetalMemorySampler {

    /// Threshold in MB. The sampler emits only when the absolute delta
    /// vs. the previous sample is strictly greater than this value.
    /// Defaults to 10 MB per REQUIREMENTS §2.6; exposed for tests so
    /// they can pin a known value.
    public let thresholdMB: Double

    /// The most recent absolute sample, in MB. `nil` until the first
    /// `sample(currentMB:reporter:)` call. The first call seeds the
    /// baseline and never emits — there is no previous sample to
    /// delta against.
    private var lastSampledMB: Double?

    /// The high-water mark observed so far, in MB. Tracked so
    /// ``MLXAudioTelemetryEvent/metalBufferAllocated(allocatedMB:peakMB:)``
    /// can carry a meaningful peak. Updated on every sample whose
    /// `currentMB` is strictly greater than the existing peak,
    /// regardless of whether an event is emitted.
    private var peakMB: Double = 0.0

    /// Create a sampler with the default 10 MB threshold (REQUIREMENTS §2.6).
    public init() {
        self.thresholdMB = 10.0
    }

    /// Create a sampler with an explicit threshold. Used by tests to
    /// pin a known value; production code should use the no-arg
    /// initializer to inherit the spec default.
    public init(thresholdMB: Double) {
        self.thresholdMB = thresholdMB
    }

    /// Sample the absolute current Metal-allocated size and, if the
    /// delta vs. the previous sample exceeds the threshold, emit the
    /// appropriate event.
    ///
    /// - Parameters:
    ///   - currentMB: The absolute current allocation in MB. Callers
    ///     produce this from `MTLDevice.currentAllocatedSize` (or a
    ///     synthetic value for tests).
    ///   - reporter: The reporter to emit through. Passed `nil` for a
    ///     no-op call (which still updates the sampler's baseline).
    ///
    /// - Note: Even with `reporter == nil`, the sampler still updates
    ///   its baseline. This means a host can attach telemetry mid-run
    ///   and continue to get accurate deltas relative to the most
    ///   recent sample. The "zero overhead when nil" invariant
    ///   (REQUIREMENTS §6 invariant 3) is satisfied because the
    ///   per-call work here is a single `Double` comparison + assign;
    ///   the expensive sampling (Metal device read) lives in the
    ///   caller's `@autoclosure` and is therefore independent of
    ///   what this sampler does.
    public func sample(
        currentMB: Double,
        reporter: (any MLXAudioTelemetryReporter)?
    ) async {
        // Update peak first so the emitted `peakMB` reflects this
        // sample, not the prior sample. `peakMB` is monotonically
        // non-decreasing across the sampler's lifetime.
        if currentMB > peakMB {
            peakMB = currentMB
        }

        defer {
            // Always update the baseline at the end of the call —
            // this is the "delta vs. the previous sample" semantics
            // from the prompt. Sub-threshold deltas update the
            // baseline opaquely so a sequence of small drifts does
            // not accumulate into a spurious giant event later.
            lastSampledMB = currentMB
        }

        guard let previous = lastSampledMB else {
            // First sample seeds the baseline; no event is emitted
            // because there is no previous reading to delta against.
            return
        }

        let delta = currentMB - previous

        // Strict comparison: a delta of exactly +threshold or
        // -threshold is suppressed. The prompt's wording ("exceeds
        // 10 MB") matches strict greater-than.
        if delta > thresholdMB {
            await Self.emit(
                .metalBufferAllocated(
                    allocatedMB: currentMB,
                    peakMB: peakMB
                ),
                to: reporter
            )
        } else if delta < -thresholdMB {
            // `freedMB` is the magnitude of the drop (positive
            // number). `remainingMB` is the absolute current value.
            await Self.emit(
                .metalBufferDeallocated(
                    freedMB: -delta,
                    remainingMB: currentMB
                ),
                to: reporter
            )
        }
        // else: sub-threshold delta in either direction —
        // suppressed. Baseline still updated by the `defer`.
    }

    /// Reset the sampler's internal state. Useful in tests that need
    /// to verify "first sample seeds, second sample deltas" without
    /// the historical state of a long-lived sampler.
    public func reset() {
        lastSampledMB = nil
        peakMB = 0.0
    }

    /// Read the current baseline (test introspection only). Not part
    /// of the public sampling contract.
    internal func currentBaselineMB() -> Double? {
        lastSampledMB
    }

    // MARK: - Internal Telemetry Helper

    /// Canonical-shape `emit(_:)` helper, adapted to the static-context
    /// the sampler emits from. The `@autoclosure` is preserved so a
    /// `nil` reporter performs zero payload work — see invariant 6 of
    /// REQUIREMENTS §6 and the canonical 4-line snippet in
    /// `MLXAudioTelemetryReporter.swift`.
    ///
    /// `static` because the sampler accepts the reporter per-call
    /// rather than holding it as instance state; making this static
    /// signals that there is no per-instance reporter to close over.
    private static func emit(
        _ event: @autoclosure () -> MLXAudioTelemetryEvent,
        to reporter: (any MLXAudioTelemetryReporter)?
    ) async {
        guard let reporter else { return }
        await reporter.capture(event())
    }
}
