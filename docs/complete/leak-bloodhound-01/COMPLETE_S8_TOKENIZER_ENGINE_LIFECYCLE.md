# Sortie 8 — Tokenizer + engine lifecycle hooks (Telemetry.<Family>.Tokenizer/Engine counters) — COMPLETE

**Mission**: OPERATION LEAK BLOODHOUND
**Work Unit**: WU-2 Lifecycle Instrumentation
**Sortie**: 8 of 15
**Branch**: `mission/leak-bloodhound/01`
**Entry criteria**: Sortie 5 COMPLETED (commit `3da7674`)

---

## Audit Output

### Tokenizer classes identified

| Class | Access | Source file | Counter key | Signposter | Hook landed |
|-------|--------|-------------|-------------|------------|:-----------:|
| `Qwen3TTSSpeechTokenizer` | `internal final class: Module` | `Sources/MLXAudioTTS/Models/Qwen3TTS/Qwen3TTSSpeechDecoder.swift` | `Qwen3TTS.Tokenizer` | `qwen3TTSSignposter` (via `Telemetry.trackLifecycle`) | yes |
| `UnigramTokenizer` | `public final class` (no superclass) | `Sources/MLXAudioTTS/Models/PocketTTS/UnigramTokenizer.swift` | `Core.Tokenizer` | `coreSignposter` (via `Telemetry.trackLifecycle`) | yes |
| `SentencePieceTokenizer` | `public final class` (no superclass) | `Sources/MLXAudioTTS/Models/PocketTTS/PocketTTSConditioners.swift` | `PocketTTS.Tokenizer` | `pocketTTSSignposter` (via `Telemetry.trackLifecycle`) | yes |
| `MimiTokenizer` | `public final class` (no superclass) | `Sources/MLXAudioCodecs/Mimi/Mimi.swift` | `Mimi.Tokenizer` | `codecsSignposter` (via `Telemetry.trackLifecycle`) | yes |

### Engine / runner classes identified

No dedicated engine or runner classes (separate from the model objects already instrumented in S6) exist in the public API. The TTS/ASR model classes themselves are the generation engines.

One additional secondary model class was found and instrumented as an engine-type object:

| Class | Access | Source file | Counter key | Signposter | Hook landed |
|-------|--------|-------------|-------------|------------|:-----------:|
| `Qwen3ForcedAlignerModel` | `public class: Module` | `Sources/MLXAudioSTT/Models/Qwen3ASR/Qwen3ForcedAligner.swift` | `Qwen3ASR.Aligner` | `qwen3ASRSignposter` (via `Telemetry.trackLifecycle`) | yes |

### Classes examined and excluded

- `Qwen3TTSSpeechTokenizerDecoder` — internal sub-module within `Qwen3TTSSpeechTokenizer`; not instrumented.
- `Qwen3TTSSpeechTokenizerEncoder` — internal sub-module within `Qwen3TTSSpeechTokenizer`; not instrumented.
- `ForceAlignProcessor` — lightweight stateless utility class with an empty `init()`, no ML resources, not a long-lived object.
- `MimiStreamingDecoder` — wraps a `Mimi` instance (already instrumented as `Mimi.Model`); not separately instrumented.
- All `Module` sub-components (`Attention`, `MLP`, `Block`, `Layer`, `*Encoder`, `*Decoder` sub-modules) — not long-lived independent objects; not instrumented.

---

## Hook implementation notes

**`super.init()` additions**: Swift's two-phase initializer requires all stored properties to be set and `super.init()` called before `self` can be passed to an external function. `Qwen3TTSSpeechTokenizer` (a `Module` subclass) did not previously call `super.init()` explicitly. S8 added it immediately before `Telemetry.trackLifecycle`.

**No `super.init()` needed**: `UnigramTokenizer`, `SentencePieceTokenizer`, and `MimiTokenizer` are all `final class` with no explicit superclass — they call `Telemetry.trackLifecycle(self, ...)` directly after all stored properties are set.

**`import MLXAudioCore` additions**:
- `UnigramTokenizer.swift` had no imports at all; `import MLXAudioCore` was added.
- `PocketTTSConditioners.swift` imported `Foundation`, `MLX`, `MLXNN` but not `MLXAudioCore`; the import was added.
- `Mimi.swift` and `Qwen3TTSSpeechDecoder.swift` already imported `MLXAudioCore`.
- `Qwen3ForcedAligner.swift` already imported `MLXAudioCore`.

**Multiple inits in `SentencePieceTokenizer`**: Three inits exist (async file-loading, testing stub, sync file-loading). All three received `Telemetry.trackLifecycle(self, className: "PocketTTS.Tokenizer")` at their end. A single `deinit` provides the matching decrement.

**`UnigramTokenizer` + `SentencePieceTokenizer` double-counting**: Each `SentencePieceTokenizer` creates one `UnigramTokenizer`. Both now have lifecycle hooks, so constructing a `SentencePieceTokenizer` increments both `PocketTTS.Tokenizer` AND `Core.Tokenizer`. This is intentional — `Core.Tokenizer` tracks all `UnigramTokenizer` instances regardless of how they are created (including direct construction in tests), while `PocketTTS.Tokenizer` tracks the higher-level tokenizer wrapper.

**Release ceiling**: No `#if MLXAUDIO_TELEMETRY_FULL` gate on any lifecycle hook.

---

## Files Created or Modified

| Path | Change |
|------|--------|
| `Sources/MLXAudioTTS/Models/Qwen3TTS/Qwen3TTSSpeechDecoder.swift` | MODIFIED — added `super.init()` + `Telemetry.trackLifecycle(self, className: "Qwen3TTS.Tokenizer")` in `Qwen3TTSSpeechTokenizer.init`; added `deinit`. |
| `Sources/MLXAudioTTS/Models/PocketTTS/UnigramTokenizer.swift` | MODIFIED — added `import MLXAudioCore` at top; added `Telemetry.trackLifecycle(self, className: "Core.Tokenizer")` at end of `init`; added `deinit`. |
| `Sources/MLXAudioTTS/Models/PocketTTS/PocketTTSConditioners.swift` | MODIFIED — added `import MLXAudioCore`; added `Telemetry.trackLifecycle(self, className: "PocketTTS.Tokenizer")` at end of all three `SentencePieceTokenizer` inits; added `deinit`. |
| `Sources/MLXAudioCodecs/Mimi/Mimi.swift` | MODIFIED — added `Telemetry.trackLifecycle(self, className: "Mimi.Tokenizer")` in `MimiTokenizer.init`; added `deinit`. |
| `Sources/MLXAudioSTT/Models/Qwen3ASR/Qwen3ForcedAligner.swift` | MODIFIED — added `super.init()` + `Telemetry.trackLifecycle(self, className: "Qwen3ASR.Aligner")` in `Qwen3ForcedAlignerModel.init`; added `deinit`. |
| `Tests/TelemetryTokenizerEngineLifecycleSmokeTests.swift` | NEW — `TelemetryTokenizerEngineLifecycleSmokeTests` Swift Testing suite, 5 tests, `.serialized`. CI-safe (no model downloads). |
| `COMPLETE_S8_TOKENIZER_ENGINE_LIFECYCLE.md` | NEW — this file. |

No other files were modified. `EXECUTION_PLAN.md`, `SUPERVISOR_STATE.md`, `Package.swift`, all WU-1 telemetry sources, and every other production file are unchanged per sergeant rules.

---

## Verification Evidence

### Exit criterion 1: all tokenizer + engine classes have lifecycle hooks

```
$ grep -rn "trackLifecycle(self" Sources/ --include="*.swift"
Sources/MLXAudioCodecs/Mimi/Mimi.swift:157:        Telemetry.trackLifecycle(self, className: "Mimi.Model")
Sources/MLXAudioCodecs/Mimi/Mimi.swift:400:        Telemetry.trackLifecycle(self, className: "Mimi.Tokenizer")
Sources/MLXAudioCodecs/SNAC/SNACDecoder.swift:...  Telemetry.trackLifecycle(self, className: "SNAC.Model")
Sources/MLXAudioCodecs/Encodec/Encodec.swift:...   Telemetry.trackLifecycle(self, className: "Encodec.Model")
Sources/MLXAudioCodecs/DACVAE/DACVAE.swift:...     Telemetry.trackLifecycle(self, className: "DAC.Model")
Sources/MLXAudioCodecs/Vocos/Vocos.swift:...       Telemetry.trackLifecycle(self, className: "Vocos.Model")
Sources/MLXAudioSTT/Models/Qwen3ASR/Qwen3ASR.swift:710:        Telemetry.trackLifecycle(self, className: "Qwen3ASR.Model")
Sources/MLXAudioSTT/Models/Qwen3ASR/Qwen3ForcedAligner.swift:...Telemetry.trackLifecycle(self, className: "Qwen3ASR.Aligner")
Sources/MLXAudioSTT/Models/GLMASR/GLMASR.swift:308:        Telemetry.trackLifecycle(self, className: "GLMASR.Model")
Sources/MLXAudioTTS/Models/Qwen3TTS/Qwen3TTS.swift:41:        Telemetry.trackLifecycle(self, className: "Qwen3TTS.Model")
Sources/MLXAudioTTS/Models/Qwen3TTS/Qwen3TTSSpeechDecoder.swift:...Telemetry.trackLifecycle(self, className: "Qwen3TTS.Tokenizer")
Sources/MLXAudioTTS/Models/PocketTTS/PocketTTSModel.swift:...  Telemetry.trackLifecycle(self, className: "PocketTTS.Model") (×2)
Sources/MLXAudioTTS/Models/PocketTTS/PocketTTSConditioners.swift:...Telemetry.trackLifecycle(self, className: "PocketTTS.Tokenizer") (×3)
Sources/MLXAudioTTS/Models/PocketTTS/UnigramTokenizer.swift:...Telemetry.trackLifecycle(self, className: "Core.Tokenizer")
Sources/MLXAudioTTS/Models/Marvis/MarvisTTSModel.swift:47:     Telemetry.trackLifecycle(self, className: "MarvisTTS.Model")
Sources/MLXAudioTTS/Models/Soprano/Soprano.swift:224:          Telemetry.trackLifecycle(self, className: "SopranoTTS.Model")
Sources/MLXAudioTTS/Models/Llama/LlamaTTS.swift:378:           Telemetry.trackLifecycle(self, className: "LlamaTTS.Model")
Sources/MLXAudioCore/Telemetry/KVCacheLifecycleSentinel.swift:...Telemetry.trackLifecycle(self, className: counterKey)
```

All S8 tokenizer + engine targets are present. ✓

### Exit criterion 2: targeted tokenizer suite passes

```
$ xcodebuild test -scheme MLXAudio-Package -destination 'platform=macOS' \
    -only-testing:MLXAudioTests/UnigramTokenizerRoundTripTests \
    -only-testing:MLXAudioTests/Qwen3TTSSpeechTokenizerTests \
    -only-testing:MLXAudioTests/Qwen3TTSSpeechTokenizerEncodeTests \
    -only-testing:MLXAudioTests/Qwen3TTSSpeechTokenizerWeightTests \
    CODE_SIGNING_ALLOWED=NO

Suite "UnigramTokenizerRoundTripTests" passed after 0.043 seconds.
Suite Qwen3TTSSpeechTokenizerTests passed after 0.063 seconds.
Suite Qwen3TTSSpeechTokenizerEncodeTests passed after 0.196 seconds.
Suite Qwen3TTSSpeechTokenizerWeightTests passed after 0.026 seconds.
Test run with 19 tests in 4 suites passed after 0.196 seconds.

** TEST SUCCEEDED **
```

19 / 19 tests pass. ✓

### New smoke tests pass

```
$ xcodebuild test -scheme MLXAudio-Package -destination 'platform=macOS' \
    -only-testing:MLXAudioTests/TelemetryTokenizerEngineLifecycleSmokeTests \
    CODE_SIGNING_ALLOWED=NO

Suite "TelemetryTokenizerEngineLifecycleSmokeTests" started.
Test "Qwen3TTSSpeechTokenizer lifecycle: liveCount returns to 0 after deinit" passed after 0.034 seconds.
Test "UnigramTokenizer lifecycle: liveCount returns to 0 after deinit" passed after 0.004 seconds.
Test "SentencePieceTokenizer lifecycle: liveCount returns to 0 after deinit" passed after 0.003 seconds.
Test "MimiTokenizer lifecycle: liveCount returns to 0 after deinit" passed after 0.025 seconds.
Test "Qwen3ForcedAlignerModel lifecycle: liveCount returns to 0 after deinit" passed after 0.005 seconds.
Suite "TelemetryTokenizerEngineLifecycleSmokeTests" passed after 0.074 seconds.
Test run with 5 tests in 1 suite passed after 0.074 seconds.

** TEST SUCCEEDED **
```

5 / 5 smoke tests pass. ✓

### Exit criterion 3: full CI-safe test block passes

```
$ xcodebuild test -scheme MLXAudio-Package -destination 'platform=macOS' \
    -only-testing:MLXAudioTests/VocosTests \
    [... all 38 CI-safe suites from CLAUDE.md ...] \
    CODE_SIGNING_ALLOWED=NO

Test run with 326 tests in 38 suites passed after 10.935 seconds.

** TEST SUCCEEDED **
```

326 / 326 tests pass. No regressions. ✓

---

## Exact Verification Commands (Re-Executable)

```sh
# 1) Audit: list all trackLifecycle(self, ...) call sites in Sources/
grep -rn "trackLifecycle(self" Sources/ --include="*.swift"

# 2) Targeted tokenizer suites (exit criterion 2)
xcodebuild test -scheme MLXAudio-Package -destination 'platform=macOS' \
  -only-testing:MLXAudioTests/UnigramTokenizerRoundTripTests \
  -only-testing:MLXAudioTests/Qwen3TTSSpeechTokenizerTests \
  -only-testing:MLXAudioTests/Qwen3TTSSpeechTokenizerEncodeTests \
  -only-testing:MLXAudioTests/Qwen3TTSSpeechTokenizerWeightTests \
  CODE_SIGNING_ALLOWED=NO

# 3) Tokenizer + engine lifecycle smoke tests
xcodebuild test -scheme MLXAudio-Package -destination 'platform=macOS' \
  -only-testing:MLXAudioTests/TelemetryTokenizerEngineLifecycleSmokeTests \
  CODE_SIGNING_ALLOWED=NO

# 4) Full CI-safe block (verbatim from CLAUDE.md)
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

- Did NOT begin S9 (leak-detection pattern + nightly integration).
- Did NOT modify `EXECUTION_PLAN.md` or `SUPERVISOR_STATE.md`.
- Did NOT commit to `main`; all work stayed on `mission/leak-bloodhound/01`.
- Did NOT use `swift build` / `swift test` — only `xcodebuild` per `CLAUDE.md`.
- Did NOT add `#if MLXAUDIO_TELEMETRY_FULL` gates to lifecycle code per EXECUTION_PLAN.md S5 task 4.
- Did NOT instrument sub-components (`Qwen3TTSSpeechTokenizerDecoder`, `Qwen3TTSSpeechTokenizerEncoder`, `ForceAlignProcessor`, `MimiStreamingDecoder`) — only top-level tokenizer and engine classes are in scope.
