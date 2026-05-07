import Foundation
import os
import ObjectiveC

/// Lifecycle-tracking sentinel for externally-owned KV cache instances.
///
/// Background: every KV cache implementation in this codebase is an
/// `MLXLMCommon.KVCacheSimple` (or a subclass thereof) — a `public class`
/// from a sibling Swift package that we cannot subclass cross-module
/// (it is `public`, not `open`) and whose `init` / `deinit` we therefore
/// cannot directly hook with `Telemetry.trackLifecycle`.
///
/// Strategy: every KV cache instance produced by an MLXAudio
/// `makeCache()` factory gets a `KVCacheLifecycleSentinel` attached to
/// it via the Objective-C associated-objects runtime. The sentinel's
/// lifetime is bound to the host KV cache via ARC: when the cache is
/// deallocated, the runtime releases the sentinel, triggering
/// `KVCacheLifecycleSentinel.deinit` and the paired
/// `Telemetry.trackLifecycleEnd(...)` decrement.
///
/// `objc_setAssociatedObject` works on any `AnyObject` regardless of
/// `@objc` annotations because libobjc owns the deinit hook for every
/// Swift class instance (this is a documented Swift / Objective-C
/// runtime invariant; Apple sample code uses the same pattern for pure
/// Swift classes).
///
/// Counter key format is the canonical `"<Family>.KVCache"` per
/// EXECUTION_PLAN.md S5.
internal final class KVCacheLifecycleSentinel: @unchecked Sendable {

    /// Counter-store class label, e.g. `"Qwen3TTS.KVCache"`.
    let counterKey: String

    /// Family signposter used for the lifetime interval.
    private let signposter: OSSignposter

    /// Begin-state token returned by `signposter.beginInterval` so we can
    /// pair it with `endInterval` in `deinit`. `OSSignpostIntervalState`
    /// is the modern non-deprecated API for `OSSignposter` interval
    /// pairing.
    private let intervalState: OSSignpostIntervalState

    /// Construct a sentinel for `family` (e.g. `"Qwen3TTS"`).
    ///
    /// Counter key is `"<family>.KVCache"`. The signposter is selected
    /// from `MLXAudioLogging` based on `family` — unknown families fall
    /// back to `MLXAudioLogging.coreSignposter` so the call site never
    /// silently no-ops.
    init(family: String) {
        self.counterKey = "\(family).KVCache"
        self.signposter = Self.signposter(forFamily: family)
        // Begin a Lifetime interval. We use the family signposter so
        // Instruments groups KV-cache lifetimes under each family's lane.
        let id = signposter.makeSignpostID()
        self.intervalState = signposter.beginInterval("Lifetime", id: id, "\(family).KVCache")
        // Lifecycle instrumentation lives in the release ceiling — must
        // NOT be `#if MLXAUDIO_TELEMETRY_FULL`-gated.
        Telemetry.trackLifecycle(self, className: counterKey)
    }

    deinit {
        signposter.endInterval("Lifetime", intervalState)
        Telemetry.trackLifecycleEnd(className: counterKey)
    }

    /// Maps a family name to its `OSSignposter`. Centralized so the call
    /// sites in `attachKVCacheLifecycle` never have to know which
    /// signposter their family uses.
    private static func signposter(forFamily family: String) -> OSSignposter {
        switch family {
        case "Qwen3TTS":   return MLXAudioLogging.qwen3TTSSignposter
        case "Qwen3":      return MLXAudioLogging.coreSignposter
        case "LlamaTTS":   return MLXAudioLogging.llamaTTSSignposter
        case "SopranoTTS": return MLXAudioLogging.sopranoTTSSignposter
        case "PocketTTS":  return MLXAudioLogging.pocketTTSSignposter
        case "MarvisTTS":  return MLXAudioLogging.marvisTTSSignposter
        case "Qwen3ASR":   return MLXAudioLogging.qwen3ASRSignposter
        case "GLMASR":     return MLXAudioLogging.glmASRSignposter
        case "Mimi":       return MLXAudioLogging.codecsSignposter
        default:           return MLXAudioLogging.coreSignposter
        }
    }
}

/// Stable address used as the associated-object key. The key only needs
/// to be unique and stable for the lifetime of the process.
private nonisolated(unsafe) var kvCacheLifecycleSentinelKey: UInt8 = 0

/// Attach a lifecycle-tracking sentinel to an externally-owned KV cache
/// instance.
///
/// The sentinel increments `<family>.KVCache` on construction and
/// decrements it on `deinit`. ARC binds the sentinel's lifetime to
/// `host` via `objc_setAssociatedObject` with `OBJC_ASSOCIATION_RETAIN`,
/// so when the host is deallocated, the runtime releases the sentinel
/// automatically.
///
/// Idempotency: calling this twice on the same host replaces the prior
/// sentinel (which then deallocates and emits its end event). Production
/// code should call this exactly once per cache instance.
///
/// Lifecycle instrumentation lives in the release ceiling, so the call
/// site is **not** gated by `#if MLXAUDIO_TELEMETRY_FULL`. The internal
/// `Telemetry.trackLifecycle` short-circuits when `Telemetry.level == .off`,
/// keeping the cost negligible at the lowest active level.
public func attachKVCacheLifecycle(family: String, to host: AnyObject) {
    let sentinel = KVCacheLifecycleSentinel(family: family)
    objc_setAssociatedObject(
        host,
        &kvCacheLifecycleSentinelKey,
        sentinel,
        .OBJC_ASSOCIATION_RETAIN_NONATOMIC
    )
}
