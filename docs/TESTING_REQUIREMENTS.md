# Testing Requirements

Audit of current test coverage for `mlx-audio-swift`, with prioritized gaps to close. Findings and citations are point-in-time as of 2026-04-30 against `development` branch.

## Background

- 5 test files / 40 `@Suite` structs / 7,835 lines of test code.
- ~75 source files across MLXAudioCore, MLXAudioCodecs, MLXAudioTTS, MLXAudioSTT, MLXAudioSTS, MLXAudioUI.
- CI runs ~24 of 40 suites (CI-safe split in `CLAUDE.md`); the remaining ~16 require model downloads and run only on developer machines.
- All references below are file paths relative to repo root and line numbers as of audit date.

---

## Critical — Silent-Regression Hotspots

These are gaps where a numerical or behavioral bug would ship undetected. Address before any further model additions.

### C1. No numeric parity tests against the Python reference

**Problem.** Every codec layer test in `Tests/MLXAudioCodecsTests.swift` asserts only output *shape* — not output *values*. Snake1d, Conv1d, ResidualUnit, ConvNeXt, ISTFTHead, RVQ all run with random-init weights through random input and check `output.shape[i] == N` (e.g., `MLXAudioCodecsTests.swift:384-418`, `:537-553`). This proves the layer doesn't crash; it does not prove it computes the right thing.

**Risk.** Textbook silent-regression scenario for a port of math kernels.

**Required tests.**
- Check in PyTorch-generated reference tensors (NPY or safetensors) for one canonical input per layer family.
- Assert `MLX.allclose(swift_out, ref, atol: 1e-4, rtol: 1e-4)`.
- Cover at minimum: Vocos ISTFTHead, Encodec quantizer, DACVAE encoder/decoder block, SNAC VQ, Mimi RVQ.
- Fixtures live under `Tests/media/parity/<layer>/{input,weights,expected}.safetensors`.

### C2. Marvis TTS has zero test coverage

**Problem.** `Sources/MLXAudioTTS/Models/Marvis/{CSMModel.swift, CSMLlamaModel.swift, MarvisTTSModel.swift}` totals 1,667 LOC. The model is registered as a P2 priority in `AudioModelManager.swift:54` and routed via `csm`/`sesame` keys in `TTSModelUtils.swift:52-53`. There is no `MarvisTTSTests` suite; no instantiation, config-decode, sanitize, or generation test exists.

**Required tests.**
- Module-setup: config decode from JSON, `sanitize` weight-key transformation, `makeCache` shape.
- Optional local-only `testMarvisGenerate` mirroring `LlamaTTSTests` (`MLXAudioTTSTests.swift:1875`).

### C3. DACVAE Watermarker is entirely untested

**Problem.** `Sources/MLXAudioCodecs/DACVAE/DACVAEWatermark.swift` (247 LOC) defines `DACVAEWatermarkEncoderBlock`, `DACVAEWatermarkDecoderBlock`, and `DACVAEWatermarker`. `DACVAETests` (`Tests/MLXAudioCodecsTests.swift:492-648`) covers Snake1d, WNConv1d, ResidualUnit, EncoderBlock, Encoder, QuantizerProj, Model, HopLength — but never instantiates the watermarker.

**Risk.** If watermarking exists for content-provenance, a silent break is a compliance issue.

**Required tests.**
- Instantiation + shape tests for both blocks.
- Round-trip test: embed watermark → extract → assert payload equality.

### C4. Mimi codec has no layer-level unit tests

**Problem.** `Sources/MLXAudioCodecs/Mimi/{Transformer.swift (369L), Conv.swift (375L), Quantization.swift (211L), Seanet.swift (370L)}` — 1,325 LOC. The only Mimi test (`Tests/MLXAudioCodecsTests.swift:85-122`) is a model-download encode/decode cycle that asserts `reconstructed.shape.last! > 0`. Compare to Encodec, which has 7 layer-level shape tests.

**Required tests.**
- Mirror the Encodec layer test pattern: Conv1d (causal/streaming), ResnetBlock, Transformer block, RVQ.
- Numeric-parity tests once C1 fixtures exist.

### C5. MLXAudioCore utilities are entirely untested

**Problem.** 11 files / ~2,415 LOC with no dedicated test suite:
- `DSP.swift` (403L) — FFT, STFT/iSTFT, mel, resampling, hann window
- `AudioUtils.swift` (149L) — WAV load/save
- `ConvWeighted.swift` (123L)
- `MLX+Extensions.swift` (184L)
- `ModelUtils.swift` (99L)
- `WiredMemoryManager.swift` (217L)
- `AudioPlayerManager.swift` (256L)
- `AudioSessionManager.swift` (87L)
- `AudioModelManager.swift` (884L)
- `GenerationTypes.swift`, `MLXAudio.swift`

The mel-spectrogram is only verified by *parameter values* (`Qwen3TTSSpeakerEmbeddingTests.melSpectrogramParametersMatchPython` at `MLXAudioTTSTests.swift:3108`), not numeric output.

**Required tests.**
- DSP: `melSpectrogram(sineWave) ≈ scipyReference` with golden NPY fixtures.
- AudioUtils: round-trip WAV write → read → equality on int16/float32 PCM.
- ConvWeighted: weight-norm reparameterization equivalence to plain Conv with composed weights.
- ModelUtils: weight-key transformation tests.

---

## Important — Real Coverage Gaps

### I1. CI is a coverage mirage

**Problem.** ~24 of 40 suites run in CI; every suite that touches real model weights or generation is local-only. PRs to Marvis, Llama, Soprano, PocketTTS, Qwen3TTSBase/CustomVoice/Cloning, SpeakerEncoderIntegration, and all STT models can land green without any model code executing. Local-only tests run on developer demand → bit-rot is near-certain.

**Required action.**
- Add a nightly GitHub Actions job (macos-26) that runs the local-only suites against the `mlx-models-v2` SwiftAcervo cache.
- Fail the nightly if any local-only suite is removed without replacement.

### I2. Integration tests pass without network

**Resolved 2026-05-04.** The `AudioModelManagerIntegrationTests` and `MLXAudioComponentDescriptorTests` files were deleted. They tested SNAC/Mimi compliance against components that aren't deployed to CDN — silent false-greens by construction. Removed rather than gated; if/when those components ship, write fresh tests against the real manifest.

### I3. Sampling / generation loop has no deterministic-seed tests

**Problem.** `temperature: 0.6, topP: 0.8` is set on `generate()` calls in many places (e.g., `MLXAudioTTSTests.swift:1646, 1677, 1719, 1752, 1785, 1822`). No test fixes a seed and asserts a deterministic token sequence.

**Required tests.**
- `MLXRandom.seed(42)` + fixed prompt → assert exact token-id sequence equality across runs.
- One per top-level model (Qwen3TTS, LlamaTTS, PocketTTS, Soprano).

### I4. KV cache correctness is uncovered

**Problem.** Only `qwen3ASRModelMakeCache` (`MLXAudioSTTTests.swift:1044`) tests cache *creation*. The canonical correctness check — prefill+decode produces the same logits as a single-shot forward — does not exist.

**Required test.**
- For one TTS and one STT model: `logits_singleshot(seq) ≈ logits_incremental(seq)` with `atol: 1e-4`.

### I5. No weight-loading round-trip

**Problem.** `sanitize` tests are one-way: feed in weights, check key/shape transformation (e.g., `qwen3ASRSanitizeStripsThinkerPrefix` at `MLXAudioSTTTests.swift:1059`, `testSanitizeTransposesConv1dWeights` at `MLXAudioTTSTests.swift:2670`). No test does save → reload → equality on a Swift-loaded model.

**Required test.**
- Load weights → save to scratch → reload → assert all parameter tensors equal.

### I6. Tokenizer round-trips against reference vectors are missing

**Problem.** `Sources/MLXAudioTTS/Models/PocketTTS/UnigramTokenizer.swift` has byte-fallback encode (`:207`) and decode (`:246`). No round-trip test against a Python-tokenizer-generated fixture.

**Required test.**
- Reference IDs from the Python tokenizer for ~10 inputs (incl. CJK, emoji, byte-fallback edge cases) → `tokenizer.encode(text) == referenceIds && tokenizer.decode(referenceIds) == text`.

### I7. Thin coverage on PocketTTS / LlamaTTS / Soprano / GLMASR LM

**Problem.**
- **PocketTTS**: only `testPocketTTSGenerate` (`MLXAudioTTSTests.swift:2137-2167`) — one end-to-end `audio.shape[0] > 0` assertion across ~thousands of LOC (UnigramTokenizer, FlowLM, Conditioners, MimiAdapter, MLP, Model, TextUtils, Transformer, Config).
- **LlamaTTS / Qwen3TTS base**: `LlamaTTSTests` (`MLXAudioTTSTests.swift:1875-1976`) and `Qwen3TTSTests` (`:1770-1873`) require model downloads. No config-decode, no sanitize, no makeCache tests — compare to `Qwen3TTSConfigTests` and `Qwen3TTSRoutingTests` for the *separate* Qwen3TTS variant.
- **Soprano**: only `testTextCleaning` (`MLXAudioTTSTests.swift:2271`) is a unit test; `SopranoDecoder`, config decode, weight sanitize uncovered.
- **GLMASR**: layer tests at `MLXAudioSTTTests.swift:104-247` cover WhisperAttention/Encoder/AdaptingMLP/AudioEncoder, but `GLMASRLanguageModel` (`GLMASR.swift:212`) and `GLMASRModel` (`:292`) are constructed only by the model-download `glmASRTranscribe` (`MLXAudioSTTTests.swift:1621`).

**Required tests.**
- For each: config-decode, sanitize one-way, makeCache. All CI-safe.

### I8. CI never validates audio I/O

**Problem.** `Tests/media/intention.wav` (73KB) is used only in SNAC/Mimi tests (model-download local-only). `conversational_a.wav` (636KB) is used only in 5 GLM/Qwen3 ASR tests (also local-only). CI never exercises `loadAudioArray` / `saveAudioArray`.

**Required test.**
- CI-safe round-trip: `loadAudioArray(intention.wav) → saveAudioArray(scratch.wav) → loadAudioArray(scratch.wav)` → assert equality.

---

## Nice-to-have

### N1. Some tests are tautologies

`testEncodecConfig` and similar (`Tests/MLXAudioCodecsTests.swift:354-368`) instantiate `EncodecConfig()` and assert each default. Since defaults live in the same module, this only catches accidental default changes. Low signal — fine to keep, but don't pad coverage stats with similar tests.

### N2. Trim `print(...)` debug noise from codec tests

Most codec tests `print(shape)` on every run (e.g., `Tests/MLXAudioCodecsTests.swift:386, 400, 418, 432`). Suggests ad-hoc debugging promoted to tests.

### N3. Watch for tests that mock too aggressively

If any future tests mock model output instead of running the model, flag and refuse — we have prior incidents in the wider codebase where mocked tests passed but real-weight runs diverged.

---

## Suggested Order of Attack

1. **C1 + C5 first.** Build the numeric-parity fixture pipeline (Python script in `Tests/media/parity/_generate.py` that emits NPY/safetensors for one canonical input per layer). Apply it first to MLXAudioCore DSP and one codec layer family. Once the harness exists, additional layers are cheap.
2. **C2 (Marvis module-setup tests).** Free CI win, closes a 1,667 LOC blind spot.
3. **I1 (nightly local-only CI).** Required infrastructure to keep everything else honest.
4. **I2 (fix integration tests that pass without network).** One-line fix, currently misleading.
5. **C3, C4 (Watermark + Mimi layer tests).** Mechanical once C1 fixtures exist.
6. **I3, I4, I5 (deterministic generation, KV-cache correctness, weight round-trip).** One pass per model family.
7. **I6, I7, I8 (tokenizer round-trips, thin model coverage, audio I/O).** Cleanup pass.

## Out of Scope (for now)

- E2E "audio in → audio out → spectrum looks plausible" subjective tests.
- Performance regression benchmarks.
- iOS-specific test targets (current scheme is `platform=macOS`).
