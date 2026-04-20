# WU7.3 Integration Smoke Report

**Date**: 2026-04-20  
**Branch**: mission/quartermaster-reshuffle/1  
**Scope (approved by supervisor)**: Soprano TTS + SNAC codec. STT deferred.  
**Outcome**: BLOCKED — two distinct infrastructure blockers prevent both families.

---

## CDN State Audit (pre-test)

Before running tests, all P1 model CDN manifests were probed:

| Model slug | CDN HTTP status |
|---|---|
| `mlx-community_Soprano-80M-bf16` | **404** — not uploaded |
| `mlx-community_snac_24khz` | **404** — not uploaded |
| `kyutai_moshiko-pytorch-bf16` | **404** — not uploaded |
| `mlx-community_VyvoTTS-EN-Beta-4bit` | **404** — not uploaded |
| `mlx-community_orpheus-3b-0.1-ft-bf16` | **404** — not uploaded |
| `mlx-community_pocket-tts` | **404** — not uploaded |
| `Marvis-AI_marvis-tts-250m-v0.2-MLX-8bit` | **404** — not uploaded |
| `mlx-community_Qwen3-TTS-12Hz-1.7B-Base-bf16` | **200** — present |
| `mlx-community_Qwen3-TTS-12Hz-1.7B-CustomVoice-bf16` | **200** — present |
| `mlx-community_Qwen3-TTS-12Hz-1.7B-VoiceDesign-bf16` | **200** — present |

CDN base URL: `https://pub-8e049ed02be340cbb18f921765fd24f3.r2.dev/models/{slug}/manifest.json`

**Finding**: Only the three Qwen3-TTS variants are on the CDN. The mission brief's claim that `soprano-tts-80m`, `snac-24khz`, and other P1 models are "pre-existing CDN-present descriptors" was incorrect. The `ensure-model-cdn.yml` nightly workflow has not yet run since these entries were added to the matrix.

---

## TTS Smoke: SopranoTTSTests

**Suite**: `SopranoTTSTests`  
**Command**:
```
xcodebuild test -scheme MLXAudio-Package -destination 'platform=macOS' \
  -only-testing:MLXAudioTests/SopranoTTSTests CODE_SIGNING_ALLOWED=NO
```

**Result**: FAIL (2 issues)  
**Final xcodebuild line**: `** TEST FAILED **`

### Failure sequence

1. **First run**: `directoryCreationFailed("/Users/stovak/Library/Group Containers/group.intrusive-memory.models/SharedModels/mlx-community_Soprano-80M-bf16")` — the group container exists but the directory for this model had not yet been created. Pre-creating it manually allowed the test to proceed.

2. **Second run**: `manifestDownloadFailed(statusCode: 404)` — SwiftAcervo attempted to download the CDN manifest at `https://pub-8e049ed02be340cbb18f921765fd24f3.r2.dev/models/mlx-community_Soprano-80M-bf16/manifest.json` and received HTTP 404.

**CDN URL observed**: `pub-8e049ed02be340cbb18f921765fd24f3.r2.dev` (correct Acervo CDN — no HuggingFace URLs)  
**HuggingFace URLs**: None observed — loader correctly routes exclusively through Acervo CDN.  
**Timing**: ~0.3 seconds (fails immediately at CDN manifest fetch, no model download attempted)

### Root cause

The `ensure-model-cdn.yml` workflow has not run since `soprano-tts-80m` was added to the matrix. The CDN manifest does not exist. This is NOT a code regression — the Acervo strict API wiring is correct (CDN-only routing confirmed, no HuggingFace fallback).

---

## Codec Smoke: SNACTests

**Suite**: `SNACTests`  
**Command**:
```
xcodebuild test -scheme MLXAudio-Package -destination 'platform=macOS' \
  -only-testing:MLXAudioTests/SNACTests CODE_SIGNING_ALLOWED=NO
```

**Result**: FAIL (1 issue)  
**Final xcodebuild line**: `** TEST FAILED **`

### Failure

`manifestDownloadFailed(statusCode: 404)` — SwiftAcervo attempted `https://pub-8e049ed02be340cbb18f921765fd24f3.r2.dev/models/mlx-community_snac_24khz/manifest.json` and received HTTP 404.

**CDN URL observed**: `pub-8e049ed02be340cbb18f921765fd24f3.r2.dev` (correct Acervo CDN — no HuggingFace URLs)  
**HuggingFace URLs**: None observed — loader correctly routes exclusively through Acervo CDN.  
**Timing**: ~1.1 seconds (fails immediately at CDN manifest fetch)

### Root cause

Same as Soprano: `ensure-model-cdn.yml` has not run for `snac-24khz`. CDN manifest absent.

---

## Bonus probe: Qwen3-TTS Base (CDN-present model, cached locally)

Since only Qwen3-TTS variants are on CDN, a probe of `Qwen3TTSBaseModelTests` was attempted to verify the Acervo path for a CDN-present model.

**Result**: FAIL  
**Error**: `NSCocoaErrorDomain Code=257 — "The file "config.json" couldn't be opened because you don't have permission to view it."` at `/Users/stovak/Library/Group Containers/group.intrusive-memory.models/SharedModels/mlx-community_Qwen3-TTS-12Hz-1.7B-Base-bf16/config.json`

**Root cause**: The `xcodebuild test` runner resolves `Acervo.sharedModelsDirectory` to the group container path (because `FileManager.default.containerURL(forSecurityApplicationGroupIdentifier:)` succeeds — the group ID `group.intrusive-memory.models` exists), but the sandbox prevents the test runner from reading files within the group container. The model is cached there from prior app usage but is inaccessible to the test runner.

This is a secondary infrastructure blocker independent of the CDN issue.

---

## Secondary infrastructure blocker: Group Container sandbox

SwiftAcervo resolves `sharedModelsDirectory` to:
1. `Acervo.customBaseDirectory` if set
2. `containerURL(forSecurityApplicationGroupIdentifier: "group.intrusive-memory.models")/SharedModels/` if the group container is available
3. `~/Library/Application Support/SwiftAcervo/SharedModels/` as fallback

The `xcodebuild test` runner triggers path (2) because the group container exists on this machine. However, the runner's sandbox does not grant file-read access to the group container, so all model file reads fail with `Operation not permitted` (POSIX errno 1).

**Resolution required before WU7.3 can pass locally**:

Option A — Set `Acervo.customBaseDirectory` in test setup:
```swift
// In a test helper or conftest, before any fromPretrained() call:
Acervo.customBaseDirectory = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/SharedModels")
```
This bypasses the group container and uses `~/Library/SharedModels/` where models downloaded by other tools may exist.

Option B — Add group container entitlement to the test target:
Add `com.apple.security.application-groups` with value `group.intrusive-memory.models` to the test target's entitlements. This requires a signed bundle identifier registered with the App Group.

Option C — Run integration tests via a standalone Swift executable (not xcodebuild test runner), which is not sandboxed by default.

---

## STT Smoke: Deferred

**Suites not run**: `GLMASRTests`, `Qwen3ASRTests`

**Reason**: As documented in the sortie brief, `glm-asr` and `qwen3-asr` component descriptors were added in WU1 Sorties 4–5 but the `ensure-model-cdn.yml` nightly workflow has not yet run since those matrix rows were added. CDN manifests for both do not exist (HTTP 404 confirmed for all non-Qwen3-TTS models).

**What must happen before STT smoke becomes unblocked**:
1. `ensure-model-cdn.yml` must run (either via nightly schedule at midnight UTC, or via `workflow_dispatch`) and successfully upload `mlx-community_GLM-ASR-Nano-2512-4bit` and `mlx-community_Qwen3-ASR-0.6B-4bit` to the CDN.
2. The group container sandbox issue (Option A/B/C above) must also be resolved so the test runner can access downloaded models.

---

## Summary of blockers

| Blocker | Affects | Resolution |
|---|---|---|
| CDN manifests missing for soprano-tts-80m, snac-24khz (and all other non-Qwen3 models) | SopranoTTSTests, SNACTests | Run `ensure-model-cdn.yml` via `workflow_dispatch` |
| CDN manifests missing for glm-asr, qwen3-asr | GLMASRTests, Qwen3ASRTests | Same — run nightly workflow |
| `xcodebuild test` sandbox blocks group container file reads | All integration tests (even for CDN-present models) | Set `Acervo.customBaseDirectory` in test setup, or add entitlement to test target, or use non-sandboxed runner |

---

## Positive finding: Acervo CDN wiring is correct

In all test runs, SwiftAcervo correctly attempted downloads exclusively from:
- `https://pub-8e049ed02be340cbb18f921765fd24f3.r2.dev/models/{slug}/manifest.json`

Zero HuggingFace URLs (`huggingface.co`) were observed in any test output. The call-site migration (WU3–WU5) and the `loadWithAcervoStrict` wiring (WU2) are functioning correctly — the failure mode is CDN data absence and sandbox permissions, not code regression.

---

## Next steps (post-merge)

1. Trigger `ensure-model-cdn.yml` via `workflow_dispatch` to upload all missing model manifests.
2. Resolve group container sandbox access for the test runner (Option A is lowest-friction: add `Acervo.customBaseDirectory` override to a test setup file in `Tests/`).
3. Re-run WU7.3 with the full original scope: SopranoTTS + SNAC + one STT suite.
