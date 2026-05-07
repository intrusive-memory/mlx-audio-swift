# Sortie 9 — Leak detection test pattern (CI-safe) + per-family local-only leak suites + nightly wiring — COMPLETE

**Mission**: OPERATION LEAK BLOODHOUND
**Work Unit**: WU-2 Lifecycle Instrumentation (capstone)
**Sortie**: 9 of 15
**Branch**: `mission/leak-bloodhound/01`
**Entry criteria**: Sorties 5–8 COMPLETED (commits `3da7674`, `5027e35`, `38585e1`, `790dcd5`)

---

## Canonical Leak-Detection Pattern (as encoded in TelemetryLeakDetectionPatternTests)

The canonical pattern mirrors `docs/TELEMETRY_REQUIREMENTS.md` Section 7 verbatim:

```swift
// Step 1: Reset counters to a known-zero state.
await Telemetry.resetCounters()

// Step 2: Capture the baseline snapshot BEFORE the allocation loop.
// Using delta (after - before) handles pre-existing live instances.
let before = await Telemetry.snapshot()

// Step 3: Loop — construct + drop inside autoreleasepool.
for _ in 0..<N {
    autoreleasepool {
        let obj = InstrumentedClass(config: syntheticConfig)
        _ = obj
        // ARC releases at end of autoreleasepool → deinit → trackLifecycleEnd
    }
}

// Step 4: Drain in-flight background Tasks before asserting.
let after = await waitForCounter(key, target: before.liveCounts[key, default: 0])

// Step 5: Assert delta is zero — no instances leaked.
#expect(
    after.liveCounts[key, default: 0] == before.liveCounts[key, default: 0],
    "Instances leaked across N iterations"
)
```

### Two instrumentation idioms exercised

**Idiom 1 — In-class init/deinit (S6/S7/S8 style)**
Test: `patternInClassInitDeinit` — creates 10 `LlamaTTSModel` instances with a tiny synthetic
config (no model download), drops them all, asserts `LlamaTTS.Model` delta == 0.
Used by: all 7 model classes, 5 codec models, and 4 tokenizer classes.

**Idiom 2 — Sentinel / associated-object (S5 style)**
Test: `patternSentinelAssociatedObject` — creates 15 `KVCacheSimple` instances each tagged
via `attachKVCacheLifecycle(family: "Sentinel", to:)`, drops them all, asserts
`Sentinel.KVCache` delta == 0.
Used by: all KV cache classes from MLXLMCommon (externally owned, non-subclassable).

Both tests are CI-safe (synthetic configs, no model downloads).

---

## Local-Only Leak Suites Added (one per major family)

| Suite | Counter keys | Family signposters exercised |
|-------|-------------|------------------------------|
| `TelemetryLeakDetectionQwen3TTSTests` | `Qwen3TTS.Model`, `Qwen3TTS.KVCache` | `qwen3TTSSignposter` |
| `TelemetryLeakDetectionLlamaTTSTests` | `LlamaTTS.Model`, `LlamaTTS.KVCache` | `llamaTTSSignposter` |
| `TelemetryLeakDetectionSopranoTTSTests` | `SopranoTTS.Model`, `SopranoTTS.KVCache` | `sopranoTTSSignposter` |
| `TelemetryLeakDetectionPocketTTSTests` | `PocketTTS.Model`, `PocketTTS.KVCache`, `PocketTTS.Tokenizer` | `pocketTTSSignposter` |
| `TelemetryLeakDetectionMarvisTTSTests` | `MarvisTTS.Model`, `MarvisTTS.KVCache`, `Mimi.Model`, `Mimi.Tokenizer` | `marvisTTSSignposter`, `codecsSignposter` |
| `TelemetryLeakDetectionQwen3ASRTests` | `Qwen3ASR.Model`, `Qwen3ASR.KVCache`, `Qwen3ASR.Aligner` | `qwen3ASRSignposter` |
| `TelemetryLeakDetectionGLMASRTests` | `GLMASR.Model`, `GLMASR.KVCache` | `glmASRSignposter` |

All 7 suites are gated by `guard ProcessInfo.processInfo.environment["MLXAUDIO_NIGHTLY_RUN"] == "1" else { return }` — they pass trivially in CI (no model downloads) and run the full leak-detection body only in nightly (where the mlx-models-v2 cache is populated).

---

## How Nightly Invokes These (nightly-tests.yaml diff)

New steps appended after the `Test Weight Round-Trip (local-only)` step, before the `Upload nightly test output` step:

```yaml
      - name: Leak detection - Qwen3TTS (local-only)
        env:
          MLXAUDIO_NIGHTLY_RUN: "1"
        run: |
          xcodebuild test-without-building \
            -scheme MLXAudio-Package \
            -destination 'platform=macOS,arch=arm64' \
            -only-testing:MLXAudioTests/TelemetryLeakDetectionQwen3TTSTests \
            CODE_SIGNING_ALLOWED=NO \
            2>&1 | tee test-leak-qwen3tts-output.log

      - name: Leak detection - LlamaTTS (local-only)
        env:
          MLXAUDIO_NIGHTLY_RUN: "1"
        run: |
          xcodebuild test-without-building \
            -scheme MLXAudio-Package \
            -destination 'platform=macOS,arch=arm64' \
            -only-testing:MLXAudioTests/TelemetryLeakDetectionLlamaTTSTests \
            CODE_SIGNING_ALLOWED=NO \
            2>&1 | tee test-leak-llamatts-output.log

      - name: Leak detection - SopranoTTS (local-only)
        env:
          MLXAUDIO_NIGHTLY_RUN: "1"
        run: |
          xcodebuild test-without-building \
            -scheme MLXAudio-Package \
            -destination 'platform=macOS,arch=arm64' \
            -only-testing:MLXAudioTests/TelemetryLeakDetectionSopranoTTSTests \
            CODE_SIGNING_ALLOWED=NO \
            2>&1 | tee test-leak-soprano-output.log

      - name: Leak detection - PocketTTS (local-only)
        env:
          MLXAUDIO_NIGHTLY_RUN: "1"
        run: |
          xcodebuild test-without-building \
            -scheme MLXAudio-Package \
            -destination 'platform=macOS,arch=arm64' \
            -only-testing:MLXAudioTests/TelemetryLeakDetectionPocketTTSTests \
            CODE_SIGNING_ALLOWED=NO \
            2>&1 | tee test-leak-pockettts-output.log

      - name: Leak detection - MarvisTTS (local-only)
        env:
          MLXAUDIO_NIGHTLY_RUN: "1"
        run: |
          xcodebuild test-without-building \
            -scheme MLXAudio-Package \
            -destination 'platform=macOS,arch=arm64' \
            -only-testing:MLXAudioTests/TelemetryLeakDetectionMarvisTTSTests \
            CODE_SIGNING_ALLOWED=NO \
            2>&1 | tee test-leak-marvis-output.log

      - name: Leak detection - Qwen3ASR (local-only)
        env:
          MLXAUDIO_NIGHTLY_RUN: "1"
        run: |
          xcodebuild test-without-building \
            -scheme MLXAudio-Package \
            -destination 'platform=macOS,arch=arm64' \
            -only-testing:MLXAudioTests/TelemetryLeakDetectionQwen3ASRTests \
            CODE_SIGNING_ALLOWED=NO \
            2>&1 | tee test-leak-qwen3asr-output.log

      - name: Leak detection - GLMASR (local-only)
        env:
          MLXAUDIO_NIGHTLY_RUN: "1"
        run: |
          xcodebuild test-without-building \
            -scheme MLXAudio-Package \
            -destination 'platform=macOS,arch=arm64' \
            -only-testing:MLXAudioTests/TelemetryLeakDetectionGLMASRTests \
            CODE_SIGNING_ALLOWED=NO \
            2>&1 | tee test-leak-glmasr-output.log
```

The artifact upload step was also extended to include all 7 new log files (`test-leak-*-output.log`).

YAML validated via: `python3 -c "import yaml; yaml.safe_load(open('.github/workflows/nightly-tests.yaml')); print('YAML OK')"` → `YAML OK`.

---

## How CLAUDE.md Was Updated

### CI-safe block (added TelemetryLeakDetectionPatternTests)

```diff
-    -only-testing:MLXAudioTests/AudioIORoundTripTests \
+    -only-testing:MLXAudioTests/AudioIORoundTripTests \
+    -only-testing:MLXAudioTests/TelemetryLeakDetectionPatternTests \
     CODE_SIGNING_ALLOWED=NO
```

### Local-Only Test Suites table (7 rows appended)

```diff
 | `WeightRoundTripTests` | LlamaTTS, Qwen3ASR | ... |
+| `TelemetryLeakDetectionQwen3TTSTests` | Qwen3-TTS | leak detection pattern (Sortie 9, see `docs/TELEMETRY_REQUIREMENTS.md` §7). Asserts `Qwen3TTS.Model` and `Qwen3TTS.KVCache` live counts return to baseline after model load+drop. Requires `MLXAUDIO_NIGHTLY_RUN=1`. |
+| `TelemetryLeakDetectionLlamaTTSTests` | LlamaTTS (Orpheus) | leak detection pattern (Sortie 9). Asserts `LlamaTTS.Model` and `LlamaTTS.KVCache` live counts return to baseline. Requires `MLXAUDIO_NIGHTLY_RUN=1`. |
+| `TelemetryLeakDetectionSopranoTTSTests` | Soprano TTS | leak detection pattern (Sortie 9). Asserts `SopranoTTS.Model` and `SopranoTTS.KVCache` live counts return to baseline. Requires `MLXAUDIO_NIGHTLY_RUN=1`. |
+| `TelemetryLeakDetectionPocketTTSTests` | PocketTTS | leak detection pattern (Sortie 9). Asserts `PocketTTS.Model`, `PocketTTS.KVCache`, and `PocketTTS.Tokenizer` live counts return to baseline. Requires `MLXAUDIO_NIGHTLY_RUN=1`. |
+| `TelemetryLeakDetectionMarvisTTSTests` | Marvis TTS (CSM / Sesame) | leak detection pattern (Sortie 9). Asserts `MarvisTTS.Model`, `MarvisTTS.KVCache`, `Mimi.Model`, and `Mimi.Tokenizer` live counts return to baseline. Requires `MLXAUDIO_NIGHTLY_RUN=1`. |
+| `TelemetryLeakDetectionQwen3ASRTests` | Qwen3-ASR | leak detection pattern (Sortie 9). Asserts `Qwen3ASR.Model`, `Qwen3ASR.KVCache`, and `Qwen3ASR.Aligner` live counts return to baseline. Requires `MLXAUDIO_NIGHTLY_RUN=1`. |
+| `TelemetryLeakDetectionGLMASRTests` | GLM-ASR | leak detection pattern (Sortie 9). Asserts `GLMASR.Model` and `GLMASR.KVCache` live counts return to baseline. Requires `MLXAUDIO_NIGHTLY_RUN=1`. |
```

---

## Verification Evidence

### Pattern test (CI-safe)

```
$ xcodebuild test -scheme MLXAudio-Package -destination 'platform=macOS' \
    -only-testing:MLXAudioTests/TelemetryLeakDetectionPatternTests \
    CODE_SIGNING_ALLOWED=NO

Suite "TelemetryLeakDetectionPatternTests" started.
Test "in-class init/deinit style: 10 LlamaTTSModel instances leave zero delta" passed after 0.033 seconds.
Test "sentinel/associated-object style: 15 KVCacheSimple instances leave zero delta" passed after 0.001 seconds.
Suite "TelemetryLeakDetectionPatternTests" passed after 0.034 seconds.
Test run with 2 tests in 1 suite passed after 0.034 seconds.

** TEST SUCCEEDED **
```

### Full CI-safe block (all 39 suites, 328 tests)

```
$ xcodebuild test -scheme MLXAudio-Package -destination 'platform=macOS' \
    -only-testing:MLXAudioTests/VocosTests \
    ... [all 38 CI-safe suites from CLAUDE.md] ...
    -only-testing:MLXAudioTests/TelemetryLeakDetectionPatternTests \
    CODE_SIGNING_ALLOWED=NO

Test run with 328 tests in 39 suites passed after 9.080 seconds.

** TEST SUCCEEDED **
```

328 / 328 tests pass (was 326 before S9; +2 from `TelemetryLeakDetectionPatternTests`).

---

## Exit Criteria Verification

### 1. Pattern test exits 0

```sh
$ xcodebuild test -scheme MLXAudio-Package -destination 'platform=macOS' \
    -only-testing:MLXAudioTests/TelemetryLeakDetectionPatternTests \
    CODE_SIGNING_ALLOWED=NO
# → ** TEST SUCCEEDED ** (exit code 0)
```

### 2. grep nightly YAML

```sh
$ grep -q 'TelemetryLeakDetection' .github/workflows/nightly-tests.yaml && echo PASS
PASS
```

### 3. grep CLAUDE.md

```sh
$ grep -q 'TelemetryLeakDetection\|leak detection' CLAUDE.md && echo PASS
PASS
```

### 4. README.md exists and contains TELEMETRY_REQUIREMENTS.md

```sh
$ test -f Tests/MLXAudioTests/README.md && echo EXISTS
EXISTS
$ grep -q 'TELEMETRY_REQUIREMENTS.md' Tests/MLXAudioTests/README.md && echo PASS
PASS
```

### 5. Full CI-safe block exits 0

```sh
$ xcodebuild test -scheme MLXAudio-Package -destination 'platform=macOS' \
    -only-testing:MLXAudioTests/VocosTests \
    [... all 39 suites ...] \
    -only-testing:MLXAudioTests/TelemetryLeakDetectionPatternTests \
    CODE_SIGNING_ALLOWED=NO
# → ** TEST SUCCEEDED ** (exit code 0)
```

All 5 exit criteria PASS.

---

## Exact Verification Commands (Re-Executable)

```sh
# Pattern test only
xcodebuild test -scheme MLXAudio-Package -destination 'platform=macOS' \
  -only-testing:MLXAudioTests/TelemetryLeakDetectionPatternTests \
  CODE_SIGNING_ALLOWED=NO

# Exit criterion checks
grep -q 'TelemetryLeakDetection' .github/workflows/nightly-tests.yaml && echo "EC2 PASS"
grep -q 'TelemetryLeakDetection\|leak detection' CLAUDE.md && echo "EC3 PASS"
test -f Tests/MLXAudioTests/README.md && echo "EC4a PASS"
grep -q 'TELEMETRY_REQUIREMENTS.md' Tests/MLXAudioTests/README.md && echo "EC4b PASS"

# YAML validation
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/nightly-tests.yaml')); print('YAML OK')"

# Full CI-safe block (verbatim from CLAUDE.md)
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

---

## Files Created or Modified

| Path | Change |
|------|--------|
| `Tests/TelemetryLeakDetectionPatternTests.swift` | NEW — CI-safe canonical pattern test; 2 tests in `.serialized` suite; exercises both in-class and sentinel idioms. |
| `Tests/TelemetryLeakDetectionQwen3TTSTests.swift` | NEW — local-only Qwen3TTS leak suite; 1 test gated by `MLXAUDIO_NIGHTLY_RUN=1`. |
| `Tests/TelemetryLeakDetectionLlamaTTSTests.swift` | NEW — local-only LlamaTTS leak suite; 1 test gated by `MLXAUDIO_NIGHTLY_RUN=1`. |
| `Tests/TelemetryLeakDetectionSopranoTTSTests.swift` | NEW — local-only SopranoTTS leak suite; 1 test gated by `MLXAUDIO_NIGHTLY_RUN=1`. |
| `Tests/TelemetryLeakDetectionPocketTTSTests.swift` | NEW — local-only PocketTTS leak suite; 1 test gated by `MLXAUDIO_NIGHTLY_RUN=1`. |
| `Tests/TelemetryLeakDetectionMarvisTTSTests.swift` | NEW — local-only MarvisTTS leak suite; 1 test gated by `MLXAUDIO_NIGHTLY_RUN=1`. |
| `Tests/TelemetryLeakDetectionQwen3ASRTests.swift` | NEW — local-only Qwen3ASR leak suite; 1 test gated by `MLXAUDIO_NIGHTLY_RUN=1`. |
| `Tests/TelemetryLeakDetectionGLMASRTests.swift` | NEW — local-only GLMASR leak suite; 1 test gated by `MLXAUDIO_NIGHTLY_RUN=1`. |
| `Tests/MLXAudioTests/README.md` | NEW — test suite README; documents CI-safe vs local-only categories, leak-detection workflow with code example, counter key reference table. References `docs/TELEMETRY_REQUIREMENTS.md` Section 7 and `nightly-tests.yaml`. |
| `.github/workflows/nightly-tests.yaml` | MODIFIED — 7 new leak-detection steps + 7 new log files in artifact upload list. |
| `CLAUDE.md` | MODIFIED — `TelemetryLeakDetectionPatternTests` added to CI-safe block; 7 rows added to Local-Only Test Suites table. |
| `COMPLETE_S9_LEAK_DETECTION_PATTERN.md` | NEW — this file. |

No production source files were modified. `EXECUTION_PLAN.md` and `SUPERVISOR_STATE.md` are unchanged per sergeant rules.

---

## Out of Scope (per sergeant rules)

- Did NOT begin WU-3 (S10/S11 — operation intervals).
- Did NOT begin WU-5 (S13/S14 — verbose).
- Did NOT modify `EXECUTION_PLAN.md` or `SUPERVISOR_STATE.md`.
- Did NOT commit to `main`; all work stayed on `mission/leak-bloodhound/01`.
- Did NOT use `swift build` / `swift test` — only `xcodebuild` per `CLAUDE.md`.
