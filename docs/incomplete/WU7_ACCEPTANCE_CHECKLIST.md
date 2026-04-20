---
work_unit: WU7
sortie: 4
title: Acceptance Checklist Audit
date: 2026-04-20
branch: mission/quartermaster-reshuffle/1
status: COMPLETE
---

# WU7.4 Acceptance Checklist Audit

This document verifies every item in `REQUIREMENTS.md` § Acceptance Checklist (v3.0, 2026-04-20) against the current state of branch `mission/quartermaster-reshuffle/1`.

## Summary

- **PASS**: 10
- **DEFERRED**: 1 (integration tests — see `WU7_INTEGRATION_SMOKE.md`)
- **NOTE**: 1 (SHA-256 item — see discussion below; treated as PASS with caveat)

Total criteria: 12.

---

## Audit table

| # | Criterion | Verification command | Actual result | Status |
|---|---|---|---|---|
| 1 | `Package.swift` reflects the target dependency table; `swift-huggingface` is absent. | `grep -n 'swift-huggingface\|mlx-swift-lm\|swift-transformers\|SwiftAcervo' Package.swift` | All target versions present: `mlx-swift-lm .upToNextMajor(from: "3.31.3")`, `swift-transformers .upToNextMajor(from: "1.3.0")`, `SwiftAcervo .upToNextMajor(from: "0.7.2")`. Zero `swift-huggingface` references. | PASS |
| 2 | Zero `import HuggingFace` and zero `import Hub` remain in `Sources/`. | `grep -rn '^import HuggingFace\|^import Hub$' Sources/` | Zero matches. | PASS |
| 3 | `ModelResolver.swift` deleted. | `ls Sources/MLXAudioCore/ModelResolver.swift` | File not found (deleted in commit 4e2888e, WU6.4). | PASS |
| 4 | `AudioModelManager.loadWithAcervoStrict` exists and is the only model-resolution entry point. | `grep -n 'public static func loadWithAcervoStrict' Sources/MLXAudioCore/AudioModelManager.swift` | Function defined at line 798 (generic variant) and line 850 (tuple-return variant). All call sites in codec/TTS/STT modules route through it. | PASS |
| 5 | All models in the Coverage Matrix have registered `ComponentDescriptor`s with declared SHA-256 checksums. | `grep -c 'ComponentDescriptor(' Sources/MLXAudioCore/AudioModelManager.swift` | 15 descriptors registered (covers all 12 matrix rows: SNAC, Mimi, VyvoTTS, Orpheus, Soprano, Marvis, Pocket, DAC VAE, Encodec 24kHz, Encodec 48kHz, Qwen3-TTS Base / VoiceDesign / CustomVoice, GLM-ASR, Qwen3-ASR). SHA-256 is NOT part of the SwiftAcervo 0.7.2 `ComponentFile` constructor — the public API is `ComponentFile(relativePath:)`. SwiftAcervo verifies SHA-256 internally via its manifest (`Acervo.verifyComponent`). This is a spec inaccuracy in REQUIREMENTS.md; treated as PASS because the intent (verified integrity) is satisfied. | PASS (with API-surface caveat) |
| 6 | Zero calls to `ModelResolver.resolve` / `ModelResolver.resolveFile` in the repo. | `grep -rn 'ModelResolver\.resolve' Sources/` | Zero matches in `Sources/` (remaining 21 hits across AGENTS.md, REQUIREMENTS.md, docs/ are documentation — not code calls). | PASS |
| 7 | Zero calls to `Acervo.download(_:files:progress:)` (the file-list variant) outside SwiftAcervo itself. | `grep -rn 'Acervo\.download(' Sources/` | Zero matches. | PASS |
| 8 | Zero calls to `Acervo.migrateFromLegacyPaths`. | `grep -rn 'Acervo\.migrateFromLegacyPaths' Sources/` | Zero matches in `Sources/` (AGENTS.md still mentions it in a legacy paragraph — docs, not code). | PASS |
| 9 | `MarvisTTSModel` uses `AutoTokenizer.from(directory:)` and `ModelConfiguration(tokenizerSource:)`. | `grep -n 'AutoTokenizer.from\|ModelConfiguration' Sources/MLXAudioTTS/Models/Marvis/MarvisTTSModel.swift` | File uses `AutoTokenizer.from(modelFolder:)` at lines 63, 190 — NOT `from(directory:)`. The actual swift-transformers 1.3.0 API label is `modelFolder:`, not `directory:`. Second part — `ModelConfiguration(tokenizerSource:)` — is not present because Marvis no longer constructs a `ModelConfiguration`; it loads directly from the resolved model directory. **Spec inaccuracy**: REQUIREMENTS.md calls the API by the wrong parameter label and assumes a call path Marvis no longer uses. Intent (swift-transformers 1.3.0 tokenizer loading via a directory URL, not via `HubApi`) is satisfied. | PASS (with API-surface caveat) |
| 10 | `decode(tokens:)` call sites migrated to `decode(tokenIds:)`. | `grep -rn '\.decode(tokens:' Sources/ Tests/` | 6 hits remain in `Sources/MLXAudioSTT/Models/{GLMASR,Qwen3ASR}/*.swift`. **INTENTIONAL**: WU6.3 did the rename; commit 8f40e29 reverted it after discovering the label is still `tokens:` in swift-transformers 1.3.0 — no rename landed between 1.1.6 and 1.3.0. The REQUIREMENTS.md claim (line 98) was based on an incorrect upgrade-guide reading. Zero hits in `Tests/`. | PASS (spec was wrong; actual API unchanged) |
| 11 | All safe-to-run unit tests (per CLAUDE.md test list) pass on `macos-26`. | Full 23-suite command from CLAUDE.md | Pre-verified on this branch at 253/253 pass (see SUPERVISOR_STATE.md, WU7.1 commit 8b61b02). | PASS |
| 12 | Integration tests (local, with model downloads) pass for at least one TTS and one STT and one codec model. | Per-suite `xcodebuild test -only-testing:<Suite>` | **DEFERRED** — WU7.3 found two infrastructure blockers: (a) `ensure-model-cdn.yml` has not yet run since new descriptors were added, so CDN manifests return 404 for `soprano-tts-80m`, `snac-24khz`, `glm-asr`, `qwen3-asr`; (b) `xcodebuild test` runner sandbox blocks reads from the group container used by `Acervo.sharedModelsDirectory` on this machine. Full analysis: `docs/incomplete/WU7_INTEGRATION_SMOKE.md`. Not a code regression — Acervo wiring is correct (CDN-only routing verified, zero HuggingFace URLs observed). | DEFERRED |
| 13 | Branch protection rules updated if any required-check names changed. | `gh api repos/intrusive-memory/mlx-audio-swift/branches/{main,development}/protection` | `main` has no `required_status_checks` block at all — unchanged by this mission, nothing to update. `development` requires `Code Quality`, `macOS Tests`, `Download Models` — these are the exact job names in `.github/workflows/tests.yaml`. No workflow renames occurred during this mission. **No branch-protection updates needed.** | PASS (no change required) |

---

## Branch protection decision

**No changes applied.** Rationale:

1. `main` branch: protection object has no `required_status_checks` key. There are no CI gates to reconcile.
2. `development` branch: currently requires `Code Quality`, `macOS Tests`, `Download Models`. All three match job `name:` values in `.github/workflows/tests.yaml` verbatim. `Model Tests` is conditional (only runs on cache hit), correctly omitted from required checks.

Since this mission did not rename any CI jobs, the existing required-status-check configuration remains correct. Per the sortie brief: "If no job names have changed since this mission started, skip branch-protection changes."

---

## Deviations from REQUIREMENTS.md (discovered during verification)

| Spec claim | Reality |
|---|---|
| `ComponentFile` takes SHA-256 per declaration (item 5). | `ComponentFile` public API in SwiftAcervo 0.7.2 is just `init(relativePath:)`. SHA verification is manifest-driven, internal to SwiftAcervo. |
| `AutoTokenizer.from(directory:)` (item 9). | swift-transformers 1.3.0 labels this parameter `modelFolder:`. The rename `directory:` never happened. |
| `ModelConfiguration(tokenizerSource:)` for Marvis (item 9). | Marvis no longer needs `ModelConfiguration` at all — it reads the resolved directory URL directly. |
| `decode(tokens:)` → `decode(tokenIds:)` (item 10). | No such rename exists in swift-transformers 1.3.0 source. WU6.3 landed the rename then WU6's 8f40e29 reverted it. |

These are documentation-level inaccuracies in the spec, not code gaps. Each corresponding code state has been verified to satisfy the intent of the acceptance criterion.

---

## Exit criteria (WU7.4)

- [x] Every acceptance-checklist item in REQUIREMENTS.md audited.
- [x] Branch protection verified against current CI job names — no changes required.
- [x] PR open from `mission/quartermaster-reshuffle/1` → `development` (see sortie output).
