# WU1 Sortie 3 — Qwen3 TTS Variant Enumeration

**Source files scanned:**
- `Sources/MLXAudioTTS/Models/Qwen3/Qwen3.swift` (`Qwen3Model.fromPretrained(_:)` at line 863)
- `Sources/MLXAudioTTS/Models/Qwen3TTS/Qwen3TTS.swift` (`Qwen3TTSModel.fromPretrained(_:)` at line 1591)
- `Tests/MLXAudioTTSTests.swift` (all `mlx-community/Qwen3-TTS-*` and `mlx-community/VyvoTTS-*` string-literal model IDs)

## Key finding on API shape

Both `Qwen3Model.fromPretrained(_:)` and `Qwen3TTSModel.fromPretrained(_:)` take an **arbitrary `String` repo ID**. They are NOT restricted to a fixed compiled-in list of variants — any HuggingFace repo whose `config.json` matches the expected schema can be loaded.

Because of that, "pre-registration of every possible Qwen3 TTS variant" is impossible in principle. We register only the variants the codebase + tests reference by name. Dynamic user-specified variants cannot be pre-registered as `ComponentDescriptor`s; they will fail `loadWithAcervoStrict` after WU2 lands (that is the stated policy in `REQUIREMENTS.md` § Non-Goals and § ComponentDescriptor Coverage Matrix).

## Enumerated variants (checklist)

### Already registered (do NOT re-register)

- [x] `mlx-community/VyvoTTS-EN-Beta-4bit` — componentId `vyvo-tts-beta-4bit`
  - **Class**: `Qwen3Model` (Sources/MLXAudioTTS/Models/Qwen3/Qwen3.swift)
  - **Status**: Registered in `AudioModelRepo.vyvoTTSBeta4bit` and `vyvoTTSBeta4bitRequiredFiles` since the P2 registration pass.
  - **Files**: `config.json`, `model.safetensors`, `tokenizer.json`
  - **Source**: referenced in `Sources/MLXAudioTTS/Models/Qwen3/README.md` and `Tests/MLXAudioTTSTests.swift:1759,1796`

### New variants to register

- [x] `mlx-community/Qwen3-TTS-12Hz-1.7B-Base-bf16` — componentId `qwen3-tts-12hz-1.7b-base-bf16`
  - **Class**: `Qwen3TTSModel` (Sources/MLXAudioTTS/Models/Qwen3TTS/Qwen3TTS.swift)
  - **tts_model_type**: `"base"` (voice source: x-vector from ref audio or none; has ECAPA-TDNN speaker encoder)
  - **Source**: `Tests/MLXAudioTTSTests.swift:3857, 4129, 4309` (integration test repo IDs)
  - **Files**: `config.json`, `vocab.json`, `merges.txt`, `tokenizer_config.json`, `model.safetensors`, `speech_tokenizer/config.json`, `speech_tokenizer/model.safetensors` (note: `tokenizer.json` is generated on first load — not downloaded; speaker encoder weights are part of the main `model.safetensors`)

- [x] `mlx-community/Qwen3-TTS-12Hz-1.7B-VoiceDesign-bf16` — componentId `qwen3-tts-12hz-1.7b-voice-design-bf16`
  - **Class**: `Qwen3TTSModel`
  - **tts_model_type**: `"voice_design"` (voice source: text description / instruct; no speaker encoder)
  - **Source**: `Tests/MLXAudioTTSTests.swift:1973, 2034, 2100`
  - **Files**: `config.json`, `vocab.json`, `merges.txt`, `tokenizer_config.json`, `model.safetensors`, `speech_tokenizer/config.json`, `speech_tokenizer/model.safetensors`

- [x] `mlx-community/Qwen3-TTS-12Hz-1.7B-CustomVoice-bf16` — componentId `qwen3-tts-12hz-1.7b-custom-voice-bf16`
  - **Class**: `Qwen3TTSModel`
  - **tts_model_type**: `"custom_voice"` (voice source: predefined named speakers; no speaker encoder)
  - **Source**: `Tests/MLXAudioTTSTests.swift:3975`
  - **Files**: `config.json`, `vocab.json`, `merges.txt`, `tokenizer_config.json`, `model.safetensors`, `speech_tokenizer/config.json`, `speech_tokenizer/model.safetensors`

## Count

- Total Qwen3 TTS variants enumerated: **4**
- Already registered (VyvoTTS): **1**
- New registrations added in this sortie: **3**

## Notes

- `ComponentFile(relativePath:)` initializer accepts only `relativePath`; SHA-256 is not part of the current API surface (the stale plan text about checksums was corrected in the sortie brief).
- The Qwen3-TTS 12Hz 1.7B repos ship a slow tokenizer (`vocab.json` + `merges.txt`) without `tokenizer.json`. `Qwen3TTSModel.fromPretrained` generates `tokenizer.json` on first load. We therefore declare `vocab.json`, `merges.txt`, and `tokenizer_config.json` as required files, NOT `tokenizer.json`.
- The speech tokenizer subdirectory (`speech_tokenizer/`) contains its own `config.json` and `model.safetensors`. Both are required; we declare them via `speech_tokenizer/<filename>` relative paths.
- Speaker encoder weights (Base variant only) are bundled inside the top-level `model.safetensors`; they do not need a separate `ComponentFile` entry.
