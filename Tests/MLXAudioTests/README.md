# MLXAudioTests

This directory (and its parent `Tests/`) contains the full test suite for `mlx-audio-swift`.

---

## Test categories

### CI-safe suites

These suites use synthetic configs and never download model weights. They run in every PR via the `macOS Tests` job in `.github/workflows/tests.yaml`. See `CLAUDE.md` for the authoritative `xcodebuild test ... -only-testing:` invocation that enumerates them all.

Key suites include:

- Codec unit tests: `VocosTests`, `EncodecTests`, `DACVAETests`, `SNACVQTests`, `MimiLayerTests`, `DACVAEWatermarkerTests`, `ConvWeightedTests`
- STT module setup and helpers: `GLMASRModuleSetupTests`, `GLMASRModelTests`, `Qwen3ASRModuleSetupTests`, `ForceAlignProcessorTests`, `ForcedAlignResultTests`, `Qwen3ASRHelperTests`, `SplitAudioIntoChunksTests`
- TTS module setup and helpers: `Qwen3TTSTests*`, `LlamaTTSModuleSetupTests`, `PocketTTSModuleSetupTests`, `SopranoModuleSetupTests`, `MarvisTTSModuleSetupTests`
- Telemetry infrastructure: `TelemetryConfigTests`, `TelemetryCounterStoreTests`, `TelemetryLoggingTests`, `TelemetryLifecycleHookTests`, `TelemetryModelLifecycleSmokeTests`, `TelemetryCodecLifecycleSmokeTests`, `TelemetryTokenizerEngineLifecycleSmokeTests`
- **Canonical leak-detection pattern**: `TelemetryLeakDetectionPatternTests` (CI-safe — synthetic configs, no downloads)
- Audio utilities: `AudioUtilsTests`, `AudioIORoundTripTests`, `MLXAudioCoreDSPTests`, `ModelUtilsTests`, `UnigramTokenizerRoundTripTests`, `ParityFixtureLoaderSmokeTests`

### Local-only suites

These suites require multi-GB model files from the `mlx-models-v2` cache and are intentionally excluded from the CI-safe block. They run in the nightly workflow (`.github/workflows/nightly-tests.yaml`) with `MLXAUDIO_NIGHTLY_RUN=1` set in the environment. See `CLAUDE.md` for the full table.

Key local-only suites:

- Codec live tests: `SNACTests`, `MimiTests`
- TTS generation: `Qwen3TTSTests`, `LlamaTTSTests`, `SopranoTTSTests`, `PocketTTSTests`, `MarvisTTSGenerateTests`, `Qwen3TTSVoiceDesignTests`
- STT: `Qwen3ASRTests`, `GLMASRTests`
- Correctness and weight integrity: `DeterministicGenerationTests`, `KVCacheCorrectnessTests`, `WeightRoundTripTests`
- **Per-family leak detection**: `TelemetryLeakDetectionQwen3TTSTests`, `TelemetryLeakDetectionLlamaTTSTests`, `TelemetryLeakDetectionSopranoTTSTests`, `TelemetryLeakDetectionPocketTTSTests`, `TelemetryLeakDetectionMarvisTTSTests`, `TelemetryLeakDetectionQwen3ASRTests`, `TelemetryLeakDetectionGLMASRTests`

---

## Leak detection workflow

The telemetry subsystem (introduced in OPERATION LEAK BLOODHOUND, Sorties 1–9) instruments every long-lived object in the library — models, KV caches, tokenizers — so test code can assert that object counts return to zero after dropping references.

The canonical pattern is documented in `docs/TELEMETRY_REQUIREMENTS.md` Section 7. In Swift Testing syntax:

```swift
@Test("Qwen3TTSModel does not leak")
func testQwen3TTSDoesNotLeak() async throws {
    // Step 1: Reset counters to a known-zero state.
    await Telemetry.resetCounters()

    // Step 2: Capture the baseline snapshot BEFORE the allocation loop.
    // Using delta (after - before) instead of absolute value handles any
    // pre-existing live instances from framework initialization.
    let before = await Telemetry.snapshot()

    // Step 3: Loop — construct and drop inside autoreleasepool so ARC
    // releases deterministically at the end of each iteration.
    for _ in 0..<10 {
        autoreleasepool {
            let model = Qwen3TTSModel(config: someConfig)
            _ = model // prevent compiler from eliding allocation
            // ARC releases model at end of autoreleasepool block →
            // deinit fires → Telemetry.trackLifecycleEnd schedules decrement
        }
    }

    // Step 4: Drain in-flight background Tasks before asserting.
    var after = await Telemetry.snapshot()
    for _ in 0..<200 {
        if (after.liveCounts["Qwen3TTS.Model"] ?? 0) == before.liveCounts["Qwen3TTS.Model", default: 0] { break }
        try? await Task.sleep(nanoseconds: 1_000_000) // 1 ms
        after = await Telemetry.snapshot()
    }

    // Step 5: Assert the delta is zero — no instances leaked.
    #expect(
        after.liveCounts["Qwen3TTS.Model", default: 0] == before.liveCounts["Qwen3TTS.Model", default: 0],
        "Qwen3TTS.Model leaked across 10 generate iterations"
    )
}
```

### Two instrumentation idioms

The codebase uses two distinct instrumentation styles (both exercised by `TelemetryLeakDetectionPatternTests`):

**Idiom 1 — In-class init/deinit (S6/S7/S8 style)**: Used by model classes (`Qwen3TTSModel`, `LlamaTTSModel`, etc.) and tokenizers. The class calls `Telemetry.trackLifecycle(self, className:)` directly in `init` and `Telemetry.trackLifecycleEnd(className:)` in `deinit`.

**Idiom 2 — Sentinel / associated-object (S5 style)**: Used by KV cache classes (`KVCacheSimple` from MLXLMCommon) that live in an external package and cannot be subclassed. The `attachKVCacheLifecycle(family:to:)` free function binds a `KVCacheLifecycleSentinel` to the cache via `objc_setAssociatedObject`. When the cache is released, ARC releases the sentinel, which fires the matching decrement in its `deinit`.

### Telemetry levels

The telemetry API has five levels: `off`, `lifecycle`, `operations`, `memory`, `verbose`. The default active level is `.lifecycle` (leak detection). For richer profiling, override via environment variable:

```sh
# Per-op memory deltas (useful for pinpointing which operations allocate)
MLXAUDIO_TELEMETRY=memory xcodebuild test ...

# Per-token signposts in generate loops (Instruments traces)
MLXAUDIO_TELEMETRY=verbose xcodebuild test ...
```

See `docs/TELEMETRY_REQUIREMENTS.md` for the full levels table and build-flag documentation.

### Running leak detection locally

CI-safe pattern test (no model downloads):

```sh
xcodebuild test -scheme MLXAudio-Package -destination 'platform=macOS' \
  -only-testing:MLXAudioTests/TelemetryLeakDetectionPatternTests \
  CODE_SIGNING_ALLOWED=NO
```

Per-family leak tests (requires model cache populated):

```sh
MLXAUDIO_NIGHTLY_RUN=1 xcodebuild test -scheme MLXAudio-Package -destination 'platform=macOS' \
  -only-testing:MLXAudioTests/TelemetryLeakDetectionQwen3TTSTests \
  CODE_SIGNING_ALLOWED=NO
```

All per-family leak suites run in the nightly workflow via `.github/workflows/nightly-tests.yaml` with `MLXAUDIO_NIGHTLY_RUN=1` in the environment.

### Counter key reference

| Counter key | Instrumented class | Sortie |
|-------------|-------------------|--------|
| `Qwen3TTS.Model` | `Qwen3TTSModel` | S6 |
| `LlamaTTS.Model` | `LlamaTTSModel` | S6 |
| `SopranoTTS.Model` | `SopranoModel` | S6 |
| `PocketTTS.Model` | `PocketTTSModel` | S6 |
| `MarvisTTS.Model` | `MarvisTTSModel` | S6 |
| `Qwen3ASR.Model` | `Qwen3ASRModel` | S6 |
| `GLMASR.Model` | `GLMASRModel` | S6 |
| `SNAC.Model` | `SNACDecoder` | S7 |
| `Mimi.Model` | `Mimi` | S7 |
| `Encodec.Model` | `Encodec` | S7 |
| `DAC.Model` | `DACVAE` | S7 |
| `Vocos.Model` | `Vocos` | S7 |
| `Qwen3TTS.Tokenizer` | `Qwen3TTSSpeechTokenizer` | S8 |
| `PocketTTS.Tokenizer` | `SentencePieceTokenizer` | S8 |
| `Core.Tokenizer` | `UnigramTokenizer` | S8 |
| `Mimi.Tokenizer` | `MimiTokenizer` | S8 |
| `Qwen3ASR.Aligner` | `Qwen3ForcedAlignerModel` | S8 |
| `*.KVCache` | Sentinel on `KVCacheSimple` via `attachKVCacheLifecycle` | S5 |
