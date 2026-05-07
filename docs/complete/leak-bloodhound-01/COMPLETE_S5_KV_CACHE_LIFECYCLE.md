# Sortie 5 — KV cache lifecycle hooks (trackLifecycle pattern + leak test) — COMPLETE

**Mission**: OPERATION LEAK BLOODHOUND
**Work Unit**: WU-2 Lifecycle Instrumentation
**Sortie**: 5 of 15
**Branch**: `mission/leak-bloodhound/01`
**Iteration**: 1

---

## Audit Output (REQUIRED — top of doc)

### Architectural finding: KV caches are externally owned

The `KVCache` protocol and every concrete implementation (`KVCacheSimple`,
`RotatingKVCache`, `QuantizedKVCache`, `ChunkedKVCache`, `MambaCache`,
`CacheList`, `BaseKVCache`) live in the external `MLXLMCommon` Swift
package — see
`.build/index-build/checkouts/mlx-swift-lm/Libraries/MLXLMCommon/KVCache.swift`.

`KVCacheSimple` is `public class` (not `open`), so it cannot be
subclassed cross-module. We therefore have no `init` / `deinit` we can
hook directly on the KV cache classes themselves. EXECUTION_PLAN.md S5
explicitly anticipates this case ("designated factory" wording, plus the
"refactor minimally to introduce a designated init" carve-out).

### Solution: lifecycle-tracking sentinel attached via associated objects

We introduce `KVCacheLifecycleSentinel` (a thin `internal final class`
in `MLXAudioCore`) and the public free function
`attachKVCacheLifecycle(family:to:)`. The function constructs a sentinel
and binds its lifetime to the host KV cache via
`objc_setAssociatedObject(..., .OBJC_ASSOCIATION_RETAIN_NONATOMIC)`.
When the host cache is deallocated, ARC releases the associated
sentinel, triggering its `deinit`, which fires the matched
`Telemetry.trackLifecycleEnd` decrement and `signposter.endInterval`.
The sentinel's `init` does the symmetric increment + `beginInterval`.

The Objective-C associated-objects runtime works on every Swift class
instance (libobjc owns the deinit hook for all reference types), so
this works even though `KVCacheSimple` is a non-`@objc` Swift class
from a sibling Swift package.

### Audit list — every KV cache instantiation site in MLX-audio-swift

Counter-key column shows the canonical `<Family>.KVCache` label that
`attachKVCacheLifecycle(family:to:)` produces at each site. Every
existing `KVCacheSimple()` constructor call in the codebase is
instrumented; the four `makePromptCache(...)`-based call sites in
`CSMModel.swift` (Marvis) are instrumented post-hoc by iterating the
returned cache array and attaching one sentinel per cache.

| Family | Counter key | Source file | Line(s) | Hook landed |
|--------|-------------|-------------|---------|:-----------:|
| Qwen3ASR | `Qwen3ASR.KVCache` | `Sources/MLXAudioSTT/Models/Qwen3ASR/Qwen3ASR.swift` | 956–962 (`makeCache`) | yes |
| GLMASR | `GLMASR.KVCache` | `Sources/MLXAudioSTT/Models/GLMASR/GLMASR.swift` | 512–518 (`makeCache`) | yes |
| Qwen3TTS (Talker) | `Qwen3TTS.KVCache` | `Sources/MLXAudioTTS/Models/Qwen3TTS/Qwen3TTSTalker.swift` | 305–311 (`Qwen3TTSTalkerModel.makeCache`) | yes |
| Qwen3TTS (TalkerForCG) | `Qwen3TTS.KVCache` | `Sources/MLXAudioTTS/Models/Qwen3TTS/Qwen3TTSTalker.swift` | 354 (forwards to inner) | yes (transitively) |
| Qwen3TTS (CodePredictor inner model) | `Qwen3TTS.KVCache` | `Sources/MLXAudioTTS/Models/Qwen3TTS/Qwen3TTSCodePredictor.swift` | 187–193 (`CodePredictorModel.makeCache`) | yes |
| Qwen3TTS (CodePredictor outer) | `Qwen3TTS.KVCache` | `Sources/MLXAudioTTS/Models/Qwen3TTS/Qwen3TTSCodePredictor.swift` | 242 (forwards to inner) | yes (transitively) |
| Qwen3TTS (SpeechDecoder) | `Qwen3TTS.KVCache` | `Sources/MLXAudioTTS/Models/Qwen3TTS/Qwen3TTSSpeechDecoder.swift` | 459–465 (`makeCache`) | yes |
| PocketTTS (Transformer.makeCache) | `PocketTTS.KVCache` | `Sources/MLXAudioTTS/Models/PocketTTS/PocketTTSTransformer.swift` | 232–238 (`makeCache`) | yes |
| PocketTTS (Transformer.callAsFunction default) | `PocketTTS.KVCache` | `Sources/MLXAudioTTS/Models/PocketTTS/PocketTTSTransformer.swift` | 222–227 (inline `nil`-fallback) | yes |
| PocketTTS (FlowLM forwards) | `PocketTTS.KVCache` | `Sources/MLXAudioTTS/Models/PocketTTS/PocketTTSFlowLM.swift` | 61 (forwards to Transformer) | yes (transitively) |
| Mimi (Transformer.makeCache) | `Mimi.KVCache` | `Sources/MLXAudioCodecs/Mimi/Transformer.swift` | 309–316 (`makeCache`) | yes |
| Mimi (ProjectedTransformer forwards) | `Mimi.KVCache` | `Sources/MLXAudioCodecs/Mimi/Transformer.swift` | 372 (forwards to Transformer) | yes (transitively) |
| Qwen3 (TTS) | `Qwen3.KVCache` | `Sources/MLXAudioTTS/Models/Qwen3/Qwen3.swift` | 529–535 (`Qwen3Model.makeCache`) | yes |
| SopranoTTS | `SopranoTTS.KVCache` | `Sources/MLXAudioTTS/Models/Soprano/Soprano.swift` | 265–271 (`makeCache`) | yes |
| LlamaTTS | `LlamaTTS.KVCache` | `Sources/MLXAudioTTS/Models/Llama/LlamaTTS.swift` | 593–599 (`makeCache`) | yes |
| MarvisTTS (CSM resetCaches) | `MarvisTTS.KVCache` | `Sources/MLXAudioTTS/Models/Marvis/CSMModel.swift` | 461–467 (`resetCaches` post-`makePromptCache` attach) | yes |
| MarvisTTS (CSM generateFrame decoder) | `MarvisTTS.KVCache` | `Sources/MLXAudioTTS/Models/Marvis/CSMModel.swift` | 503–504 (`generateFrame` post-`makePromptCache` attach) | yes |

**Family count**: 9 distinct families instrumented — `Qwen3TTS`,
`Qwen3`, `LlamaTTS`, `SopranoTTS`, `PocketTTS`, `MarvisTTS`,
`Qwen3ASR`, `GLMASR`, `Mimi`. Each maps to a known
`MLXAudioLogging.*Signposter` (or `coreSignposter` for `Qwen3` which has
no per-family signposter) inside `KVCacheLifecycleSentinel.signposter(forFamily:)`.

**`KVCacheSimple()` instantiation count after S5**: 11 direct
constructor sites (one per row above marked "yes" except the four
forwarding rows and the two Marvis post-hoc rows). All 11 are now
followed by `attachKVCacheLifecycle(family:to:)`. Verified via
`grep -rn 'KVCacheSimple()' Sources/ --include='*.swift'`.

---

## Summary

`KVCacheLifecycleSentinel` (new in `MLXAudioCore/Telemetry/`) emits the
`<Family>.KVCache` increment + `OSSignposter` `Lifetime` interval start
in `init`, and the matching decrement + interval end in `deinit`.
`attachKVCacheLifecycle(family:to:)` is the public free-function entry
point used by every `makeCache()` factory. The sentinel is bound to the
KV cache via `objc_setAssociatedObject`, so its lifetime tracks the
cache's exactly — no behavior changes, no API changes, no type
substitutions. Lifecycle instrumentation lives in the release ceiling
(`Telemetry.level >= .lifecycle`), so call sites are NOT wrapped in
`#if MLXAUDIO_TELEMETRY_FULL`. The internal `Telemetry.trackLifecycle`
helpers short-circuit when `Telemetry.level == .off`, keeping cost
negligible.

---

## Files Created or Modified

| Path | Change |
|------|--------|
| `Sources/MLXAudioCore/Telemetry/KVCacheLifecycleSentinel.swift` | NEW — `internal final class KVCacheLifecycleSentinel` + `public func attachKVCacheLifecycle(family:to:)`. Pulls in `import ObjectiveC` for `objc_setAssociatedObject`. |
| `Sources/MLXAudioCodecs/Mimi/Transformer.swift` | MODIFIED — `Transformer.makeCache()` attaches `Mimi` family sentinels. |
| `Sources/MLXAudioSTT/Models/GLMASR/GLMASR.swift` | MODIFIED — `makeCache()` attaches `GLMASR` family sentinels. |
| `Sources/MLXAudioSTT/Models/Qwen3ASR/Qwen3ASR.swift` | MODIFIED — `makeCache()` attaches `Qwen3ASR` family sentinels. |
| `Sources/MLXAudioTTS/Models/Llama/LlamaTTS.swift` | MODIFIED — `makeCache()` attaches `LlamaTTS` family sentinels. |
| `Sources/MLXAudioTTS/Models/Marvis/CSMModel.swift` | MODIFIED — added `import MLXAudioCore`; `resetCaches()` and `generateFrame()` post-`makePromptCache` attach `MarvisTTS` family sentinels. |
| `Sources/MLXAudioTTS/Models/PocketTTS/PocketTTSTransformer.swift` | MODIFIED — added `import MLXAudioCore`; `makeCache()` and `callAsFunction` `nil`-fallback both attach `PocketTTS` family sentinels. |
| `Sources/MLXAudioTTS/Models/Qwen3/Qwen3.swift` | MODIFIED — `Qwen3Model.makeCache()` attaches `Qwen3` family sentinels. |
| `Sources/MLXAudioTTS/Models/Qwen3TTS/Qwen3TTSCodePredictor.swift` | MODIFIED — added `import MLXAudioCore`; inner `CodePredictorModel.makeCache()` attaches `Qwen3TTS` family sentinels. |
| `Sources/MLXAudioTTS/Models/Qwen3TTS/Qwen3TTSSpeechDecoder.swift` | MODIFIED — `makeCache()` attaches `Qwen3TTS` family sentinels. |
| `Sources/MLXAudioTTS/Models/Qwen3TTS/Qwen3TTSTalker.swift` | MODIFIED — added `import MLXAudioCore`; `Qwen3TTSTalkerModel.makeCache()` attaches `Qwen3TTS` family sentinels. |
| `Sources/MLXAudioTTS/Models/Soprano/Soprano.swift` | MODIFIED — `makeCache()` attaches `SopranoTTS` family sentinels. |
| `Tests/TelemetryLifecycleHookTests.swift` | NEW — 6 Swift Testing tests in a `.serialized` `TelemetryLifecycleHookTests` suite. |
| `COMPLETE_S5_KV_CACHE_LIFECYCLE.md` | NEW — this file. |

No other files were modified. `EXECUTION_PLAN.md`, `SUPERVISOR_STATE.md`,
`Package.swift`, all WU-1 telemetry sources / tests, and every other
production file are unchanged per sergeant rules.

---

## Verification Evidence

### Exit criterion 1: every audited family's hook lands in the diff

Every row in the audit table above has counter-key string
`<Family>.KVCache` paired with a source file that contains a new call
to `attachKVCacheLifecycle(family: "<Family>", to: cache)`. Verify:

```
$ grep -rn 'attachKVCacheLifecycle' Sources/ --include='*.swift'
Sources/MLXAudioCodecs/Mimi/Transformer.swift:312:            attachKVCacheLifecycle(family: "Mimi", to: cache)
Sources/MLXAudioSTT/Models/GLMASR/GLMASR.swift:515:            attachKVCacheLifecycle(family: "GLMASR", to: cache)
Sources/MLXAudioSTT/Models/Qwen3ASR/Qwen3ASR.swift:959:            attachKVCacheLifecycle(family: "Qwen3ASR", to: cache)
Sources/MLXAudioTTS/Models/Llama/LlamaTTS.swift:596:            attachKVCacheLifecycle(family: "LlamaTTS", to: cache)
Sources/MLXAudioTTS/Models/Marvis/CSMModel.swift:464:        backboneCache?.forEach { attachKVCacheLifecycle(family: "MarvisTTS", to: $0) }
Sources/MLXAudioTTS/Models/Marvis/CSMModel.swift:465:        decoderCache?.forEach { attachKVCacheLifecycle(family: "MarvisTTS", to: $0) }
Sources/MLXAudioTTS/Models/Marvis/CSMModel.swift:504:        decoderCache?.forEach { attachKVCacheLifecycle(family: "MarvisTTS", to: $0) }
Sources/MLXAudioTTS/Models/PocketTTS/PocketTTSTransformer.swift:226:            attachKVCacheLifecycle(family: "PocketTTS", to: c)
Sources/MLXAudioTTS/Models/PocketTTS/PocketTTSTransformer.swift:238:            attachKVCacheLifecycle(family: "PocketTTS", to: cache)
Sources/MLXAudioTTS/Models/Qwen3/Qwen3.swift:532:            attachKVCacheLifecycle(family: "Qwen3", to: cache)
Sources/MLXAudioTTS/Models/Qwen3TTS/Qwen3TTSCodePredictor.swift:190:            attachKVCacheLifecycle(family: "Qwen3TTS", to: cache)
Sources/MLXAudioTTS/Models/Qwen3TTS/Qwen3TTSSpeechDecoder.swift:463:            attachKVCacheLifecycle(family: "Qwen3TTS", to: cache)
Sources/MLXAudioTTS/Models/Qwen3TTS/Qwen3TTSTalker.swift:308:            attachKVCacheLifecycle(family: "Qwen3TTS", to: cache)
Sources/MLXAudioTTS/Models/Soprano/Soprano.swift:268:            attachKVCacheLifecycle(family: "SopranoTTS", to: cache)
```

14 call sites across 11 files — every audited family has at least one
hook. ✓

### Exit criterion 2: targeted suite passes

```
$ xcodebuild test -scheme MLXAudio-Package -destination 'platform=macOS' \
    -only-testing:MLXAudioTests/TelemetryLifecycleHookTests \
    CODE_SIGNING_ALLOWED=NO
...
􀟈 Suite "TelemetryLifecycleHookTests" started.
􁁛 Test "KVCacheLifecycleSentinel init increments liveCounts" passed after 0.011 seconds.
􁁛 Test "KVCacheLifecycleSentinel deinit decrements liveCounts" passed after 0.004 seconds.
􁁛 Test "multiple sentinels are counted independently" passed after 0.004 seconds.
􁁛 Test "attachKVCacheLifecycle binds sentinel lifetime to host" passed after 0.004 seconds.
􁁛 Test "create + drop 10 KV caches: liveCount returns to 0" passed after 0.002 seconds.
􁁛 Test "sentinel constructs cleanly for every audited family" passed after 0.004 seconds.
􁁛 Suite "TelemetryLifecycleHookTests" passed after 0.031 seconds.
􁁛 Test run with 6 tests in 1 suite passed after 0.031 seconds.

** TEST SUCCEEDED **
```

6 / 6 tests pass. ✓

### Exit criterion 3: KV-cache leak test passes

The leak test `create + drop 10 KV caches: liveCount returns to 0` is
within the suite above (line 165 of `TelemetryLifecycleHookTests.swift`).
It allocates ten `KVCacheSimple` instances inside an `autoreleasepool`,
each tagged with `attachKVCacheLifecycle(family: "LeakTest", to:)`,
drops them, awaits `Telemetry.snapshot()`, and asserts
`snapshot.liveCounts["LeakTest.KVCache"] == 0`. No model downloads.
Test passed: see Exit criterion 2 output above. ✓

### Exit criterion 4: full CI-safe test block passes

```
$ xcodebuild test -scheme MLXAudio-Package -destination 'platform=macOS' \
    -only-testing:MLXAudioTests/VocosTests \
    [... all 38 suites from CLAUDE.md ...] \
    CODE_SIGNING_ALLOWED=NO
...
􁁛 Test run with 326 tests in 38 suites passed after 10.402 seconds.

** TEST SUCCEEDED **
```

326 / 326 tests pass. No regressions across the full CI-safe block. ✓

---

## Exact Verification Commands (Re-Executable)

```sh
# 1) Audit: list every attachKVCacheLifecycle call site
grep -rn 'attachKVCacheLifecycle' Sources/ --include='*.swift'

# 2) Targeted suite
xcodebuild test -scheme MLXAudio-Package -destination 'platform=macOS' \
  -only-testing:MLXAudioTests/TelemetryLifecycleHookTests \
  CODE_SIGNING_ALLOWED=NO

# 3) Full CI-safe block (verbatim from CLAUDE.md)
xcodebuild test -scheme MLXAudio-Package -destination 'platform=macOS' \
  -only-testing:MLXAudioTests/VocosTests \
  -only-testing:MLXAudioTests/EncodecTests \
  -only-testing:MLXAudioTests/DACVAETests \
  -only-testing:MLXAudioTests/GLMASRModuleSetupTests \
  -only-testing:MLXAudioTests/GLMASRModelTests \
  -only-testing:MLXAudioTests/Qwen3ASRModuleSetupTests \
  -only-testing:MLXAudioTests/ForceAlignProcessorTests \
  -only-testing:MLXAudioTests/ForcedAlignResultTests \
  -only-testing:MLXAudioTests/Qwen3ASRHelperTests \
  -only-testing:MLXAudioTests/SplitAudioIntoChunksTests \
  -only-testing:MLXAudioTests/Qwen3TTSSpeechTokenizerTests \
  -only-testing:MLXAudioTests/Qwen3TTSSpeechTokenizerEncodeTests \
  -only-testing:MLXAudioTests/Qwen3TTSSpeechTokenizerWeightTests \
  -only-testing:MLXAudioTests/Qwen3TTSLanguageTests \
  -only-testing:MLXAudioTests/Qwen3TTSConfigTests \
  -only-testing:MLXAudioTests/Qwen3TTSRoutingTests \
  -only-testing:MLXAudioTests/Qwen3TTSPrepareBaseInputsTests \
  -only-testing:MLXAudioTests/Qwen3TTSGenerateCustomVoiceTests \
  -only-testing:MLXAudioTests/Qwen3TTSSpeakerEncoderTests \
  -only-testing:MLXAudioTests/Qwen3TTSSpeakerEncoderWeightTests \
  -only-testing:MLXAudioTests/Qwen3TTSSpeakerEmbeddingTests \
  -only-testing:MLXAudioTests/Qwen3TTSPrepareICLInputsTests \
  -only-testing:MLXAudioTests/Qwen3TTSGenerateICLTests \
  -only-testing:MLXAudioTests/Qwen3TTSSpeakerEncoderSmokeTests \
  -only-testing:MLXAudioTests/LlamaTTSModuleSetupTests \
  -only-testing:MLXAudioTests/ParityFixtureLoaderSmokeTests \
  -only-testing:MLXAudioTests/PocketTTSModuleSetupTests \
  -only-testing:MLXAudioTests/SopranoModuleSetupTests \
  -only-testing:MLXAudioTests/MarvisTTSModuleSetupTests \
  -only-testing:MLXAudioTests/MLXAudioCoreDSPTests \
  -only-testing:MLXAudioTests/ModelUtilsTests \
  -only-testing:MLXAudioTests/MimiLayerTests \
  -only-testing:MLXAudioTests/SNACVQTests \
  -only-testing:MLXAudioTests/DACVAEWatermarkerTests \
  -only-testing:MLXAudioTests/UnigramTokenizerRoundTripTests \
  -only-testing:MLXAudioTests/ConvWeightedTests \
  -only-testing:MLXAudioTests/AudioUtilsTests \
  -only-testing:MLXAudioTests/AudioIORoundTripTests \
  CODE_SIGNING_ALLOWED=NO
```

---

## Design Notes

### Why `objc_setAssociatedObject` and not subclassing

`KVCacheSimple` is `public class` (not `open`), so no cross-module
subclass is possible. Wrapping with a forwarding `BaseKVCache` subclass
would change the static type returned by every `makeCache()` factory
(some of which type their return as `[KVCacheSimple]`, not `[KVCache]`)
and ripple through every call site. The associated-objects approach
binds the sentinel's lifetime to the cache without any type changes,
keeping S5's blast radius minimal and S6/S7/S8 patterns easy to copy.

### Why `init` and `deinit` are not behind `#if MLXAUDIO_TELEMETRY_FULL`

Lifecycle instrumentation is at level 1 (`.lifecycle`), which is in the
release ceiling. The compile-time `#if MLXAUDIO_TELEMETRY_FULL` only
gates levels above the release ceiling (`.operations` / `.memory` /
`.verbose`). Per requirements §4 and EXECUTION_PLAN.md S5 task 4, the
lifecycle hook MUST stay compiled in for release builds — it's the
load-bearing leak-detection mechanism. The internal
`Telemetry.trackLifecycle` short-circuits when
`Telemetry.level == .off`, keeping the runtime cost negligible at the
default and embedded levels.

### Why the sentinel uses `OSSignpostIntervalState`, not a manual ID

`OSSignposter.beginInterval(_:id:_:)` returns a typed
`OSSignpostIntervalState` token that pairs cleanly with `endInterval`.
This is the modern (macOS 12+) API and works correctly in both
asynchronous and `deinit` contexts. The sentinel stores the token as
`let` and ends the interval in `deinit` with the matching call. No
explicit pointer-as-ID handling needed.

### Why family-name → signposter is a `switch`, not a dictionary

Switches generate efficient O(1) dispatch via the compiler and do not
need a static initializer. The family list is small (9 entries) and
matched against compile-time-constant strings; a dictionary would
incur a hash lookup and a runtime initializer. `default:` falls back
to `MLXAudioLogging.coreSignposter` so unknown families still work
(no silent no-op).

### Why the test suite is `.serialized`

Same reasoning as `TelemetryCounterStoreTests`: every test mutates
`CounterStore.shared` and calls `Telemetry.resetCounters()`. Without
`.serialized`, parallel test methods would let increments / decrements
/ resets interleave, producing flaky assertions. Suite runs in ~31 ms.

### Why `waitForCounter` uses `Task.sleep(1ms)` and not `Task.yield`

The fire-and-forget `Telemetry.trackLifecycle` helpers spawn
`Task.detached(priority: .background)`. Background-priority tasks can be
deferred behind in-flight test-priority tasks, so a tight `Task.yield`
loop never gives them CPU. Replacing `yield` with a 1 ms `Task.sleep`
gives the background tasks an actual scheduling slot. The total wait
budget is 200 attempts × 1 ms = 200 ms — plenty for a counter to
reach its target on real hardware, but bounded enough to fail a real
leak quickly. Empirically tests complete in 1–25 ms.

### Why test families use unique names per test

`Telemetry.trackLifecycleEnd` is fire-and-forget and uses
`.background` priority, so the decrement from a sentinel released at
the end of one test may land *after* the next test's
`Telemetry.resetCounters()` zeros `liveCounts`, dropping that key into
negative territory and confusing the next test's assertion. Each test
uses a unique family string (`"InitTestFamily"`, `"DeinitTestFamily"`,
`"FamA"`, `"FamB"`, `"FamHost"`, `"LeakTest"`, plus the canonical 9 in
the audit-coverage test). This isolates per-test counter state in a
robust way.

### Why `attachKVCacheLifecycle` is `public`, not `internal`

The KV cache call sites live in `MLXAudioCodecs`, `MLXAudioTTS`, and
`MLXAudioSTT` — three sibling modules that all depend on
`MLXAudioCore`. The helper has to be visible from those consuming
modules, so `public` is the minimum-needed visibility. The internal
sentinel class stays `internal final class` because nothing outside
`MLXAudioCore` constructs it directly.

---

## Out of Scope (per sergeant rules)

- Did NOT instrument TTS/ASR model classes (S6 work).
- Did NOT instrument codec model classes (SNAC, Encodec, DAC, Vocos — S7).
- Did NOT instrument tokenizer / engine classes (S8).
- Did NOT add the broader leak-detection pattern test suite (S9).
- Did NOT modify `EXECUTION_PLAN.md` or `SUPERVISOR_STATE.md`.
- Did NOT touch `main`; all work stayed on `mission/leak-bloodhound/01`.
- Did NOT use `swift build` / `swift test` — only `xcodebuild` per `CLAUDE.md`.
- Did NOT add `#if MLXAUDIO_TELEMETRY_FULL` gates to lifecycle code per
  EXECUTION_PLAN.md S5 task 4.
