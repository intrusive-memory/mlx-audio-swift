# Claude Code Instructions

Read and follow all instructions in [AGENTS.md](AGENTS.md) before starting any task. App Group configuration (required for SwiftAcervo model storage) is documented in [AGENTS.md § App Group configuration](AGENTS.md#app-group-configuration-required).

## References

- **Telemetry**: see [docs/TELEMETRY_USAGE.md](docs/TELEMETRY_USAGE.md) for level/env-var/Instruments examples.
- **Telemetry public API** (event vocabulary, reporter protocol, injection patterns, invariants): [docs/TELEMETRY.md](docs/TELEMETRY.md)
- Full telemetry specification: [docs/TELEMETRY_REQUIREMENTS.md](docs/TELEMETRY_REQUIREMENTS.md)

## Additional Rules for Claude

- **Never use `swift build` or `swift test`**. Always use `xcodebuild` with `-scheme MLXAudio-Package -destination 'platform=macOS'`.
- **Never expose secrets**. Do not echo environment variables, API keys, or `.env` file contents. Use existence checks only (`test -n "$VAR"`).
- **CI runner must be `macos-26`** or later. Never use `macos-latest`, `macos-15`, etc.
- **Commit to `development`**, never directly to `main`. PRs go `development` → `main`.
- When modifying CI workflows, update branch protection rules in concert using `gh api`.
- Run unit tests (no model downloads) after code changes to verify nothing is broken:
  ```bash
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
    -only-testing:MLXAudioTests/MLXAudioTelemetryEventTests \
    -only-testing:MLXAudioTests/AudioModelManagerTelemetryTests \
    -only-testing:MLXAudioTests/Qwen3TTSTelemetryTests \
    -only-testing:MLXAudioTests/GLMASRTelemetryTests \
    -only-testing:MLXAudioTests/MemoryTelemetryTests \
    -only-testing:MLXAudioTests/VocosTelemetryTests \
    -only-testing:MLXAudioTests/AudioUtilsTelemetryTests \
    -only-testing:MLXAudioTests/SopranoTTSTelemetryTests \
    -only-testing:MLXAudioTests/LlamaTTSTelemetryTests \
    -only-testing:MLXAudioTests/PocketTTSTelemetryTests \
    -only-testing:MLXAudioTests/MarvisTTSTelemetryTests \
    -only-testing:MLXAudioTests/Qwen3ASRTelemetryTests \
    -only-testing:MLXAudioTests/EncodecTelemetryTests \
    -only-testing:MLXAudioTests/SNACTelemetryTests \
    -only-testing:MLXAudioTests/MimiTelemetryTests \
    -only-testing:MLXAudioTests/DACVAETelemetryTests \
    -only-testing:MLXAudioTests/AudioBufferCacheTelemetryTests \
    -only-testing:MLXAudioTests/EndToEndTelemetryTests \
    -only-testing:MLXAudioTests/HotLoopGuardTests \
    CODE_SIGNING_ALLOWED=NO
  ```

## Local-Only Test Suites (require model downloads — NOT in CI-safe list above)

These suites require multi-GB model files from the `mlx-models-v2` cache
(`~/Library/Group Containers/group.intrusive-memory.models/SharedModels`). They are intentionally excluded from the CI-safe
`make test` / `xcodebuild test` block above. Run them locally or in the
nightly workflow (`.github/workflows/nightly-tests.yaml`, Sortie 9).

| Suite | Model family | Notes |
|-------|-------------|-------|
| `SNACTests` | SNAC codec | Downloads SNAC model weights |
| `MimiTests` | Mimi codec | Downloads Mimi model weights |
| `Qwen3TTSTests` | Qwen3-TTS | Downloads Qwen3-TTS model |
| `LlamaTTSTests` | LlamaTTS (Orpheus) | Downloads orpheus-3b model |
| `SopranoTTSTests` | Soprano TTS | Downloads Soprano model |
| `PocketTTSTests` | PocketTTS | Downloads PocketTTS model |
| `Qwen3TTSVoiceDesignTests` | Qwen3-TTS voice design | Downloads Qwen3-TTS model |
| `Qwen3ASRTests` | Qwen3-ASR | Downloads Qwen3-ASR model |
| `GLMASRTests` | GLM-ASR | Downloads GLM-ASR model |
| `MarvisTTSGenerateTests` | Marvis TTS (CSM / Sesame) | Downloads Marvis-AI/marvis-tts-250m-v0.2-MLX-8bit + Mimi codec |
| `DeterministicGenerationTests` | Qwen3TTS, LlamaTTS, SopranoTTS, PocketTTS | Downloads all four models; asserts reproducible token-id sequences (Sortie 21). Fixtures in `Tests/media/deterministic/` are placeholders until regenerated locally. PocketTTS is PARTIAL (flow-matching model has no discrete token IDs; uses audio sample-count proxy). |
| `KVCacheCorrectnessTests` | LlamaTTS (full), Qwen3ASR (PARTIAL) | KV cache correctness: asserts single-shot and prefill+decode logits match within `atol: 1e-4` (Sortie 22). LlamaTTS test is FULL (public API sufficient). Qwen3ASR test is PARTIAL — `mergeAudioFeatures` is private; stub skips gracefully with documented API gap. Nightly run requires `MLXAUDIO_NIGHTLY_RUN=1` env var (set by nightly workflow). CI-safe promotion deferred — synthetic small-config benchmark not yet validated. |
| `WeightRoundTripTests` | LlamaTTS, Qwen3ASR | Weight save→reload round-trip: extracts `model.parameters().flattened()`, saves to `FileManager.temporaryDirectory/<uuid>.safetensors` via `MLX.save(arrays:url:)`, reloads via `MLX.loadArrays(url:)`, asserts `MLX.allClose(atol: 0)` (byte-exact) for all keys (Sortie 23). Both TTS and STT tests are FULL — no API gaps for weight serialization. Nightly run requires `MLXAUDIO_NIGHTLY_RUN=1` env var (set by nightly workflow). CI-safe promotion deferred — requires public `init(config:)` without Acervo download to benchmark synthetic-config path in <10 min. |
| `TelemetryLeakDetectionQwen3TTSTests` | Qwen3-TTS | leak detection pattern (Sortie 9, see `docs/TELEMETRY_REQUIREMENTS.md` §7). Asserts `Qwen3TTS.Model` and `Qwen3TTS.KVCache` live counts return to baseline after model load+drop. Requires `MLXAUDIO_NIGHTLY_RUN=1`. |
| `TelemetryLeakDetectionLlamaTTSTests` | LlamaTTS (Orpheus) | leak detection pattern (Sortie 9). Asserts `LlamaTTS.Model` and `LlamaTTS.KVCache` live counts return to baseline. Requires `MLXAUDIO_NIGHTLY_RUN=1`. |
| `TelemetryLeakDetectionSopranoTTSTests` | Soprano TTS | leak detection pattern (Sortie 9). Asserts `SopranoTTS.Model` and `SopranoTTS.KVCache` live counts return to baseline. Requires `MLXAUDIO_NIGHTLY_RUN=1`. |
| `TelemetryLeakDetectionPocketTTSTests` | PocketTTS | leak detection pattern (Sortie 9). Asserts `PocketTTS.Model`, `PocketTTS.KVCache`, and `PocketTTS.Tokenizer` live counts return to baseline. Requires `MLXAUDIO_NIGHTLY_RUN=1`. |
| `TelemetryLeakDetectionMarvisTTSTests` | Marvis TTS (CSM / Sesame) | leak detection pattern (Sortie 9). Asserts `MarvisTTS.Model`, `MarvisTTS.KVCache`, `Mimi.Model`, and `Mimi.Tokenizer` live counts return to baseline. Requires `MLXAUDIO_NIGHTLY_RUN=1`. |
| `TelemetryLeakDetectionQwen3ASRTests` | Qwen3-ASR | leak detection pattern (Sortie 9). Asserts `Qwen3ASR.Model`, `Qwen3ASR.KVCache`, and `Qwen3ASR.Aligner` live counts return to baseline. Requires `MLXAUDIO_NIGHTLY_RUN=1`. |
| `TelemetryLeakDetectionGLMASRTests` | GLM-ASR | leak detection pattern (Sortie 9). Asserts `GLMASR.Model` and `GLMASR.KVCache` live counts return to baseline. Requires `MLXAUDIO_NIGHTLY_RUN=1`. |

To run a single local-only suite:
  ```bash
  xcodebuild test -scheme MLXAudio-Package -destination 'platform=macOS' \
    -only-testing:MLXAudioTests/MarvisTTSGenerateTests \
    CODE_SIGNING_ALLOWED=NO
  ```
