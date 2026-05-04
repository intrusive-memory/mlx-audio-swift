# Claude Code Instructions

Read and follow all instructions in [AGENTS.md](AGENTS.md) before starting any task.

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
    CODE_SIGNING_ALLOWED=NO
  ```

## Local-Only Test Suites (require model downloads — NOT in CI-safe list above)

These suites require multi-GB model files from the `mlx-models-v2` cache
(`~/Library/SharedModels`). They are intentionally excluded from the CI-safe
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

To run a single local-only suite:
  ```bash
  xcodebuild test -scheme MLXAudio-Package -destination 'platform=macOS' \
    -only-testing:MLXAudioTests/MarvisTTSGenerateTests \
    CODE_SIGNING_ALLOWED=NO
  ```
