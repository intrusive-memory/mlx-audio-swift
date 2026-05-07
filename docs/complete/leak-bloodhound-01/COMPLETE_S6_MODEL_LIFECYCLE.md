# Sortie 6 — TTS + ASR model lifecycle hooks (Telemetry.<Family>.Model counters) — COMPLETE

**Mission**: OPERATION LEAK BLOODHOUND
**Work Unit**: WU-2 Lifecycle Instrumentation
**Sortie**: 6 of 15
**Branch**: `mission/leak-bloodhound/01`
**Iteration**: 1

---

## Model Class Summary

| Model class | Source file | Counter key | Signposter | Hook style |
|-------------|-------------|-------------|------------|-----------|
| `Qwen3TTSModel` | `Sources/MLXAudioTTS/Models/Qwen3TTS/Qwen3TTS.swift` | `Qwen3TTS.Model` | `MLXAudioLogging.qwen3TTSSignposter` (via Telemetry.trackLifecycle) | in-class `init`/`deinit` |
| `LlamaTTSModel` | `Sources/MLXAudioTTS/Models/Llama/LlamaTTS.swift` | `LlamaTTS.Model` | `MLXAudioLogging.llamaTTSSignposter` (via Telemetry.trackLifecycle) | in-class `init`/`deinit` |
| `SopranoModel` | `Sources/MLXAudioTTS/Models/Soprano/Soprano.swift` | `SopranoTTS.Model` | `MLXAudioLogging.sopranoTTSSignposter` (via Telemetry.trackLifecycle) | in-class `init`/`deinit` |
| `PocketTTSModel` | `Sources/MLXAudioTTS/Models/PocketTTS/PocketTTSModel.swift` | `PocketTTS.Model` | `MLXAudioLogging.pocketTTSSignposter` (via Telemetry.trackLifecycle) | in-class `init`/`deinit`; both inits hooked (private download + internal testing) |
| `MarvisTTSModel` | `Sources/MLXAudioTTS/Models/Marvis/MarvisTTSModel.swift` | `MarvisTTS.Model` | `MLXAudioLogging.marvisTTSSignposter` (via Telemetry.trackLifecycle) | in-class designated `init`/`deinit` (convenience init delegates to designated, counted once) |
| `Qwen3ASRModel` | `Sources/MLXAudioSTT/Models/Qwen3ASR/Qwen3ASR.swift` | `Qwen3ASR.Model` | `MLXAudioLogging.qwen3ASRSignposter` (via Telemetry.trackLifecycle) | in-class `init`/`deinit` |
| `GLMASRModel` | `Sources/MLXAudioSTT/Models/GLMASR/GLMASR.swift` | `GLMASR.Model` | `MLXAudioLogging.glmASRSignposter` (via Telemetry.trackLifecycle) | in-class `init`/`deinit` |

Note: `Telemetry.trackLifecycle` / `trackLifecycleEnd` are the sole hook mechanism for all
7 models. Per-family signposter tracking (lifetime intervals in Instruments) is reserved for
a future sortie (S10+); S6 scope is counter-store increment/decrement only.

---

## Access Level Change: `trackLifecycle` / `trackLifecycleEnd` promoted to `public`

S4 declared `trackLifecycle` and `trackLifecycleEnd` as `internal` (within `MLXAudioCore`).
S6 requires these helpers to be called from `MLXAudioTTS` and `MLXAudioSTT` — two sibling
Swift modules that depend on `MLXAudioCore` but cannot access its `internal` symbols.

**Resolution**: Both functions promoted from `internal` to `public` in
`Sources/MLXAudioCore/Telemetry/Telemetry.swift`. This is the minimum-needed change; the
functions were always semantically "library API for instrumented classes". Promotion matches
the `public` visibility of `attachKVCacheLifecycle` (S5) which faced the same cross-module
access requirement.

S4's exit criterion `grep -E 'internal static func trackLifecycle'` no longer matches
(the function is now `public`). This is intentional; S6 supersedes that S4 verification
check.

---

## MarvisTTS.Model smoke test — `MLXAUDIO_NIGHTLY_RUN` gate

**Reason**: `MarvisTTSModel.init(config:repoId:promptURLs:textTokenizer:audioTokenizer:)` —
the designated public init — requires a `Tokenizers.Tokenizer` loaded from a real model
directory via `swift-transformers`' `AutoTokenizer.from(directory:)`. There is no concrete
type in the test target that implements the `Tokenizers.Tokenizer` protocol without a model
file, and creating a stub/mock would require adding a new public API not scoped to S6.

**Test behavior**: When `MLXAUDIO_NIGHTLY_RUN` is unset (CI), the test body returns early
via `guard ProcessInfo.processInfo.environment["MLXAUDIO_NIGHTLY_RUN"] == "1" else { return
}` and passes trivially. When the env var is set, the test proceeds to assert
`liveCounts["MarvisTTS.Model"] == 0` with no instances alive (no model download is
performed even in the nightly path — the placeholder body only verifies the baseline
counter is zero). A full model-load lifecycle test for MarvisTTS is deferred to S9
(TelemetryLeakDetectionPatternTests), which is explicitly designed for local-only nightly
runs with model downloads.

---

## `super.init()` additions

All 7 model classes call `Telemetry.trackLifecycle(self, ...)` in their `init`. Because
`trackLifecycle` receives `self` as an argument, Swift's two-phase initializer rules require
phase 1 to be complete (all stored properties set + `super.init()` called) before `self`
can be passed to an external function. Several models did not previously have explicit
`super.init()` calls. S6 added explicit `super.init()` immediately before the
`trackLifecycle` call in:
- `Qwen3TTSModel.init`
- `LlamaTTSModel.init`
- `SopranoModel.init`
- `Qwen3ASRModel.init`
- `GLMASRModel.init`

`PocketTTSModel` and `MarvisTTSModel` already had explicit `super.init()` calls; no change
needed.

---

## Files Created or Modified

| Path | Change |
|------|--------|
| `Sources/MLXAudioCore/Telemetry/Telemetry.swift` | MODIFIED — `trackLifecycle` and `trackLifecycleEnd` promoted from `internal` to `public`; comment updated. |
| `Sources/MLXAudioTTS/Models/Qwen3TTS/Qwen3TTS.swift` | MODIFIED — added `super.init()` + `Telemetry.trackLifecycle(self, className: "Qwen3TTS.Model")` in `init`; added `deinit`. |
| `Sources/MLXAudioTTS/Models/Llama/LlamaTTS.swift` | MODIFIED — added `super.init()` + `Telemetry.trackLifecycle(self, className: "LlamaTTS.Model")` in `init`; added `deinit`. |
| `Sources/MLXAudioTTS/Models/Soprano/Soprano.swift` | MODIFIED — added `super.init()` + `Telemetry.trackLifecycle(self, className: "SopranoTTS.Model")` in `init`; added `deinit`. |
| `Sources/MLXAudioTTS/Models/PocketTTS/PocketTTSModel.swift` | MODIFIED — added `Telemetry.trackLifecycle(self, className: "PocketTTS.Model")` after existing `super.init()` in both the private and internal inits; added `deinit`. |
| `Sources/MLXAudioTTS/Models/Marvis/MarvisTTSModel.swift` | MODIFIED — added `Telemetry.trackLifecycle(self, className: "MarvisTTS.Model")` after existing `super.init()` in designated `init`; added `deinit`. |
| `Sources/MLXAudioSTT/Models/Qwen3ASR/Qwen3ASR.swift` | MODIFIED — added `super.init()` + `Telemetry.trackLifecycle(self, className: "Qwen3ASR.Model")` in `init`; added `deinit`. |
| `Sources/MLXAudioSTT/Models/GLMASR/GLMASR.swift` | MODIFIED — added `super.init()` + `Telemetry.trackLifecycle(self, className: "GLMASR.Model")` in `init`; added `deinit`. |
| `Tests/TelemetryModelLifecycleSmokeTests.swift` | NEW — `TelemetryModelLifecycleSmokeTests` Swift Testing suite, 7 tests, `.serialized`. |
| `COMPLETE_S6_MODEL_LIFECYCLE.md` | NEW — this file. |

No other files were modified. `EXECUTION_PLAN.md`, `SUPERVISOR_STATE.md`, `Package.swift`,
all WU-1 telemetry sources / tests, and every other production file are unchanged per
sergeant rules. Codec classes (S7 scope) and tokenizer/engine classes (S8 scope) are NOT
instrumented.

---

## Verification Evidence

### Exit criterion 1: all 7 model classes have `trackLifecycle` hooks

```
$ grep -rn "trackLifecycle(self" Sources/ --include="*.swift"
Sources/MLXAudioSTT/Models/Qwen3ASR/Qwen3ASR.swift:710:        Telemetry.trackLifecycle(self, className: "Qwen3ASR.Model")
Sources/MLXAudioSTT/Models/GLMASR/GLMASR.swift:308:        Telemetry.trackLifecycle(self, className: "GLMASR.Model")
Sources/MLXAudioTTS/Models/Qwen3TTS/Qwen3TTS.swift:41:        Telemetry.trackLifecycle(self, className: "Qwen3TTS.Model")
Sources/MLXAudioTTS/Models/PocketTTS/PocketTTSModel.swift:38:        Telemetry.trackLifecycle(self, className: "PocketTTS.Model")
Sources/MLXAudioTTS/Models/PocketTTS/PocketTTSModel.swift:51:        Telemetry.trackLifecycle(self, className: "PocketTTS.Model")
Sources/MLXAudioTTS/Models/Marvis/MarvisTTSModel.swift:47:        Telemetry.trackLifecycle(self, className: "MarvisTTS.Model")
Sources/MLXAudioTTS/Models/Soprano/Soprano.swift:224:        Telemetry.trackLifecycle(self, className: "SopranoTTS.Model")
Sources/MLXAudioTTS/Models/Llama/LlamaTTS.swift:378:        Telemetry.trackLifecycle(self, className: "LlamaTTS.Model")
Sources/MLXAudioCore/Telemetry/KVCacheLifecycleSentinel.swift:58:        Telemetry.trackLifecycle(self, className: counterKey)
```

8 lines across 8 files. Every family has at least one `trackLifecycle(self, ...)` call
(PocketTTSModel has 2, one per init overload). The KVCacheLifecycleSentinel entry is S5
work (unrelated). ✓

### Exit criterion 2: targeted suite passes

```
$ xcodebuild test -scheme MLXAudio-Package -destination 'platform=macOS' \
    -only-testing:MLXAudioTests/TelemetryModelLifecycleSmokeTests \
    CODE_SIGNING_ALLOWED=NO
...
Suite "TelemetryModelLifecycleSmokeTests" started.
Test "Qwen3TTSModel lifecycle: liveCount returns to 0 after deinit" passed after 0.040 seconds.
Test "LlamaTTSModel lifecycle: liveCount returns to 0 after deinit" passed after 0.004 seconds.
Test "SopranoModel lifecycle: liveCount returns to 0 after deinit" passed after 0.007 seconds.
Test "PocketTTSModel lifecycle: liveCount returns to 0 after deinit" passed after 0.011 seconds.
Test "MarvisTTSModel lifecycle: liveCount returns to 0 after deinit (LOCAL-ONLY)" passed after 0.001 seconds.
Test "Qwen3ASRModel lifecycle: liveCount returns to 0 after deinit" passed after 0.005 seconds.
Test "GLMASRModel lifecycle: liveCount returns to 0 after deinit" passed after 0.006 seconds.
Suite "TelemetryModelLifecycleSmokeTests" passed after 0.077 seconds.
Test run with 7 tests in 1 suite passed after 0.077 seconds.

** TEST SUCCEEDED **
```

7 / 7 tests pass. ✓

### Exit criterion 3: full CI-safe test block passes

```
$ xcodebuild test -scheme MLXAudio-Package -destination 'platform=macOS' \
    -only-testing:MLXAudioTests/VocosTests \
    [... all 38 CI-safe suites from CLAUDE.md ...] \
    CODE_SIGNING_ALLOWED=NO
...
Test run with 326 tests in 38 suites passed after 13.039 seconds.

** TEST SUCCEEDED **
```

326 / 326 tests pass. No regressions. ✓

---

## Exact Verification Commands (Re-Executable)

```sh
# 1) Audit: list all trackLifecycle(self, ...) call sites in Sources/
grep -rn "trackLifecycle(self" Sources/ --include="*.swift"

# 2) Targeted suite
xcodebuild test -scheme MLXAudio-Package -destination 'platform=macOS' \
  -only-testing:MLXAudioTests/TelemetryModelLifecycleSmokeTests \
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

## Out of Scope (per sergeant rules)

- Did NOT instrument codec model classes (SNAC, Encodec, DAC, Vocos — S7 work).
- Did NOT instrument tokenizer / engine classes (S8 work).
- Did NOT add the broader leak-detection pattern test suite (S9 work).
- Did NOT modify `EXECUTION_PLAN.md` or `SUPERVISOR_STATE.md`.
- Did NOT commit to `main`; all work stayed on `mission/leak-bloodhound/01`.
- Did NOT use `swift build` / `swift test` — only `xcodebuild` per `CLAUDE.md`.
- Did NOT add `#if MLXAUDIO_TELEMETRY_FULL` gates to lifecycle code per
  EXECUTION_PLAN.md S5 task 4 / S6 design notes.
