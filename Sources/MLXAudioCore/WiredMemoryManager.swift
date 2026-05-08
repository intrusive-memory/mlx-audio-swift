//
//  WiredMemoryManager.swift
//  MLXAudioCore
//
//  Utilities for pinning model weights in physical memory using MLX's wired memory API.
//  Wired memory prevents macOS from paging out GPU buffers under memory pressure,
//  reducing latency spikes during real-time TTS/STT inference.
//
//  Requires macOS 15+ / Metal 3 (Apple Silicon). Degrades gracefully on older systems.
//

import Foundation
@preconcurrency import MLX

// MARK: - Telemetry storage (Sortie 5 — OPERATION SILENT STETHOSCOPE)

/// File-private actor that holds the optional public-telemetry reporter
/// for the `WiredMemoryManager` namespace.
///
/// `WiredMemoryManager` is a `public enum` with only `static` members,
/// so the canonical per-instance `private var telemetry: ...?` storage
/// from `MLXAudioTelemetryReporter.swift`'s doc comment cannot live on
/// `self`. Mirroring the pattern established by Sortie 2 in
/// `AudioModelManager.swift`, we hold the reporter inside a single
/// file-private actor and expose the canonical `setTelemetry(_:)` /
/// `emit(_:)` shape through `static` wrappers on `WiredMemoryManager`.
///
/// The `@autoclosure` deferral semantics of the canonical helper are
/// preserved: payload-construction (Metal sampling, `Memory.activeMemory`
/// reads, byte-to-MB conversions) only runs after we have read a
/// non-`nil` reporter out of the actor. With no reporter attached the
/// `event()` autoclosure is never invoked, satisfying invariant 6 of
/// REQUIREMENTS-telemetry.md §6.
private actor _WiredMemoryManagerTelemetryStorage {
    static let shared = _WiredMemoryManagerTelemetryStorage()

    private var telemetry: (any MLXAudioTelemetryReporter)?

    private init() {
        self.telemetry = nil
    }

    func set(_ reporter: (any MLXAudioTelemetryReporter)?) {
        self.telemetry = reporter
    }

    func current() -> (any MLXAudioTelemetryReporter)? {
        telemetry
    }
}

// MARK: - WiredMemoryManager

/// Manages wired (pinned) memory for MLX model weights.
///
/// When model weights are loaded into GPU memory, macOS may page them out under memory
/// pressure. For real-time audio applications (TTS/STT), this causes unpredictable latency
/// spikes as weights must be paged back in. Wired memory pins buffers in physical RAM,
/// guaranteeing they remain resident.
///
/// This manager wraps MLX's `Memory.withWiredLimit()` API, which uses Metal residency sets
/// (macOS 15+, Metal 3) to keep allocated buffers resident up to the specified limit.
///
/// ## Usage
///
/// ### Pin memory for a generation block
/// ```swift
/// let audio = try await WiredMemoryManager.withPinnedMemory {
///     try await model.generate(text: "Hello", voice: "A clear voice", language: "en")
/// }
/// ```
///
/// ### Pin with explicit byte limit
/// ```swift
/// let audio = try await WiredMemoryManager.withPinnedMemory(limitBytes: 4_000_000_000) {
///     try await model.generate(text: "Hello", voice: "A clear voice", language: "en")
/// }
/// ```
///
/// ### Query system limits
/// ```swift
/// let info = WiredMemoryManager.systemInfo()
/// print("Max wirable: \(info.maxWirableBytes / 1_000_000)MB")
/// ```
public enum WiredMemoryManager {

    // MARK: - Public Telemetry API (Sortie 5 — OPERATION SILENT STETHOSCOPE)

    /// Attach (or detach) a vendor-neutral telemetry reporter.
    ///
    /// Pass `nil` (the default state) to silence the namespace; with no
    /// reporter attached every emission site short-circuits before any
    /// payload construction runs (Metal sampling, `Memory.activeMemory`
    /// reads, etc.) — see invariant 3 / 6 of
    /// `REQUIREMENTS-telemetry.md §6` and the canonical `emit(_:)`
    /// snippet documented in `MLXAudioTelemetryReporter.swift`.
    ///
    /// `WiredMemoryManager` is a `public enum` with only `static`
    /// members, so storage lives in a file-private actor
    /// (`_WiredMemoryManagerTelemetryStorage`). The setter is `async`
    /// because it forwards to that actor; this matches the
    /// static-namespace shape Sortie 2 established for
    /// `AudioModelManager`.
    public static func setTelemetry(_ reporter: (any MLXAudioTelemetryReporter)?) async {
        await _WiredMemoryManagerTelemetryStorage.shared.set(reporter)
    }

    // MARK: - Internal Telemetry Helpers

    /// Canonical per-namespace `emit(_:)` helper for the public telemetry
    /// surface. Adapted from the 4-line snippet documented in
    /// `MLXAudioTelemetryReporter.swift` to the static-namespace shape:
    /// the actor read replaces the per-instance `guard let telemetry`
    /// check, but the `@autoclosure` deferral semantics are preserved.
    ///
    /// The `@autoclosure` is load-bearing — payload construction only
    /// runs when `reporter` is non-`nil`, so any expensive sampling
    /// inside the call site (e.g. `Memory.activeMemory`,
    /// byte-to-MB math) is elided whenever telemetry is detached.
    private static func emit(_ event: @autoclosure () -> MLXAudioTelemetryEvent) async {
        guard let reporter = await _WiredMemoryManagerTelemetryStorage.shared.current() else { return }
        await reporter.capture(event())
    }

    /// Convert a byte count to MB as a `Double`. Centralized so every
    /// payload site uses the same divisor and so the call site of
    /// every conversion is auditable via `grep`.
    private static func bytesToMB(_ bytes: Int) -> Double {
        Double(bytes) / (1024.0 * 1024.0)
    }

    private static func bytesToMB(_ bytes: UInt64) -> Double {
        Double(bytes) / (1024.0 * 1024.0)
    }

    // MARK: - System Info

    /// Information about system wired memory capabilities.
    public struct SystemInfo: Sendable {
        /// Maximum recommended working set size reported by the GPU device, in bytes.
        /// This is the upper bound for the wired memory limit.
        public let maxRecommendedWorkingSetSize: UInt64

        /// Total physical memory on the system, in bytes.
        public let totalMemoryBytes: Int

        /// Maximum bytes that can be safely wired without exceeding system limits.
        /// This is `maxRecommendedWorkingSetSize` on supported systems, or 0 if
        /// wired memory is not available.
        public let maxWirableBytes: Int

        /// GPU architecture name (e.g., "Apple M4 Pro").
        public let architecture: String

        /// Whether the system supports Metal residency sets (macOS 15+, Metal 3).
        /// Wired memory has no effect on systems without this support.
        public let supportsWiredMemory: Bool
    }

    /// Query system wired memory capabilities.
    ///
    /// Returns information about the GPU device and the maximum amount of memory
    /// that can be wired. Use this to make informed decisions about wired limits.
    ///
    /// - Returns: A ``SystemInfo`` describing the system's wired memory capabilities.
    public static func systemInfo() -> SystemInfo {
        let deviceInfo = GPU.deviceInfo()
        let maxWorkingSet = deviceInfo.maxRecommendedWorkingSetSize
        // Metal residency sets require macOS 15+ and Metal 3 (Apple Silicon).
        // maxRecommendedWorkingSetSize == 0 indicates no GPU or unsupported device.
        let supportsWired = maxWorkingSet > 0
        return SystemInfo(
            maxRecommendedWorkingSetSize: maxWorkingSet,
            totalMemoryBytes: deviceInfo.memorySize,
            maxWirableBytes: supportsWired ? Int(maxWorkingSet) : 0,
            architecture: deviceInfo.architecture,
            supportsWiredMemory: supportsWired
        )
    }

    // MARK: - Wired Memory Execution (Synchronous)

    /// Execute a block with model weights pinned in physical memory.
    ///
    /// This sets the MLX wired memory limit for the duration of the block, causing
    /// all MLX GPU allocations (including model weights and intermediate buffers)
    /// to be kept resident in physical RAM up to the specified limit.
    ///
    /// If `limitBytes` exceeds the system's maximum recommended working set size,
    /// the limit is clamped and a warning is printed. If the system does not support
    /// wired memory at all, the block executes normally without pinning.
    ///
    /// - Parameters:
    ///   - limitBytes: Maximum bytes to wire. Pass `nil` to use the system's maximum
    ///     recommended working set size (the safest default for pinning all model weights).
    ///   - body: The block to execute with wired memory enabled.
    /// - Returns: The return value of `body`.
    /// - Throws: Rethrows any error from `body`.
    public static func withPinnedMemory<R>(
        limitBytes: Int? = nil,
        _ body: () throws -> R
    ) rethrows -> R {
        let info = systemInfo()

        guard info.supportsWiredMemory else {
            print("[WiredMemoryManager] Wired memory not available on this system (\(info.architecture)). Continuing without pinning.")
            return try body()
        }

        let resolvedLimit = resolveLimit(requested: limitBytes, maxWirable: info.maxWirableBytes)

        print("[WiredMemoryManager] Pinning up to \(resolvedLimit / 1_000_000)MB of GPU memory (max: \(info.maxWirableBytes / 1_000_000)MB)")

        // Public telemetry (Sortie 5): emit a `wiredMemoryState`
        // snapshot at the entry boundary, after the wired limit is
        // resolved and just before the wired-memory scope opens. We do
        // not introduce a new sampling timer; this is the existing
        // coarse-grained boundary already used by the manager (see
        // REQUIREMENTS §2.6). The emission goes through the canonical
        // `emit(_:)` helper, which short-circuits when no reporter is
        // attached — `Memory.activeMemory` is therefore never read in
        // the silent default.
        //
        // The sync overload schedules the async emission as a detached
        // Task so the existing synchronous signature (`rethrows -> R`)
        // is preserved. The Task's payload work still respects the
        // `@autoclosure` deferral inside `emit(_:)` — when no reporter
        // is attached the closure is never invoked.
        Task {
            await emit(
                .wiredMemoryState(
                    wiredMB: bytesToMB(resolvedLimit),
                    committedMB: bytesToMB(Memory.activeMemory)
                )
            )
        }

        let result = try Memory.withWiredLimit(resolvedLimit) {
            try body()
        }

        print("[WiredMemoryManager] Wired memory released.")

        // Exit-boundary `wiredMemoryState` snapshot. `wiredMB == 0.0`
        // signals the wired scope has been released; `committedMB` is
        // the post-release `Memory.activeMemory` reading.
        Task {
            await emit(
                .wiredMemoryState(
                    wiredMB: 0.0,
                    committedMB: bytesToMB(Memory.activeMemory)
                )
            )
        }

        return result
    }

    // MARK: - Wired Memory Execution (Async)

    /// Execute an async block with model weights pinned in physical memory.
    ///
    /// This is the async variant of ``withPinnedMemory(limitBytes:_:)-6g9p3``, suitable
    /// for use in model generation methods that are `async`.
    ///
    /// - Parameters:
    ///   - limitBytes: Maximum bytes to wire. Pass `nil` to use the system's maximum.
    ///   - body: The async block to execute with wired memory enabled.
    /// - Returns: The return value of `body`.
    /// - Throws: Rethrows any error from `body`.
    public static func withPinnedMemory<R>(
        limitBytes: Int? = nil,
        _ body: () async throws -> R
    ) async rethrows -> R {
        let info = systemInfo()

        guard info.supportsWiredMemory else {
            print("[WiredMemoryManager] Wired memory not available on this system (\(info.architecture)). Continuing without pinning.")
            return try await body()
        }

        let resolvedLimit = resolveLimit(requested: limitBytes, maxWirable: info.maxWirableBytes)

        print("[WiredMemoryManager] Pinning up to \(resolvedLimit / 1_000_000)MB of GPU memory (max: \(info.maxWirableBytes / 1_000_000)MB)")

        // Public telemetry (Sortie 5): entry-boundary `wiredMemoryState`
        // snapshot. See the sync overload above for the full design
        // rationale; the async overload can `await emit(...)` directly
        // because it already lives in an `async` context.
        await emit(
            .wiredMemoryState(
                wiredMB: bytesToMB(resolvedLimit),
                committedMB: bytesToMB(Memory.activeMemory)
            )
        )

        let result = try await Memory.withWiredLimit(resolvedLimit) {
            try await body()
        }

        print("[WiredMemoryManager] Wired memory released.")

        // Exit-boundary snapshot. `wiredMB == 0.0` signals the wired
        // scope has been released; `committedMB` is the post-release
        // `Memory.activeMemory` reading.
        await emit(
            .wiredMemoryState(
                wiredMB: 0.0,
                committedMB: bytesToMB(Memory.activeMemory)
            )
        )

        return result
    }

    // MARK: - Convenience: Pin Based on Active Memory

    /// Execute a block with wired memory sized to cover the current active memory footprint,
    /// plus a growth headroom factor.
    ///
    /// This is useful after loading a model: call this to pin approximately the model's
    /// weight size plus room for inference buffers.
    ///
    /// - Parameters:
    ///   - headroomFactor: Multiplier on the current active memory to allow for inference
    ///     buffers. Defaults to 1.5 (50% headroom). For example, if the model uses 2GB,
    ///     the wired limit will be set to 3GB.
    ///   - body: The block to execute.
    /// - Returns: The return value of `body`.
    /// - Throws: Rethrows any error from `body`.
    public static func withPinnedMemoryForCurrentModel<R>(
        headroomFactor: Double = 1.5,
        _ body: () async throws -> R
    ) async rethrows -> R {
        let activeBytes = Memory.activeMemory
        let desiredLimit = Int(Double(activeBytes) * headroomFactor)
        return try await withPinnedMemory(limitBytes: desiredLimit, body)
    }

    // MARK: - Internal

    /// Resolve the wired memory limit, clamping to the system maximum with a warning
    /// if the requested limit exceeds it.
    private static func resolveLimit(requested: Int?, maxWirable: Int) -> Int {
        guard let requested = requested else {
            // Default: use the full recommended working set size
            return maxWirable
        }

        if requested > maxWirable {
            print("[WiredMemoryManager] WARNING: Requested wired limit (\(requested / 1_000_000)MB) exceeds system maximum (\(maxWirable / 1_000_000)MB). Clamping to maximum.")
            return maxWirable
        }

        if requested <= 0 {
            print("[WiredMemoryManager] WARNING: Requested wired limit is <= 0. Disabling wired memory.")
            return 0
        }

        return requested
    }
}
