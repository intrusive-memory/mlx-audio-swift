# Sortie 7 — Codec model lifecycle hooks (Telemetry.<Codec>.Model counters) — COMPLETE

**Mission**: OPERATION LEAK BLOODHOUND
**Work Unit**: WU-2 Lifecycle Instrumentation
**Sortie**: 7 of 15
**Branch**: `mission/leak-bloodhound/01`
**Commit**: `ee0c20e`

---

## Audit Output

### Codec model classes identified

All five codec families live under `Sources/MLXAudioCodecs/`. Each has a single
top-level model class that is the lifecycle instrumentation target.

| Codec family | Top-level model class | Source file | Counter key | Hook landed |
|---|---|---|---|:---:|
| SNAC | `SNAC` | `Sources/MLXAudioCodecs/SNAC/SNACDecoder.swift` | `SNAC.Model` | yes |
| Mimi | `Mimi` | `Sources/MLXAudioCodecs/Mimi/Mimi.swift` | `Mimi.Model` | yes |
| Encodec | `Encodec` | `Sources/MLXAudioCodecs/Encodec/Encodec.swift` | `Encodec.Model` | yes |
| DAC (DACVAE) | `DACVAE` | `Sources/MLXAudioCodecs/DACVAE/DACVAE.swift` | `DAC.Model` | yes |
| Vocos | `Vocos` | `Sources/MLXAudioCodecs/Vocos/Vocos.swift` | `Vocos.Model` | yes |

**Additional classes examined and excluded** (sub-components, not top-level model classes):

- `EncodecEncoder`, `EncodecDecoder` — encoder/decoder sub-modules within `Encodec`. Not instrumented per plan ("at minimum" the five named families, and these are not long-lived independent objects).
- `DACVAEFullDecoder`, `DACVAEEncoder` — sub-modules of `DACVAE`. Not instrumented.
- `SeanetEncoder`, `SeanetDecoder`, `ProjectedTransformer` — sub-modules of `Mimi`. Not instrumented.
- `MimiStreamingDecoder` — wraps a `Mimi` instance but is not itself a model class; its lifetime is tied to the `Mimi` it wraps.
- `MimiTokenizer` — wraps a `Mimi` instance; counted via the `Mimi.Model` counter of the underlying codec.
- `VocosBackbone`, `ISTFTHead`, `AdaLayerNorm`, `EncodecFeatures` — Vocos sub-modules or feature-extractor components. Not instrumented.
- `SNAC.Encoder`, `SNAC.Decoder`, `ResidualVectorQuantize`, `VectorQuantize` — SNAC sub-modules. Not instrumented.

### Hook implementation notes

**Access level**: `Telemetry.trackLifecycle` / `trackLifecycleEnd` are `public` (promoted in S6) and accessible from `MLXAudioCodecs`.

**Import added**: `Vocos.swift` did not previously import `MLXAudioCore`. Added `import MLXAudioCore` to support the `Telemetry.*` calls.

**`super.init()` additions**: Swift's two-phase initializer requires all stored properties to be set and `super.init()` to be called before `self` can be passed to an external function (`trackLifecycle` receives `self`). The following classes did not previously have explicit `super.init()` calls and needed them added immediately before `trackLifecycle`:

- `SNAC.init` — added `super.init()` before `Telemetry.trackLifecycle`
- `DACVAE.init` — added `super.init()` before `Telemetry.trackLifecycle`
- `Mimi.init` — added `super.init()` before `Telemetry.trackLifecycle`
- `Encodec.init` — added `super.init()` before `Telemetry.trackLifecycle`
- `Vocos.init` — added `super.init()` before `Telemetry.trackLifecycle`

**Signposter**: All five codec families share `MLXAudioLogging.codecsSignposter` (subsystem `MLXAudio.codecs`). Per EXECUTION_PLAN.md, the family is encoded in the **counter key** (`"SNAC.Model"`, `"Mimi.Model"`, etc.), not in separate signposters.

**Release ceiling**: No `#if MLXAUDIO_TELEMETRY_FULL` gate. Lifecycle hooks are in the release ceiling per S5 task 4.

---

## Files Created or Modified

| Path | Change |
|---|---|
| `Sources/MLXAudioCodecs/SNAC/SNACDecoder.swift` | MODIFIED — added `super.init()` + `Telemetry.trackLifecycle(self, className: "SNAC.Model")` in `SNAC.init`; added `deinit`. |
| `Sources/MLXAudioCodecs/Mimi/Mimi.swift` | MODIFIED — added `super.init()` + `Telemetry.trackLifecycle(self, className: "Mimi.Model")` in `Mimi.init`; added `deinit`. |
| `Sources/MLXAudioCodecs/Encodec/Encodec.swift` | MODIFIED — added `super.init()` + `Telemetry.trackLifecycle(self, className: "Encodec.Model")` in `Encodec.init`; added `deinit`. |
| `Sources/MLXAudioCodecs/DACVAE/DACVAE.swift` | MODIFIED — added `super.init()` + `Telemetry.trackLifecycle(self, className: "DAC.Model")` in `DACVAE.init`; added `deinit`. |
| `Sources/MLXAudioCodecs/Vocos/Vocos.swift` | MODIFIED — added `import MLXAudioCore`; added `super.init()` + `Telemetry.trackLifecycle(self, className: "Vocos.Model")` in `Vocos.init`; added `deinit`. |
| `Tests/TelemetryCodecLifecycleSmokeTests.swift` | NEW — `TelemetryCodecLifecycleSmokeTests` Swift Testing suite, 5 tests, `.serialized`. CI-safe (no model downloads). |
| `COMPLETE_S7_CODEC_LIFECYCLE.md` | NEW — this file. |

No other files were modified. `EXECUTION_PLAN.md`, `SUPERVISOR_STATE.md`, `Package.swift`, all WU-1 telemetry sources, and every other production file are unchanged per sergeant rules.

---

## Verification Evidence

### Exit criterion 1: all codec model classes have `trackLifecycle` hooks

```
$ grep -rn "trackLifecycle(self" Sources/MLXAudioCodecs/ --include="*.swift"
Sources/MLXAudioCodecs/SNAC/SNACDecoder.swift:      Telemetry.trackLifecycle(self, className: "SNAC.Model")
Sources/MLXAudioCodecs/Mimi/Mimi.swift:              Telemetry.trackLifecycle(self, className: "Mimi.Model")
Sources/MLXAudioCodecs/Encodec/Encodec.swift:        Telemetry.trackLifecycle(self, className: "Encodec.Model")
Sources/MLXAudioCodecs/DACVAE/DACVAE.swift:          Telemetry.trackLifecycle(self, className: "DAC.Model")
Sources/MLXAudioCodecs/Vocos/Vocos.swift:            Telemetry.trackLifecycle(self, className: "Vocos.Model")
```

5 entries — one per codec family. ✓

### Exit criterion 2: targeted codec test suites pass

```
$ xcodebuild test -scheme MLXAudio-Package -destination 'platform=macOS' \
    -only-testing:MLXAudioTests/VocosTests \
    -only-testing:MLXAudioTests/EncodecTests \
    -only-testing:MLXAudioTests/DACVAETests \
    -only-testing:MLXAudioTests/SNACVQTests \
    -only-testing:MLXAudioTests/MimiLayerTests \
    -only-testing:MLXAudioTests/DACVAEWatermarkerTests \
    CODE_SIGNING_ALLOWED=NO

Suite "MimiLayerTests" passed after 0.096 seconds.
Suite "SNACVQTests" passed after 0.097 seconds.
Suite "DACVAEWatermarkerTests" passed after 0.117 seconds.
Suite VocosTests passed after 0.187 seconds.
Suite DACVAETests passed after 0.495 seconds.
Suite EncodecTests passed after 4.844 seconds.
Test run with 40 tests in 6 suites passed after 4.844 seconds.
** TEST SUCCEEDED **
```

40 / 40 tests pass. ✓

### Codec lifecycle smoke tests pass

```
$ xcodebuild test -scheme MLXAudio-Package -destination 'platform=macOS' \
    -only-testing:MLXAudioTests/TelemetryCodecLifecycleSmokeTests \
    CODE_SIGNING_ALLOWED=NO

Suite "TelemetryCodecLifecycleSmokeTests" started.
Test "SNAC model lifecycle: liveCount returns to 0 after deinit" passed after 0.017 seconds.
Test "Mimi model lifecycle: liveCount returns to 0 after deinit" passed after 0.011 seconds.
Test "Encodec model lifecycle: liveCount returns to 0 after deinit" passed after 0.006 seconds.
Test "DACVAE model lifecycle: liveCount returns to 0 after deinit" passed after 0.009 seconds.
Test "Vocos model lifecycle: liveCount returns to 0 after deinit" passed after 0.005 seconds.
Suite "TelemetryCodecLifecycleSmokeTests" passed after 0.050 seconds.
Test run with 5 tests in 1 suite passed after 0.050 seconds.
** TEST SUCCEEDED **
```

5 / 5 smoke tests pass. ✓

### Exit criterion 3: full CI-safe test block passes

```
$ xcodebuild test -scheme MLXAudio-Package -destination 'platform=macOS' \
    -only-testing:MLXAudioTests/VocosTests \
    -only-testing:MLXAudioTests/EncodecTests \
    -only-testing:MLXAudioTests/DACVAETests \
    [... all 38 CI-safe suites from CLAUDE.md ...] \
    CODE_SIGNING_ALLOWED=NO

Test run with 326 tests in 38 suites passed after 11.198 seconds.
** TEST SUCCEEDED **
```

326 / 326 tests pass. No regressions. ✓

---

## Exact Verification Commands (Re-Executable)

```sh
# 1) Audit: list all trackLifecycle(self, ...) call sites in codec sources
grep -rn "trackLifecycle(self" Sources/MLXAudioCodecs/ --include="*.swift"

# 2) Targeted codec suites (exit criterion 2)
xcodebuild test -scheme MLXAudio-Package -destination 'platform=macOS' \
  -only-testing:MLXAudioTests/VocosTests \
  -only-testing:MLXAudioTests/EncodecTests \
  -only-testing:MLXAudioTests/DACVAETests \
  -only-testing:MLXAudioTests/SNACVQTests \
  -only-testing:MLXAudioTests/MimiLayerTests \
  -only-testing:MLXAudioTests/DACVAEWatermarkerTests \
  CODE_SIGNING_ALLOWED=NO

# 3) Codec lifecycle smoke tests
xcodebuild test -scheme MLXAudio-Package -destination 'platform=macOS' \
  -only-testing:MLXAudioTests/TelemetryCodecLifecycleSmokeTests \
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

- Did NOT instrument tokenizer / engine classes (S8 work).
- Did NOT add the broader leak-detection pattern test suite (S9 work).
- Did NOT modify `EXECUTION_PLAN.md` or `SUPERVISOR_STATE.md`.
- Did NOT commit to `main`; all work stayed on `mission/leak-bloodhound/01`.
- Did NOT use `swift build` / `swift test` — only `xcodebuild` per `CLAUDE.md`.
- Did NOT add `#if MLXAUDIO_TELEMETRY_FULL` gates to lifecycle code per EXECUTION_PLAN.md S5 task 4.
- Did NOT instrument Encodec sub-components (`EncodecEncoder`, `EncodecDecoder`) or Vocos sub-components (`VocosBackbone`, `ISTFTHead`) — only the top-level codec model class per family is in scope.
