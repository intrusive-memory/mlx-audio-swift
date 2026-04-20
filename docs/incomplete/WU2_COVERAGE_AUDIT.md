# WU2.2 Coverage Audit: Legacy Call Sites vs. Registered Descriptors

**Execution Date**: 2026-04-20  
**Audit Scope**: All legacy model-loading call sites in `Sources/` (excluding internal helpers in `ModelResolver.swift` and `ModelUtils.swift`)  
**Registered Descriptors Source**: `AudioModelManager.swift` § `audioComponentDescriptors` array + `AudioModelRepo` enum

---

## Rollup Summary

| Metric | Count |
|--------|-------|
| **Total call sites found** | 13 |
| **Registered (✅ can proceed)** | 13 |
| **Gaps (❌ blocks execution)** | 0 |
| **Status** | **READY FOR WU3+** |

---

## Call-Site Audit Table

Each row documents one legacy API call site (outside the internal ModelResolver/ModelUtils helpers) that will be migrated to `AudioModelManager.loadWithAcervoStrict(componentId:load:)`.

| File | Line | Current API | Target componentId | Registration Status | Layer 2 Migration Sortie |
|------|------|-------------|-------------------|-------------------|---------------------------|
| `Sources/MLXAudioCodecs/SNAC/SNACDecoder.swift` | 196 | `ModelResolver.resolve(modelId:)` | `snac-24khz` | ✅ registered | WU3.1 Migrate SNAC |
| `Sources/MLXAudioCodecs/Mimi/Mimi.swift` | 348 | `ModelResolver.resolveFile(modelId:fileName:)` | `mimi-pytorch-bf16` | ✅ registered | WU3.2 Migrate Mimi |
| `Sources/MLXAudioCodecs/DACVAE/DACVAE.swift` | 391 | `ModelResolver.resolve(modelId:)` | `dac-vae` | ✅ registered | WU3.3 Migrate DACVAE |
| `Sources/MLXAudioCodecs/Encodec/Encodec.swift` | 402 | `ModelResolver.resolve(modelId:)` | `encodec-24khz` (or `-48khz`) | ✅ registered | WU3.4 Migrate Encodec |
| `Sources/MLXAudioTTS/Models/Llama/LlamaTTS.swift` | 914 | `ModelResolver.resolve(modelId:)` | `orpheus-tts-3b` | ✅ registered | WU4.1 Migrate Llama TTS |
| `Sources/MLXAudioTTS/Models/Soprano/Soprano.swift` | 878 | `ModelResolver.resolve(modelId:)` | `soprano-tts-80m` | ✅ registered | WU4.2 Migrate Soprano TTS |
| `Sources/MLXAudioTTS/Models/Qwen3/Qwen3.swift` | 864 | `ModelResolver.resolve(modelId:)` | variant-dispatched (see WU4.3) | ✅ registered | WU4.3 Migrate Qwen3 TTS |
| `Sources/MLXAudioTTS/Models/PocketTTS/PocketTTSModel.swift` | 343 | `ModelResolver.resolve(modelId:)` | `pocket-tts` | ✅ registered | WU4.4 Migrate PocketTTS |
| `Sources/MLXAudioTTS/Models/Marvis/MarvisTTSModel.swift` | 168 | `ModelUtils.resolveOrDownloadModel(repoID:requiredExtension:hfToken:)` | `marvis-tts-250m-8bit` | ✅ registered | WU4.5 Migrate Marvis TTS (call-site) |
| `Sources/MLXAudioSTT/Models/GLMASR/GLMASR.swift` | 563 | `ModelResolver.resolve(modelId:)` | `glm-asr` | ✅ registered | WU5.1 Migrate GLM ASR |
| `Sources/MLXAudioSTT/Models/Qwen3ASR/Qwen3ASR.swift` | 1546 | `ModelUtils.resolveOrDownloadModel(repoID:requiredExtension:hfToken:)` | `qwen3-asr` | ✅ registered | WU5.2 Migrate Qwen3 ASR |
| `Sources/MLXAudioSTT/Models/Qwen3ASR/Qwen3ForcedAligner.swift` | 540 | `ModelUtils.resolveOrDownloadModel(repoID:requiredExtension:hfToken:)` | `qwen3-asr` | ✅ registered | WU5.2 Migrate Qwen3 ASR |
| `Sources/MLXAudioTTS/Models/Qwen3TTS/Qwen3TTS.swift` | 1593 | `ModelUtils.resolveOrDownloadModel(repoID:requiredExtension:...)` | variant-dispatched (see WU4.3 note) | ✅ registered | WU4.3 Migrate Qwen3 TTS |

---

## Detailed Coverage Notes

### Codec Models (WU3)

- **SNAC 24 kHz** (`snac-24khz`): Descriptor exists; `SNACDecoder.fromPretrained()` call at line 196 via legacy `ModelResolver`. Swaps to `loadWithAcervoStrict(componentId: "snac-24khz", ...)` in WU3.1.
  
- **Mimi PyTorch BF16** (`mimi-pytorch-bf16`): Descriptor exists; `Mimi.fromPretrained()` has a file-level call at line 348 via `ModelResolver.resolveFile(modelId:fileName:)`. This is a single-file load (tokenizer checkpoint). Swaps to `loadWithAcervoStrict` in WU3.2.

- **DAC VAE Watermarked** (`dac-vae`): Descriptor exists; `DACVAE.fromPretrained()` call at line 391. Swaps in WU3.3.

- **Encodec 24 kHz / 48 kHz** (`encodec-24khz` / `encodec-48khz`): Both descriptors exist (separate registrations in `AudioModelManager`). `Encodec.fromPretrained()` at line 402 accepts a variant string but currently issues one `ModelResolver.resolve()` call. Will dispatch on variant in WU3.4.

### TTS Models (WU4)

- **LlamaTTS (Orpheus)** (`orpheus-tts-3b`): Descriptor exists; call at line 914 in `LlamaTTS.swift`. Swaps in WU4.1.

- **Soprano TTS** (`soprano-tts-80m`): Descriptor exists; call at line 878 in `Soprano.swift`. Swaps in WU4.2.

- **Qwen3 TTS variants** (`qwen3-tts-12hz-1.7b-base-bf16`, `qwen3-tts-12hz-1.7b-voice-design-bf16`, `qwen3-tts-12hz-1.7b-custom-voice-bf16`): All three descriptors registered. Call site at line 864 in `Qwen3.swift` + line 1593 in `Qwen3TTS.swift` (uses `ModelUtils.resolveOrDownloadModel`). WU4.3 responsible for variant dispatch logic — each variant gets its own componentId, with runtime dispatch based on repo string or model config. See EXECUTION_PLAN.md § WU4.3 for dispatch details.

- **PocketTTS** (`pocket-tts`): Descriptor exists; call at line 343 in `PocketTTSModel.swift`. Swaps in WU4.4.

- **MarvisTTS** (`marvis-tts-250m-8bit`): Descriptor exists; call at line 168 via `ModelUtils.resolveOrDownloadModel(repoID:requiredExtension:hfToken:)`. This sortie (WU4.5) updates the call site to `loadWithAcervoStrict` while leaving `HubApi`, `ModelConfiguration(id:)`, and tokenizer calls untouched (those are WU6.2). Model will be available via Acervo; the partial migration unblocks Layer 2.

### STT Models (WU5)

- **GLM ASR Nano** (`glm-asr`): Descriptor exists; call at line 563 in `GLMASR.swift`. Swaps in WU5.1.

- **Qwen3 ASR 0.6B** (`qwen3-asr`): Descriptor exists; two call sites both via `ModelUtils.resolveOrDownloadModel()`:
  - Line 1546 in `Qwen3ASR.swift`
  - Line 540 in `Qwen3ForcedAligner.swift`
  Both swaps happen in WU5.2.

---

## Internal Helpers (Not Flagged as Coverage Gaps)

The following files are internal/legacy and will be deleted wholesale in WU6.4. They are **NOT** subject to migration and should **NOT** be counted as call sites:

- **`Sources/MLXAudioCore/ModelResolver.swift`**: Legacy API. Contains one `Acervo.download(...)` call at line 125 (internal implementation detail). Deleted in WU6.4.
  
- **`Sources/MLXAudioCore/ModelUtils.swift`**: Two wrappers (`resolveOrDownloadModel` overloads at lines 89 and 109) that delegate to `ModelResolver.resolve()`. Both are replaced by direct `AudioModelManager.loadWithAcervoStrict(...)` calls at the consumer sites (hence listed above as call sites). Deleted in WU6.4.

---

## Variant Dispatch Notes (Qwen3 TTS)

The Qwen3 TTS case (WU4.3) requires runtime variant dispatch:

- **Three separate descriptors registered**: `qwen3-tts-12hz-1.7b-base-bf16`, `qwen3-tts-12hz-1.7b-voice-design-bf16`, `qwen3-tts-12hz-1.7b-custom-voice-bf16`.
- **Call sites** (`Qwen3.swift:864` and `Qwen3TTS.swift:1593`) receive a repo string (e.g., `"mlx-community/Qwen3-TTS-12Hz-1.7B-Base-bf16"`).
- **Dispatch logic** (WU4.3): Extract the variant name from the repo string, map it to the corresponding componentId, then call `loadWithAcervoStrict(componentId: mapped, ...)`.
- **No coverage gap**: All three variants have registered descriptors. Dispatch is a pure routing problem, solved in WU4.3.

---

## Acervo.download() Internal Call

One additional call to `Acervo.download(modelId:files:progress:)` exists at `Sources/MLXAudioCore/ModelResolver.swift:125` (internal fallback within `ModelResolver.resolve()`). This is **not a call site** subject to migration — it's part of the legacy code that will be deleted in WU6.4. No coverage gap.

---

## Conclusion

✅ **All 13 legacy call sites have registered descriptors.**  
✅ **No coverage gaps detected.**  
✅ **Ready to proceed with Layer 2 (WU3, WU4, WU5) migrations.**

The registration work in WU1 (Sorties 1–5) completed on commit `43b5b84` and subsequent commits, providing complete ComponentDescriptor coverage for every legacy API call site in the codebase.

---

**Next Steps**:
1. WU2.1 (`loadWithAcervoStrict` API) lands.
2. WU2.2 audit (this document) confirms coverage.
3. WU3–WU5 migrate call sites in parallel waves (11 sorties, 5 concurrent max).
4. WU6 upgrades dependencies and deletes legacy code.
5. WU7 verifies integration and opens PR.
