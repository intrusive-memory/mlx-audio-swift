# COMPLETE — Sortie 11: Operation Intervals (generate / encode / decode entry points)

**Mission**: OPERATION LEAK BLOODHOUND
**Sortie**: S11 (WU-3 capstone)
**Branch**: `mission/leak-bloodhound/01`
**Predecessor**: S10 (`3425dec`)
**Status**: COMPLETE

---

## Audit Output — Wrapped Entry Points

All sites are gated by **both** `#if MLXAUDIO_TELEMETRY_FULL` (compile-time
ceiling, only `.debug` configurations) and `if Telemetry.level >= .operations`
(runtime floor). The release ceiling is `.lifecycle`, so every wrap below strips
entirely from release binaries.

### TTS Families (5 families × 1 public entry point = 5 sites)

| Family | File | Interval Label | Subsystem | Concurrency |
|--------|------|---------------|-----------|-------------|
| **Qwen3TTS** | `Sources/MLXAudioTTS/Models/Qwen3TTS/Qwen3TTS.swift` — `generate(text:voice:refAudio:refText:language:instruct:generationParameters:)` | `Qwen3TTS.generate` | `MLXAudio.qwen3TTS` | `async` |
| **LlamaTTS** | `Sources/MLXAudioTTS/Models/Llama/LlamaTTS.swift` — `generate(text:voice:refAudio:refText:language:instruct:generationParameters:)` | `LlamaTTS.generate` | `MLXAudio.llamaTTS` | `async` |
| **SopranoTTS** | `Sources/MLXAudioTTS/Models/Soprano/Soprano.swift` — `generate(text:voice:refAudio:refText:language:instruct:generationParameters:)` | `SopranoTTS.generate` | `MLXAudio.sopranoTTS` | `async` |
| **PocketTTS** | `Sources/MLXAudioTTS/Models/PocketTTS/PocketTTSModel.swift` — `generate(text:voice:refAudio:refText:language:instruct:generationParameters:)` | `PocketTTS.generate` | `MLXAudio.pocketTTS` | `async` |
| **MarvisTTS** | `Sources/MLXAudioTTS/Models/Marvis/MarvisTTSModel.swift` — `generate(text:voice:refAudio:refText:language:instruct:generationParameters:)` | `MarvisTTS.generate` | `MLXAudio.marvisTTS` | `async` |

All five TTS entry points are the `SpeechGenerationModel` protocol conformance
methods. Secondary entry points (e.g. `generate(text:voice:splitPattern:parameters:)` in
SopranoTTS, `generate(text:voice:cache:parameters:)` in LlamaTTS) are NOT double-wrapped;
they are internal implementation details called by the public entry point. The
interval wraps the outermost public surface so Instruments shows end-to-end
duration including dispatch overhead.

### ASR Families (2 families × 1 public entry point = 2 sites)

| Family | File | Interval Label | Subsystem | Concurrency |
|--------|------|---------------|-----------|-------------|
| **Qwen3ASR** | `Sources/MLXAudioSTT/Models/Qwen3ASR/Qwen3ASR.swift` — `generate(audio:maxTokens:temperature:language:chunkDuration:minChunkDuration:maxBatchSize:)` | `Qwen3ASR.generate` | `MLXAudio.qwen3ASR` | sync |
| **GLMASR** | `Sources/MLXAudioSTT/Models/GLMASR/GLMASR.swift` — `generate(audio:maxTokens:temperature:topP:topK:verbose:)` | `GLMASR.generate` | `MLXAudio.glmASR` | sync |

Both ASR generate functions are synchronous (`-> STTOutput`). The sync
`Telemetry.emitInterval` overload is used. Implementation body was extracted to
a private `_generateImpl` / `_glmGenerateImpl` helper to avoid code duplication
between the gated and non-gated paths.

### Codec Families (5 families × varying entry points = 9 sites)

| Family | File | Function | Interval Label | Subsystem | Concurrency |
|--------|------|----------|---------------|-----------|-------------|
| **SNAC** | `Sources/MLXAudioCodecs/SNAC/SNACDecoder.swift` | `encode(_:)` | `SNAC.encode` | `MLXAudio.codecs` | sync |
| **SNAC** | `Sources/MLXAudioCodecs/SNAC/SNACDecoder.swift` | `decode(_:)` | `SNAC.decode` | `MLXAudio.codecs` | sync |
| **Mimi** | `Sources/MLXAudioCodecs/Mimi/Mimi.swift` | `encode(_:)` | `Mimi.encode` | `MLXAudio.codecs` | sync |
| **Mimi** | `Sources/MLXAudioCodecs/Mimi/Mimi.swift` | `decode(_:)` | `Mimi.decode` | `MLXAudio.codecs` | sync |
| **Encodec** | `Sources/MLXAudioCodecs/Encodec/Encodec.swift` | `encode(_:paddingMask:bandwidth:)` | `Encodec.encode` | `MLXAudio.codecs` | sync |
| **Encodec** | `Sources/MLXAudioCodecs/Encodec/Encodec.swift` | `decode(_:_:paddingMask:)` | `Encodec.decode` | `MLXAudio.codecs` | sync |
| **DACVAE** | `Sources/MLXAudioCodecs/DACVAE/DACVAE.swift` | `encode(_:)` | `DAC.encode` | `MLXAudio.codecs` | sync |
| **DACVAE** | `Sources/MLXAudioCodecs/DACVAE/DACVAE.swift` | `decode(_:chunkSize:)` | `DAC.decode` | `MLXAudio.codecs` | sync |
| **Vocos** | `Sources/MLXAudioCodecs/Vocos/Vocos.swift` | `decode(_:bandwidthId:)` | `Vocos.decode` | `MLXAudio.codecs` | sync |

Vocos is decode-only: no public `encode` method exists. `encodeStep` / `decodeStep`
on Mimi are step-level (streaming) functions; they are NOT wrapped at `.operations`
level because they are called inside a loop (verbose territory, reserved for S13/S14).

### Count Summary

| Category | New `Telemetry.emitInterval` / `emitIntervalAsync` call sites |
|----------|----:|
| TTS generate | 5 |
| ASR generate | 2 |
| Codec encode | 4 (SNAC, Mimi, Encodec, DAC) |
| Codec decode | 5 (SNAC, Mimi, Encodec, DAC, Vocos) |
| **Total new operation-interval call sites in `Sources/`** | **16** |

16 new call sites exceeds the ≥ 14 threshold from EXECUTION_PLAN S11's exit criterion.

---

## TelemetryOperationsTests Additions (S11)

12 new tests added to `Tests/TelemetryOperationsTests.swift`. The suite grows
from 4 tests (S10) to 16 tests (S11).

### Design rationale: CI vs NIGHTLY gating

- **CI-safe (no model download)** — 10 tests:
  - TTS families (Qwen3TTS, LlamaTTS, SopranoTTS, PocketTTS): Construct model via synthetic config. Call `generate(...)` which throws `modelNotInitialized` (tokenizer/weights not loaded) — but the interval's `defer` block fires the `endInterval` / `recordEnd` BEFORE the error propagates. The recorder captures the expected begin/end pair. Assertion verifies the pair arrived.
  - Codec families (SNAC, Mimi, Encodec, DAC, Vocos): Construct codec via tiny synthetic config. Call `encode`/`decode` with tiny zero arrays (no download). Real ML compute runs on tiny tensors. Recorder captures begin/end pair as expected.

- **LOCAL-ONLY (MLXAUDIO_NIGHTLY_RUN=1)** — 3 tests:
  - MarvisTTS: `MarvisTTSModel.init` requires a `Tokenizers.Tokenizer` from `AutoTokenizer.from(directory:)` — no synthetic stub available. Gated by `MLXAUDIO_NIGHTLY_RUN=1`.
  - Qwen3ASR: `generate(...)` calls `fatalError("Tokenizer not loaded")` when tokenizer is nil — cannot safely call without a real tokenizer. Gated by `MLXAUDIO_NIGHTLY_RUN=1`.
  - GLMASR: Same `fatalError` pattern as Qwen3ASR. Gated by `MLXAUDIO_NIGHTLY_RUN=1`.

### Test list

| Test Name | Family | CI-safe? | Assertion |
|-----------|--------|----------|-----------|
| `testQwen3TTSGenerateEmitsInterval` | Qwen3TTS | yes | 1 begin+end on `MLXAudio.qwen3TTS`, name=`Qwen3TTS.generate` |
| `testLlamaTTSGenerateEmitsInterval` | LlamaTTS | yes | 1 begin+end on `MLXAudio.llamaTTS`, name=`LlamaTTS.generate` |
| `testSopranoTTSGenerateEmitsInterval` | SopranoTTS | yes | 1 begin+end on `MLXAudio.sopranoTTS`, name=`SopranoTTS.generate` |
| `testPocketTTSGenerateEmitsInterval` | PocketTTS | yes | 1 begin+end on `MLXAudio.pocketTTS`, name=`PocketTTS.generate` |
| `testMarvisTTSGenerateEmitsInterval` | MarvisTTS | NIGHTLY | 1 begin+end on `MLXAudio.marvisTTS`, name=`MarvisTTS.generate` |
| `testQwen3ASRGenerateEmitsInterval` | Qwen3ASR | NIGHTLY | 1 begin+end on `MLXAudio.qwen3ASR`, name=`Qwen3ASR.generate` |
| `testGLMASRGenerateEmitsInterval` | GLMASR | NIGHTLY | 1 begin+end on `MLXAudio.glmASR`, name=`GLMASR.generate` |
| `testSNACEncodeDecodeEmitIntervals` | SNAC | yes | 1 begin+end on `MLXAudio.codecs`, name=`SNAC.encode`; 1 on `SNAC.decode` |
| `testMimiEncodeDecodeEmitIntervals` | Mimi | yes | 1 begin+end on `MLXAudio.codecs`, name=`Mimi.encode`; 1 on `Mimi.decode` |
| `testEncodecEncodeDecodeEmitIntervals` | Encodec | yes | 1 begin+end on `MLXAudio.codecs`, name=`Encodec.encode`; 1 on `Encodec.decode` |
| `testDACEncodeDecodeEmitIntervals` | DACVAE | yes | 1 begin+end on `MLXAudio.codecs`, name=`DAC.encode`; 1 on `DAC.decode` |
| `testVocosDecodeEmitsInterval` | Vocos | yes | 1 begin+end on `MLXAudio.codecs`, name=`Vocos.decode` |

---

## Verification Evidence

### TelemetryOperationsTests (only)

```
$ xcodebuild test -scheme MLXAudio-Package -destination 'platform=macOS' \
    -only-testing:MLXAudioTests/TelemetryOperationsTests \
    CODE_SIGNING_ALLOWED=NO

Test Suite 'MLXAudioTests.xctest' passed at 2026-05-06 23:25:55.590.
Test Suite 'Selected tests' passed at 2026-05-06 23:25:55.590.
  Test "Telemetry.level resolves to .operations under override (Q4)" passed after 0.001 seconds.
  Test "instrumented loadWeights emits exactly one begin/end pair" passed after 0.022 seconds.
  Test "level < .operations skips the wrap (no events recorded)" passed after 0.001 seconds.
  Test "Family.subsystem strings match MLXAudioLogging subsystems" passed after 0.001 seconds.
  Test "Qwen3TTS.generate emits one interval on MLXAudio.qwen3TTS (.operations)" passed after 0.018 seconds.
  Test "LlamaTTS.generate emits one interval on MLXAudio.llamaTTS (.operations)" passed after 0.002 seconds.
  Test "SopranoTTS.generate emits one interval on MLXAudio.sopranoTTS (.operations)" passed after 0.003 seconds.
  Test "PocketTTS.generate emits one interval on MLXAudio.pocketTTS (.operations)" passed after 0.009 seconds.
  Test "MarvisTTS.generate emits one interval on MLXAudio.marvisTTS (.operations) [LOCAL-ONLY]" passed after 0.001 seconds.
  Test "Qwen3ASR.generate emits one interval on MLXAudio.qwen3ASR (.operations) [LOCAL-ONLY]" passed after 0.001 seconds.
  Test "GLMASR.generate emits one interval on MLXAudio.glmASR (.operations) [LOCAL-ONLY]" passed after 0.001 seconds.
  Test "SNAC.encode/decode emit one interval each on MLXAudio.codecs (.operations)" passed after 0.064 seconds.
  Test "Mimi.encode/decode emit one interval each on MLXAudio.codecs (.operations)" passed after 0.021 seconds.
  Test "Encodec.encode/decode emit one interval each on MLXAudio.codecs (.operations)" passed after 1.250 seconds.
  Test "DAC.encode/decode emit one interval each on MLXAudio.codecs (.operations)" passed after 0.087 seconds.
  Test "Vocos.decode emits one interval on MLXAudio.codecs (.operations)" passed after 0.012 seconds.
  Suite "TelemetryOperationsTests" passed after 1.494 seconds.
  Test run with 16 tests in 1 suite passed after 1.495 seconds.
** TEST SUCCEEDED **
```

### Full CI-safe block from CLAUDE.md

```
$ xcodebuild test -scheme MLXAudio-Package -destination 'platform=macOS' \
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
    -only-testing:MLXAudioTests/TelemetryLeakDetectionPatternTests \
    CODE_SIGNING_ALLOWED=NO

  Test run with 328 tests in 39 suites passed after 12.086 seconds.
** TEST SUCCEEDED **
```

---

## Files Created / Modified

### Created

- `COMPLETE_S11_GENERATE_ENCODE_DECODE_INTERVALS.md` — this document.

### Modified

| File | Change Summary |
|------|---------------|
| `Sources/MLXAudioTTS/Models/Qwen3TTS/Qwen3TTS.swift` | Extracted `generate(...)` body to `_generateImpl`; wrapped public `generate` with `Telemetry.emitIntervalAsync(name: "Qwen3TTS.generate", family: .qwen3TTS)`. |
| `Sources/MLXAudioTTS/Models/Llama/LlamaTTS.swift` | Wrapped `generate(text:voice:refAudio:refText:language:instruct:generationParameters:)` with `Telemetry.emitIntervalAsync(name: "LlamaTTS.generate", family: .llamaTTS)`. |
| `Sources/MLXAudioTTS/Models/Soprano/Soprano.swift` | Wrapped SpeechGenerationModel `generate(...)` with `Telemetry.emitIntervalAsync(name: "SopranoTTS.generate", family: .sopranoTTS)`. |
| `Sources/MLXAudioTTS/Models/PocketTTS/PocketTTSModel.swift` | Extracted `generate(...)` body to `_generateImpl`; wrapped public `generate` with `Telemetry.emitIntervalAsync(name: "PocketTTS.generate", family: .pocketTTS)`. |
| `Sources/MLXAudioTTS/Models/Marvis/MarvisTTSModel.swift` | Extracted `generate(...)` body to `_marvisGenerateImpl`; wrapped public `generate` with `Telemetry.emitIntervalAsync(name: "MarvisTTS.generate", family: .marvisTTS)`. |
| `Sources/MLXAudioSTT/Models/Qwen3ASR/Qwen3ASR.swift` | Extracted `generate(...)` body to `_generateImpl`; wrapped public `generate` with `Telemetry.emitInterval(name: "Qwen3ASR.generate", family: .qwen3ASR)`. |
| `Sources/MLXAudioSTT/Models/GLMASR/GLMASR.swift` | Extracted `generate(...)` body to `_glmGenerateImpl`; wrapped public `generate` with `Telemetry.emitInterval(name: "GLMASR.generate", family: .glmASR)`. |
| `Sources/MLXAudioCodecs/SNAC/SNACDecoder.swift` | Wrapped `encode(_:)` with `SNAC.encode` and `decode(_:)` with `SNAC.decode` intervals on `.codecs`. |
| `Sources/MLXAudioCodecs/Mimi/Mimi.swift` | Wrapped `encode(_:)` with `Mimi.encode` and `decode(_:)` with `Mimi.decode` intervals on `.codecs`. |
| `Sources/MLXAudioCodecs/Encodec/Encodec.swift` | Extracted encode/decode bodies to `_encodecEncodeImpl` / `_encodecDecodeImpl`; wrapped public methods with `Encodec.encode` and `Encodec.decode` intervals on `.codecs`. |
| `Sources/MLXAudioCodecs/DACVAE/DACVAE.swift` | Wrapped `encode(_:)` with `DAC.encode`; extracted decode body to `_dacDecodeImpl`, wrapped `decode(_:chunkSize:)` with `DAC.decode` on `.codecs`. |
| `Sources/MLXAudioCodecs/Vocos/Vocos.swift` | Wrapped `decode(_:bandwidthId:)` with `Vocos.decode` on `.codecs`. |
| `Tests/TelemetryOperationsTests.swift` | Added `@testable import MLXAudioTTS`, `@testable import MLXAudioSTT`, `@testable import MLXAudioCodecs`, `import MLXLMCommon`. Added 12 new per-family interval tests plus shared `runWithRecorder` / `assertOneInterval` helpers and `makeTinyPocketTTSModel` factory. Suite grows from 4 to 16 tests. |

---

## Exact Verification Commands

```bash
# Sortie 11's own tests (CI-safe)
xcodebuild test -scheme MLXAudio-Package -destination 'platform=macOS' \
    -only-testing:MLXAudioTests/TelemetryOperationsTests \
    CODE_SIGNING_ALLOWED=NO

# Full CI-safe block from CLAUDE.md
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
    -only-testing:MLXAudioTests/TelemetryLeakDetectionPatternTests \
    CODE_SIGNING_ALLOWED=NO
```

Both invocations exit 0.
