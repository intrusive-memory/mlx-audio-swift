---
feature_name: OPERATION QUARTERMASTER RESHUFFLE
starting_point_commit: 43b5b846ecb11a74c1c76c8751560d79b79414de
mission_branch: mission/quartermaster-reshuffle/1
iteration: 1
---

# EXECUTION_PLAN.md — mlx-audio-swift Full Dependency Upgrade + SwiftAcervo v2 Integration

**Version**: 4.0
**Generated**: 2026-04-20
**Refined**: 2026-04-20 (atomicity, priority, parallelism, open-questions passes applied)
**Status**: READY TO EXECUTE
**Requirements Source**: `REQUIREMENTS.md` (v3.0, 2026-04-20)

---

## Terminology

> **Mission** — A definable, testable scope of work. Defines scope, acceptance criteria, and dependency structure.

> **Sortie** — An atomic, testable unit of work executed by a single autonomous AI agent in one dispatch. One aircraft, one mission, one return.

> **Work Unit** — A grouping of sorties (package, component, phase).

---

## Mission Overview

Land three outcomes in a single branch off `development`:

1. Adopt SwiftAcervo's Component Registry API (v2) exclusively — `Acervo.ensureComponentReady`, `AcervoManager.withComponentAccess`, `Acervo.modelDirectory(for:)`.
2. Upgrade every dependency to its latest published version, including the `mlx-swift-lm` major-version bump (2.x → 3.x).
3. Delete all legacy code paths: `ModelResolver`, HuggingFace Hub fallback, dual-path branching, `migrateFromLegacyPaths` bootstrap, and `swift-huggingface` as a direct dependency.

This is a clean-break atomic upgrade. No phased rollout. No compatibility shims. No migration of legacy cache data.

---

## Work Units

| Work Unit | Directory | Sorties | Layer | Dependencies |
|-----------|-----------|---------|-------|-------------|
| WU1: ComponentDescriptor Coverage | `Sources/MLXAudioCore/` + CDN workflow | 5 | 0 | none |
| WU2: Core API Foundation | `Sources/MLXAudioCore/` | 2 | 1 | WU1 |
| WU3: Codec Call-Site Migrations | `Sources/MLXAudioCodecs/` | 4 | 2 | WU2 |
| WU4: TTS Call-Site Migrations | `Sources/MLXAudioTTS/` | 5 | 2 | WU2 |
| WU5: STT Call-Site Migrations | `Sources/MLXAudioSTT/` | 2 | 2 | WU2 |
| WU6: Dependency Upgrade & Legacy Deletion | project root + `Sources/` | 5 | 3 | WU3, WU4, WU5 |
| WU7: Testing & Acceptance | `Tests/` + `.github/` | 4 | 4 | WU6 |

---

## Work Unit 1: ComponentDescriptor Coverage

Register `ComponentDescriptor`s for the 5 models flagged as BLOCKERs in the Coverage Matrix. These additions are non-breaking (new registrations only) and unblock downstream call-site migrations.

Each sortie must: (a) identify the model's HF repo + required files, (b) compute SHA-256 checksums, (c) declare `ComponentDescriptor` with `ComponentFile` array, (d) add a registration call in `ensureComponentsRegistered()`, (e) add the model to the `.github/workflows/ensure-model-cdn.yml` matrix.

### Sortie 1: Register DAC VAE ComponentDescriptor

**Priority**: 32.25 — unblocks WU3.3, then cascades to WU6+WU7 (10 downstream sorties).

**Agent**: sub-agent (edits + grep). Supervising agent runs build verification.

**Entry criteria**:
- [ ] First sortie — no prerequisites

**Tasks**:
1. Identify the DAC VAE HuggingFace repo ID and full file list currently used by `DACVAE.fromPretrained`.
2. Declare `dac-vae` `ComponentDescriptor` with `ComponentFile` array and SHA-256 for each file.
3. Add `Acervo.register(dacVAEDescriptor)` to `AudioModelManager.ensureComponentsRegistered()`.
4. Add `dac-vae` entry to `.github/workflows/ensure-model-cdn.yml` matrix.
5. Build the package to confirm the new descriptor registration compiles.

**Exit criteria**:
- [ ] `grep -rn "dac-vae" Sources/MLXAudioCore` returns a descriptor declaration and a registration call.
- [ ] `grep -rn "dac-vae" .github/workflows/ensure-model-cdn.yml` shows a matrix entry.
- [ ] `xcodebuild build -scheme MLXAudio-Package -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO` succeeds.

### Sortie 2: Register Encodec ComponentDescriptor

**Priority**: 32.25 — unblocks WU3.4, then cascades to WU6+WU7 (10 downstream sorties).

**Agent**: sub-agent (edits + grep). Supervising agent runs build verification.

**Entry criteria**:
- [ ] First sortie — no prerequisites

**Tasks**:
1. Identify the Encodec HuggingFace repo ID and full file list used by `Encodec.fromPretrained`.
2. Declare `encodec` `ComponentDescriptor` with SHA-256 checksums.
3. Register via `Acervo.register(encodecDescriptor)` in `ensureComponentsRegistered()`.
4. Add `encodec` entry to `ensure-model-cdn.yml` matrix.
5. Build to confirm.

**Exit criteria**:
- [ ] `encodec` descriptor declared and registered in `AudioModelManager.swift`.
- [ ] `encodec` appears in the CDN workflow matrix.
- [ ] Package builds successfully.

### Sortie 3: Register Qwen3 TTS ComponentDescriptor(s)

**Priority**: 32.5 — highest Layer-0 priority (multi-variant, unblocks WU4.3 + cascade = 10 downstream).

**Agent**: sub-agent (edits + grep). Supervising agent runs build verification.

**Entry criteria**:
- [ ] First sortie — no prerequisites

**Tasks**:
1. Enumerate every Qwen3 TTS variant currently supported by `Qwen3TTS.fromPretrained` and `Qwen3.swift` (grep `Sources/MLXAudioTTS/Models/Qwen3*` for variant/size/precision constants). Record the enumerated list in `docs/incomplete/WU1_QWEN3_TTS_VARIANTS.md` as a checklist.
2. Declare one `ComponentDescriptor` per variant (e.g., `qwen3-tts-0.6b`, `qwen3-tts-4b-4bit`) with SHA-256 checksums.
3. Register each via `Acervo.register(...)` in `AudioModelManager.ensureComponentsRegistered()`.
4. Add each variant to `ensure-model-cdn.yml` matrix.
5. Build to confirm.

**Exit criteria**:
- [ ] `docs/incomplete/WU1_QWEN3_TTS_VARIANTS.md` exists and lists N variants.
- [ ] `grep -c 'qwen3-tts-' Sources/MLXAudioCore/AudioModelManager.swift` returns ≥ N (one descriptor + one registration per variant, so ≥ 2N in practice).
- [ ] `grep -c 'qwen3-tts-' .github/workflows/ensure-model-cdn.yml` returns ≥ N.
- [ ] `xcodebuild build -scheme MLXAudio-Package -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO` succeeds.

### Sortie 4: Register GLM ASR ComponentDescriptor

**Priority**: 32.25 — unblocks WU5.1, then cascades to WU6+WU7 (10 downstream sorties).

**Agent**: sub-agent (edits + grep). Supervising agent runs build verification.

**Entry criteria**:
- [ ] First sortie — no prerequisites

**Tasks**:
1. Identify the GLM ASR HuggingFace repo ID and file list used by `GLMASR.fromPretrained`.
2. Declare `glm-asr` `ComponentDescriptor` with SHA-256 checksums.
3. Register via `Acervo.register(glmASRDescriptor)`.
4. Add `glm-asr` entry to `ensure-model-cdn.yml` matrix.
5. Build to confirm.

**Exit criteria**:
- [ ] `glm-asr` descriptor declared and registered.
- [ ] `glm-asr` appears in the CDN workflow matrix.
- [ ] Package builds successfully.

### Sortie 5: Register Qwen3 ASR ComponentDescriptor

**Priority**: 32.25 — unblocks WU5.2, then cascades to WU6+WU7 (10 downstream sorties).

**Agent**: sub-agent (edits + grep). Supervising agent runs build verification.

**Entry criteria**:
- [ ] First sortie — no prerequisites

**Tasks**:
1. Identify the Qwen3 ASR HuggingFace repo ID and file list used by `Qwen3ASR.fromPretrained`.
2. Declare `qwen3-asr` `ComponentDescriptor` with SHA-256 checksums.
3. Register via `Acervo.register(qwen3ASRDescriptor)`.
4. Add `qwen3-asr` entry to `ensure-model-cdn.yml` matrix.
5. Build to confirm.

**Exit criteria**:
- [ ] `qwen3-asr` descriptor declared and registered.
- [ ] `qwen3-asr` appears in the CDN workflow matrix.
- [ ] Package builds successfully.

---

## Work Unit 2: Core API Foundation

Introduce the single, strict entry point `AudioModelManager.loadWithAcervoStrict(componentId:load:)` that callers will use, and delete the `componentId(for:)` repo-ID lookup helper.

### Sortie 1: Add `loadWithAcervoStrict` to `AudioModelManager`

**Priority**: 68.75 — **HIGHEST**. Foundation sortie; unblocks all 11 Layer-2 call-site migrations plus the cascade through WU6 and WU7 (21 downstream sorties).

**Agent**: supervising agent (new API + build-sensitive).

**Entry criteria**:
- [ ] WU1 Sorties 1–5 complete (all BLOCKER descriptors registered).

**Tasks**:
1. Implement `AudioModelManager.loadWithAcervoStrict(componentId:load:)` that calls `Acervo.ensureComponentReady(componentId)`, then `AcervoManager.shared.withComponentAccess(componentId) { metadata, path in load(path) }`.
2. The function must throw `AcervoError.componentNotRegistered` if `Acervo.component(componentId)` returns nil.
3. Mark the signature `async throws` with a generic return type `<T>`.
4. Remove the `componentId(for modelId:)` HF-repo-ID lookup helper from `AudioModelManager.swift`.
5. Delete any references to `runMigrationIfNeeded`, legacy cache paths, `didMigrateLegacyPaths` UserDefault inside this file.
6. Build to confirm.

**Exit criteria**:
- [ ] `grep -rn "loadWithAcervoStrict" Sources/MLXAudioCore/AudioModelManager.swift` shows the new function definition.
- [ ] `grep -rn "componentId(for" Sources/MLXAudioCore/` returns zero matches.
- [ ] `grep -rn "runMigrationIfNeeded\|didMigrateLegacyPaths" Sources/MLXAudioCore/` returns zero matches.
- [ ] Package builds successfully.

### Sortie 2: Audit descriptor coverage against call-site inventory

**Priority**: 63.25 — second-highest. Gate before Layer 2; prevents unexpected coverage gaps from detonating mid-migration.

**Agent**: sub-agent (grep + documentation only — no build).

**Entry criteria**:
- [ ] WU2 Sortie 1 complete.

**Tasks**:
1. Run a grep of all `ModelResolver.resolve`, `ModelResolver.resolveFile`, and `Acervo.download(_:files:progress:)` call sites in `Sources/`.
2. Cross-reference each call site against the Coverage Matrix; verify every model has a registered descriptor.
3. Document findings in `docs/incomplete/WU2_COVERAGE_AUDIT.md` — one row per call site with file:line, current API, target `componentId`, and status (registered / gap).
4. If any gap is discovered that was not anticipated in the Coverage Matrix, halt and surface to the user.

**Exit criteria**:
- [ ] `docs/incomplete/WU2_COVERAGE_AUDIT.md` exists with a row for every legacy call site.
- [ ] Every row has a target `componentId` that maps to a registered descriptor.
- [ ] Zero unresolved gaps (or halt-and-surface if any exist).

---

## Work Unit 3: Codec Call-Site Migrations

Migrate each codec's `fromPretrained` call path to use `AudioModelManager.loadWithAcervoStrict`. These sorties do NOT bump Package.swift or delete `ModelResolver.swift` — they add the new call path alongside the old one so the project continues to compile on the current dependency set.

### Sortie 1: Migrate SNAC

**Priority**: 29.5 — Layer-2 parallel batch; unblocks WU6.1 once all WU3/4/5 complete (9 downstream sorties).

**Agent**: sub-agent (edits + grep). Supervising agent runs build gate.

**Entry criteria**:
- [ ] WU2 complete.

**Tasks**:
1. Rewrite `SNACDecoder.fromPretrained(_:)` in `Sources/MLXAudioCodecs/SNAC/SNACDecoder.swift` to call `AudioModelManager.loadWithAcervoStrict(componentId: "snac-24khz", load: ...)`.
2. Delete `SNACDecoder.fromPretrainedLegacy(_:)` (line 195 per REQUIREMENTS.md).
3. Delete the unknown-repo branch at lines 164–166.
4. Delete the `(Future: will upgrade to v2 ComponentAccess API...)` comment.
5. Build to confirm.

**Exit criteria**:
- [ ] `grep -rn "fromPretrainedLegacy" Sources/MLXAudioCodecs/SNAC/` returns zero matches.
- [ ] `grep -rn "ModelResolver" Sources/MLXAudioCodecs/SNAC/` returns zero matches.
- [ ] `grep -rn "loadWithAcervoStrict" Sources/MLXAudioCodecs/SNAC/SNACDecoder.swift` returns at least one match.
- [ ] Package builds successfully.

### Sortie 2: Migrate Mimi

**Priority**: 29.5 — Layer-2 parallel batch (9 downstream sorties).

**Agent**: sub-agent (edits + grep). Supervising agent runs build gate.

**Entry criteria**:
- [ ] WU2 complete.

**Tasks**:
1. Rewrite `Mimi.fromPretrained(_:)` to call `loadWithAcervoStrict(componentId: "mimi-pytorch-bf16", load: ...)`.
2. Delete `Mimi.fromPretrainedLegacy(_:)` (line ~328) and the `ModelResolver.resolveFile` call (line 348).
3. Delete the unknown-repo branch (lines 251–252).
4. Build to confirm.

**Exit criteria**:
- [ ] `grep -rn "fromPretrainedLegacy\|ModelResolver" Sources/MLXAudioCodecs/Mimi/` returns zero matches.
- [ ] `grep -rn "loadWithAcervoStrict" Sources/MLXAudioCodecs/Mimi/Mimi.swift` returns at least one match.
- [ ] Package builds successfully.

### Sortie 3: Migrate DACVAE

**Priority**: 29.5 — Layer-2 parallel batch (9 downstream sorties).

**Agent**: sub-agent (edits + grep). Supervising agent runs build gate.

**Entry criteria**:
- [ ] WU2 complete.
- [ ] WU1 Sortie 1 (DAC VAE descriptor) complete.

**Tasks**:
1. At `Sources/MLXAudioCodecs/DACVAE/DACVAE.swift:391`, replace the `ModelResolver.resolve` call with `loadWithAcervoStrict(componentId: "dac-vae", load: ...)`.
2. Delete any `fromPretrainedLegacy` variants and unknown-repo branches in DACVAE.
3. Build to confirm.

**Exit criteria**:
- [ ] `grep -rn "ModelResolver" Sources/MLXAudioCodecs/DACVAE/` returns zero matches.
- [ ] `grep -rn "loadWithAcervoStrict" Sources/MLXAudioCodecs/DACVAE/DACVAE.swift` returns at least one match.
- [ ] Package builds successfully.

### Sortie 4: Migrate Encodec

**Priority**: 29.5 — Layer-2 parallel batch (9 downstream sorties).

**Agent**: sub-agent (edits + grep). Supervising agent runs build gate.

**Entry criteria**:
- [ ] WU2 complete.
- [ ] WU1 Sortie 2 (Encodec descriptor) complete.

**Tasks**:
1. At `Sources/MLXAudioCodecs/Encodec/Encodec.swift:402`, replace the `ModelResolver.resolve` call with `loadWithAcervoStrict(componentId: "encodec", load: ...)`.
2. Delete legacy fallback paths in Encodec.
3. Build to confirm.

**Exit criteria**:
- [ ] `grep -rn "ModelResolver" Sources/MLXAudioCodecs/Encodec/` returns zero matches.
- [ ] `grep -rn "loadWithAcervoStrict" Sources/MLXAudioCodecs/Encodec/Encodec.swift` returns at least one match.
- [ ] Package builds successfully.

---

## Work Unit 4: TTS Call-Site Migrations

### Sortie 1: Migrate Llama TTS (Orpheus)

**Priority**: 29.5 — Layer-2 parallel batch (9 downstream sorties).

**Agent**: sub-agent (edits + grep). Supervising agent runs build gate.

**Entry criteria**:
- [ ] WU2 complete.

**Tasks**:
1. At `Sources/MLXAudioTTS/Models/Llama/LlamaTTS.swift:914`, replace the `ModelResolver.resolve` call with `loadWithAcervoStrict(componentId: "orpheus-tts-3b", load: ...)`.
2. Remove `import HuggingFace` from this file.
3. Build to confirm.

**Exit criteria**:
- [ ] `grep -n "import HuggingFace\|ModelResolver" Sources/MLXAudioTTS/Models/Llama/LlamaTTS.swift` returns zero matches.
- [ ] Package builds successfully.

### Sortie 2: Migrate Soprano TTS

**Priority**: 29.5 — Layer-2 parallel batch (9 downstream sorties).

**Agent**: sub-agent (edits + grep). Supervising agent runs build gate.

**Entry criteria**:
- [ ] WU2 complete.

**Tasks**:
1. At `Sources/MLXAudioTTS/Models/Soprano/Soprano.swift:878`, replace the `ModelResolver.resolve` call with `loadWithAcervoStrict(componentId: "soprano-tts-80m", load: ...)`.
2. Remove `import HuggingFace` from this file.
3. Build to confirm.

**Exit criteria**:
- [ ] `grep -n "import HuggingFace\|ModelResolver" Sources/MLXAudioTTS/Models/Soprano/Soprano.swift` returns zero matches.
- [ ] Package builds successfully.

### Sortie 3: Migrate Qwen3 TTS

**Priority**: 29.5 — Layer-2 parallel batch (9 downstream sorties). Variant-dispatch complexity keeps this on the supervising agent.

**Agent**: supervising agent (variant dispatch + two-file edit).

**Entry criteria**:
- [ ] WU2 complete.
- [ ] WU1 Sortie 3 (Qwen3 TTS descriptors) complete.

**Tasks**:
1. At `Sources/MLXAudioTTS/Models/Qwen3/Qwen3.swift:864`, replace the `ModelResolver.resolve` call with `loadWithAcervoStrict(componentId: "<variant>", load: ...)` dispatching on the requested variant.
2. Remove `import HuggingFace` from `Qwen3.swift` and from `Sources/MLXAudioTTS/Models/Qwen3TTS/Qwen3TTS.swift`.
3. Build to confirm.

**Exit criteria**:
- [ ] `grep -rn "import HuggingFace\|ModelResolver" Sources/MLXAudioTTS/Models/Qwen3/ Sources/MLXAudioTTS/Models/Qwen3TTS/` returns zero matches.
- [ ] Package builds successfully.

### Sortie 4: Migrate PocketTTS

**Priority**: 29.5 — Layer-2 parallel batch (9 downstream sorties).

**Agent**: sub-agent (edits + grep). Supervising agent runs build gate.

**Entry criteria**:
- [ ] WU2 complete.

**Tasks**:
1. At `Sources/MLXAudioTTS/Models/PocketTTS/PocketTTSModel.swift:343`, replace the `ModelResolver.resolve` call with `loadWithAcervoStrict(componentId: "pocket-tts", load: ...)`.
2. Remove `import Hub` and `import HuggingFace` from this file.
3. Build to confirm.

**Exit criteria**:
- [ ] `grep -n "import Hub\|import HuggingFace\|ModelResolver" Sources/MLXAudioTTS/Models/PocketTTS/PocketTTSModel.swift` returns zero matches.
- [ ] Package builds successfully.

### Sortie 5: Migrate Marvis TTS call-site (loadWithAcervoStrict only)

**Priority**: 29.5 — Layer-2 parallel batch (9 downstream sorties). Partial migration — leaves tokenizer call sites for WU6.2.

**Agent**: sub-agent (edits + grep). Supervising agent runs build gate.

**Entry criteria**:
- [ ] WU2 complete.

**Tasks**:
1. In `Sources/MLXAudioTTS/Models/Marvis/MarvisTTSModel.swift`, replace any `ModelResolver.resolve` call with `loadWithAcervoStrict(componentId: "marvis-tts-250m-8bit", load: ...)`.
2. Leave the `HubApi` default-arg signature, `ModelConfiguration(id:)`, and `loadTokenizer(...)` call sites UNTOUCHED — those are migrated in WU6 Sortie 2 together with the mlx-swift-lm 3.x bump.
3. Do NOT remove `import Hub` or `import HuggingFace` in this sortie (MarvisTTSModel still compiles against swift-transformers 1.1.6 in this state).
4. Build to confirm.

**Exit criteria**:
- [ ] `grep -n "ModelResolver" Sources/MLXAudioTTS/Models/Marvis/MarvisTTSModel.swift` returns zero matches.
- [ ] `grep -n "loadWithAcervoStrict" Sources/MLXAudioTTS/Models/Marvis/MarvisTTSModel.swift` returns at least one match.
- [ ] Package builds successfully.

---

## Work Unit 5: STT Call-Site Migrations

### Sortie 1: Migrate GLM ASR

**Priority**: 29.5 — Layer-2 parallel batch (9 downstream sorties).

**Agent**: sub-agent (edits + grep). Supervising agent runs build gate.

**Entry criteria**:
- [ ] WU2 complete.
- [ ] WU1 Sortie 4 (GLM ASR descriptor) complete.

**Tasks**:
1. At `Sources/MLXAudioSTT/Models/GLMASR/GLMASR.swift:563`, replace the `ModelResolver.resolve` call with `loadWithAcervoStrict(componentId: "glm-asr", load: ...)`.
2. Remove `import HuggingFace` from this file.
3. Build to confirm.

**Exit criteria**:
- [ ] `grep -n "import HuggingFace\|ModelResolver" Sources/MLXAudioSTT/Models/GLMASR/GLMASR.swift` returns zero matches.
- [ ] Package builds successfully.

### Sortie 2: Migrate Qwen3 ASR + ForcedAligner

**Priority**: 29.5 — Layer-2 parallel batch (9 downstream sorties).

**Agent**: sub-agent (edits + grep). Supervising agent runs build gate.

**Entry criteria**:
- [ ] WU2 complete.
- [ ] WU1 Sortie 5 (Qwen3 ASR descriptor) complete.

**Tasks**:
1. In `Sources/MLXAudioSTT/Models/Qwen3ASR/Qwen3ASR.swift`, replace `ModelResolver.resolve` with `loadWithAcervoStrict(componentId: "qwen3-asr", load: ...)`.
2. Remove `import HuggingFace` from `Qwen3ASR.swift` and `Sources/MLXAudioSTT/Models/Qwen3ASR/Qwen3ForcedAligner.swift`.
3. Build to confirm.

**Exit criteria**:
- [ ] `grep -rn "import HuggingFace\|ModelResolver" Sources/MLXAudioSTT/Models/Qwen3ASR/` returns zero matches.
- [ ] Package builds successfully.

---

## Work Unit 6: Dependency Upgrade & Legacy Deletion

**This is the clean-break layer.** Once WU3/WU4/WU5 are complete, no production code should reference `ModelResolver` or `HubClient`. This work unit bumps every dependency, deletes dead files, and migrates MarvisTTSModel to the swift-transformers 1.3.0 + mlx-swift-lm 3.x surface.

### Sortie 1: Bump `Package.swift` dependencies

**Priority**: 29.5 — gate sortie for Layer 3; unblocks WU6.2, WU6.3, and the WU6.4/5 cleanup cascade (8 downstream sorties).

**Agent**: supervising agent (package resolve + build — build failures expected until WU6.2/6.3 land).

**Entry criteria**:
- [ ] WU3, WU4, WU5 complete.
- [ ] `grep -rn "ModelResolver" Sources/` returns zero matches.

**Tasks**:
1. Update `Package.swift` `dependencies` array to match the target versions from REQUIREMENTS.md § Target Dependency Versions.
2. Remove the `https://github.com/huggingface/swift-huggingface.git` entry.
3. Remove every `.product(name: "HuggingFace", package: "swift-huggingface")` from target `dependencies`.
4. Add `SwiftAcervo` product dependency to `MLXAudioCodecs`, `MLXAudioTTS`, `MLXAudioSTT` targets if not already present.
5. Run `xcodebuild -resolvePackageDependencies -scheme MLXAudio-Package` to regenerate `Package.resolved`.
6. Build — expect failures only in MarvisTTSModel.swift (handled by next sortie) and in `decode(tokens:)` call sites (handled by Sortie 3).

**Exit criteria**:
- [ ] `grep -n "swift-huggingface\|HuggingFace" Package.swift` returns zero matches.
- [ ] `Package.resolved` pins `mlx-swift-lm` at 3.31.x, `swift-transformers` at 1.3.x, `SwiftAcervo` at 0.7.2.
- [ ] `grep -c 'package = "swift-huggingface"' Package.resolved` returns 0.

### Sortie 2: Migrate MarvisTTSModel to mlx-swift-lm 3.x + swift-transformers 1.3.0

**Priority**: 21.5 — Layer-3 parallel with WU6.3 (6 downstream sorties). Highest risk: major-version API surface change.

**Agent**: supervising agent (new tokenizer API + build-sensitive).

**Entry criteria**:
- [ ] WU6 Sortie 1 complete.

**Tasks**:
1. In `Sources/MLXAudioTTS/Models/Marvis/MarvisTTSModel.swift`, rewrite the `HubApi`-accepting default-arg function signature (lines 53, 221) to drop the `hub:` parameter.
2. Replace `ModelConfiguration(id: repoId, tokenizerId: ...)` / `overrideTokenizer:` with `ModelConfiguration(tokenizerSource: .directory(modelDirectory))` resolved via `Acervo.modelDirectory(for: "marvis-tts-250m-8bit")`.
3. Replace `loadTokenizer(configuration:hub:)` with `AutoTokenizer.from(directory: modelDirectory)` (line 58).
4. Remove `import Hub` and `import HuggingFace` from MarvisTTSModel.swift and from `Sources/MLXAudioTTS/Models/Marvis/CSMModel.swift` (line 3).
5. Build to confirm MarvisTTSModel compiles.

**Exit criteria**:
- [ ] `grep -n "HubApi\|import Hub\|import HuggingFace\|loadTokenizer\|tokenizerId:\|overrideTokenizer:" Sources/MLXAudioTTS/Models/Marvis/` returns zero matches.
- [ ] `grep -n "AutoTokenizer.from(directory:" Sources/MLXAudioTTS/Models/Marvis/MarvisTTSModel.swift` returns at least one match.
- [ ] Package builds successfully.

### Sortie 3: `decode(tokens:)` → `decode(tokenIds:)` sweep

**Priority**: 19.5 — Layer-3 parallel with WU6.2 (6 downstream sorties). Simple label rename, but test regression must be confirmed.

**Agent**: sub-agent (edits + grep). Supervising agent runs build + unit tests.

**Entry criteria**:
- [ ] WU6 Sortie 1 complete.

**Tasks**:
1. Run `grep -rn "\.decode(tokens:" Sources Tests` and list every hit.
2. Change each hit's parameter label from `tokens:` to `tokenIds:`.
3. Build + run the CLAUDE.md unit test suite to confirm no regression in tokenizer decoding.

**Exit criteria**:
- [ ] `grep -rn "\.decode(tokens:" Sources Tests` returns zero matches.
- [ ] `grep -rn "\.decode(tokenIds:" Sources` returns at least one match.
- [ ] Package builds successfully: `xcodebuild build -scheme MLXAudio-Package -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO`.
- [ ] The complete CLAUDE.md unit-test command passes (all 24 no-download suites listed in `CLAUDE.md`).

### Sortie 4: Delete `ModelResolver.swift` and dead helpers

**Priority**: 17.5 — unblocks WU6.5 and WU7 (5 downstream sorties).

**Agent**: sub-agent (file deletion + grep). Supervising agent runs build gate.

**Entry criteria**:
- [ ] WU6 Sorties 1–3 complete.

**Tasks**:
1. Delete `Sources/MLXAudioCore/ModelResolver.swift`.
2. In `Sources/MLXAudioCore/ModelUtils.swift`: delete the two `ModelResolver.resolve` wrappers (lines 89, 109) and every `HubClient`-accepting overload.
3. In `Sources/MLXAudioTTS/TTSModelUtils.swift`: remove `import HuggingFace` (line 2) and delete any `HubClient`-accepting helpers.
4. Remove the `Acervo.migrateFromLegacyPaths()` call from wherever it is invoked (should be nowhere by this point — confirm with grep).
5. Move `docs/incomplete/REQUIREMENTS_PHASE1_AUDIT.md` to `docs/complete/` if it exists.
6. Build to confirm.

**Exit criteria**:
- [ ] `test ! -f Sources/MLXAudioCore/ModelResolver.swift` succeeds.
- [ ] `grep -rn "ModelResolver" Sources/ Tests/` returns zero matches.
- [ ] `grep -rn "migrateFromLegacyPaths" Sources/` returns zero matches.
- [ ] `grep -rn "HubClient" Sources/` returns zero matches.
- [ ] Package builds successfully.

### Sortie 5: Final import cleanup sweep

**Priority**: 13.25 — last Layer-3 sortie; unblocks WU7 (4 downstream sorties).

**Agent**: sub-agent (edits + grep). Supervising agent runs build gate.

**Entry criteria**:
- [ ] WU6 Sorties 1–4 complete.

**Tasks**:
1. Run `grep -rn "import HuggingFace\|import Hub" Sources/` — expect zero matches. Remove any stragglers.
2. Run `grep -rn "Acervo.download(" Sources/` — expect zero matches outside SwiftAcervo itself.
3. Run `grep -rn "isModelAvailable\|modelFileExists" Sources/` — expect zero matches (replaced by `isComponentReady`).
4. Build to confirm.

**Exit criteria**:
- [ ] `grep -rn "import HuggingFace\|import Hub" Sources/` returns zero matches.
- [ ] `grep -rn "Acervo.download(" Sources/` returns zero matches.
- [ ] `grep -rn "isModelAvailable\|modelFileExists" Sources/` returns zero matches.
- [ ] Package builds successfully.

---

## Work Unit 7: Testing & Acceptance

### Sortie 1: Unit test migration (no downloads)

**Priority**: 13.5 — first Layer-4 sortie; gates WU7.2/3/4 (3 downstream sorties).

**Agent**: supervising agent (test runner).

**Entry criteria**:
- [ ] WU6 complete.

**Tasks**:
1. Delete or rewrite any test that currently exercises `ModelResolver` to use a mocked `AudioModelManager.loadWithAcervoStrict` path.
2. Update test imports — remove `import HuggingFace` / `import Hub` from `Tests/`.
3. Run the full no-download test list from `CLAUDE.md`.

**Exit criteria**:
- [ ] `grep -rn "ModelResolver\|import HuggingFace\|import Hub" Tests/` returns zero matches.
- [ ] The complete CLAUDE.md unit-test command passes: `xcodebuild test -scheme MLXAudio-Package -destination 'platform=macOS' -only-testing:MLXAudioTests/VocosTests ... CODE_SIGNING_ALLOWED=NO` (all 24 suites listed in CLAUDE.md).

### Sortie 2: Re-record tokenizer golden outputs

**Priority**: 7.5 — gates WU7.3 and WU7.4 (2 downstream sorties).

**Agent**: supervising agent (test-discovery + regeneration + test run).

**Entry criteria**:
- [ ] WU7 Sortie 1 complete.

**Tasks**:
1. Identify every test that snapshots a rendered chat template or tokenizer output (`Tests/**/*.swift` using `XCTAssertEqual` against a string containing chat-template whitespace). Write the enumerated list to `docs/incomplete/WU7_GOLDEN_FIXTURE_INVENTORY.md`.
2. Regenerate each golden output against swift-transformers 1.3.0's new defaults (`lstripBlocks: true, trimBlocks: true`).
3. Commit the updated fixtures.

**Exit criteria**:
- [ ] `docs/incomplete/WU7_GOLDEN_FIXTURE_INVENTORY.md` exists and lists every touched test file.
- [ ] Every test suite enumerated in step 1 passes via `xcodebuild test -scheme MLXAudio-Package -destination 'platform=macOS' -only-testing:<SuiteName> CODE_SIGNING_ALLOWED=NO`.
- [ ] Any diff in golden fixtures is committed with a message explaining the swift-transformers 1.2.0 whitespace flip.

### Sortie 3: Integration test smoke — one model per family

**Priority**: 6 — gates WU7.4 (1 downstream sortie).

**Agent**: supervising agent (local model downloads required — cannot parallelize to sub-agents).

**Entry criteria**:
- [ ] WU7 Sorties 1–2 complete.
- [ ] CDN artifacts uploaded for all new descriptors (WU1 Sorties 1–5 workflow runs green).

**Tasks**:
1. Run one TTS integration test (e.g., `Qwen3TTSTests` or `SopranoTTSTests`) locally with model downloads.
2. Run one STT integration test (e.g., `GLMASRTests` or `Qwen3ASRTests`).
3. Run one codec integration test (e.g., `SNACTests` or `MimiTests`).
4. Confirm all three download via Acervo CDN and complete without network errors.

**Exit criteria**:
- [ ] One TTS, one STT, and one codec integration test pass locally.
- [ ] Test logs show downloads via Acervo CDN path only (no HuggingFace endpoint URLs).

### Sortie 4: Branch protection + acceptance checklist

**Priority**: 3.5 — terminal sortie; opens PR. Blocks nothing downstream.

**Agent**: supervising agent (gh CLI + branch protection is risky/irreversible — keep with the supervisor).

**Entry criteria**:
- [ ] WU7 Sorties 1–3 complete.

**Tasks**:
1. Run through every item in REQUIREMENTS.md § Acceptance Checklist and verify each by command.
2. If any CI job name has changed, update branch protection for `development` and `main` via `gh api` to match new required-check names.
3. Open the PR from `development` to `main` with a summary of removed deps, new descriptors, and the v2 Component Registry migration.

**Exit criteria**:
- [ ] Every acceptance-checklist item in REQUIREMENTS.md ticks as verified.
- [ ] `gh api repos/intrusive-memory/mlx-audio-swift/branches/main/protection` shows required-check names that match current workflow job names.
- [ ] PR exists from `development` → `main`.

---

## Parallelism Structure

**Critical Path** (12 sorties): `WU1.3 → WU2.1 → WU2.2 → WU4.3 → WU6.1 → WU6.2 → WU6.4 → WU6.5 → WU7.1 → WU7.2 → WU7.3 → WU7.4`

Either branch of the WU6.2/6.3 pair extends the critical path by equal length; WU6.2 is shown because it carries the higher risk score. Any Layer-0 WU1 sortie could substitute for WU1.3; WU1.3 is shown because it has the highest Layer-0 priority.

**Parallel Execution Groups**:

- **Group 0 — Layer 0 (all parallel, no dependencies)**
  - WU1.1 Register DAC VAE — sub-agent
  - WU1.2 Register Encodec — sub-agent
  - WU1.3 Register Qwen3 TTS variants — sub-agent
  - WU1.4 Register GLM ASR — sub-agent
  - WU1.5 Register Qwen3 ASR — sub-agent (fifth slot handled by supervising agent between build gates for Sorties 1–4)

- **Group 1a — Layer 1 foundation (sequential, blocks everything)**
  - WU2.1 Add `loadWithAcervoStrict` — **supervising agent only** (new API + build-sensitive)
- **Group 1b — Layer 1 audit (sequential after WU2.1)**
  - WU2.2 Coverage audit — sub-agent (grep + markdown, no build)

- **Group 2 — Layer 2 call-site migrations (11 sorties, parallel in waves of 4+1 = 5 concurrent)**
  - Wave 2a: WU3.1 SNAC, WU3.2 Mimi, WU3.3 DACVAE, WU3.4 Encodec — sub-agents; WU4.1 Llama TTS — supervising agent
  - Wave 2b: WU4.2 Soprano, WU4.4 PocketTTS, WU4.5 Marvis, WU5.1 GLM ASR — sub-agents; WU5.2 Qwen3 ASR — supervising agent
  - Wave 2c: WU4.3 Qwen3 TTS — **supervising agent only** (variant dispatch + two-file edit)
  - Each sortie: sub-agent edits + grep-verifies; supervising agent runs `xcodebuild build` gate before marking COMPLETED.

- **Group 3 — Layer 3 dependency upgrade (sequential gate, then parallel pair, then sequential tail)**
  - WU6.1 Package.swift bump — **supervising agent only** (must land first; build failures expected until WU6.2/6.3)
  - WU6.2 Marvis migration + WU6.3 decode(tokens:) sweep — parallel; WU6.2 on supervising agent, WU6.3 on sub-agent with supervisor-run build+tests
  - WU6.4 Delete ModelResolver — sub-agent (edits + grep), supervisor runs build gate
  - WU6.5 Final import sweep — sub-agent (edits + grep), supervisor runs build gate

- **Group 4 — Layer 4 verification (fully sequential)**
  - WU7.1 Unit tests → WU7.2 Golden fixtures → WU7.3 Integration smoke → WU7.4 Branch protection + PR
  - All supervising agent (test runners + gh CLI).

**Agent Constraints**:
- **Supervising agent**: runs every `xcodebuild build` verification, every `xcodebuild test` run, every `gh` / branch-protection operation, and any sortie with a new API surface or variant-dispatch logic (WU2.1, WU4.3, WU6.1, WU6.2, entirety of WU7).
- **Sub-agents (max 4 concurrent)**: file edits, `grep` verification, markdown doc generation. Sub-agents do NOT invoke `xcodebuild`; they report ready-for-build and the supervising agent runs the gate.
- **Max concurrency per wave**: 1 supervising + 4 sub-agents = 5 sorties.

**Parallelism Metrics**:
- Critical path length: 12 sorties
- Total sorties: 27
- Theoretical maximum parallelism: 5 concurrent sorties (Layer 0 and Layer 2 waves)
- Current layering is already near-optimal — no reordering opportunities missed.
- Build-gate constraint forces supervising agent as the serialization point for every wave's completion.

---

## Open Questions & Missing Documentation

Pass 4 scan results:

| Category | Count | Blocking |
|----------|-------|----------|
| Open questions (unresolved decisions) | 0 | 0 |
| Vague criteria | 3 (auto-fixed in WU1.3, WU6.3, WU7.2) | 0 |
| Missing documentation | 0 | 0 |
| External dependencies (undocumented) | 0 | 0 |

**Auto-fixed vague criteria**:
- WU1.3 exit now requires `docs/incomplete/WU1_QWEN3_TTS_VARIANTS.md` to enumerate N variants and the registration + workflow counts to match.
- WU6.3 exit now requires the full CLAUDE.md unit-test command to pass (previously only checked build).
- WU7.2 exit now requires `docs/incomplete/WU7_GOLDEN_FIXTURE_INVENTORY.md` to enumerate every touched test suite, and each must pass individually by `-only-testing:<SuiteName>`.

**No blocking issues.** Plan is ready to execute.

---

## Summary

| Metric | Value |
|--------|-------|
| Work units | 7 |
| Total sorties | 27 |
| Dependency structure | Layered (0 → 4), with parallelism within WU1, WU3, WU4, WU5 |
| Critical path length | 12 sorties |
| Max concurrent sorties | 5 (1 supervising + 4 sub-agents) |
| Build-gated sorties (supervising agent required) | 27 (every sortie ends on an `xcodebuild` verification) |
| Sub-agent–eligible sorties (edits + grep only) | 17 |
| Layer 0 (independent, parallel) | WU1 Sorties 1–5 |
| Layer 1 (foundation) | WU2 Sorties 1–2 |
| Layer 2 (call-site migrations, parallel across WU3/4/5) | 11 sorties |
| Layer 3 (atomic upgrade) | WU6 Sorties 1–5 |
| Layer 4 (verification) | WU7 Sorties 1–4 |
| Highest-priority sortie | WU2.1 (68.75) — unblocks 21 downstream |
| Critical path | `WU1.3 → WU2.1 → WU2.2 → WU4.3 → WU6.1 → WU6.2 → WU6.4 → WU6.5 → WU7.1 → WU7.2 → WU7.3 → WU7.4` |
