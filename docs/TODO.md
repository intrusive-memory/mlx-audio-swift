# TODO: SwiftAcervo 0.14.0 → 0.16.0 Upgrade Audit

## Summary

- **Current pin**: SwiftAcervo `0.14.0` (`Package.swift` line 91, `Package.resolved` line 100).
- **Target**: SwiftAcervo `0.16.0`.
- **Total SwiftAcervo call sites surveyed**: 9 production files + 3 test files (`import SwiftAcervo` in 8 files; ~30 distinct API calls).
- **Areas most affected**:
  1. `Package.swift` / `Package.resolved` — pin bump.
  2. `Sources/MLXAudioCore/AudioModelManager.swift` — the central choke point, but uses only component-keyed APIs (`Acervo.register`, `Acervo.component`, `Acervo.ensureComponentReady`, `Acervo.isComponentReady`, `Acervo.modelDirectory`, `Acervo.slugify`, `AcervoManager.shared.withComponentAccess`). None of these were touched by 0.15/0.16 breaking changes.
  3. CDN-manifest publishing for the codebase's models — operational, not code.
- **Risk / ambiguity**:
  - **Low overall code risk.** The upgrade guide's *language-level* break (the new `ModelAvailability.partial` case forcing switch exhaustiveness) does NOT apply here: a repo-wide grep finds **zero** uses of `ModelAvailability`, `Acervo.availability(`, `isModelAvailable`, or `isModelConfigPresent`. The only `availability` token in the entire tree is the static-analysis attribute on Swift APIs, not the SwiftAcervo enum.
  - **`acervo ship` re-publish risk (UPGRADING.md Step 3 / TL;DR row 4).** 0.16.0 requires the wire-format `primaryRepo` and `components` fields on the CDN manifest. Any model in this repo's catalog that was last shipped with `acervo` < 0.16 will *strict-decode fail* on first fetch after the upgrade. Cached `.acervo-manifest.json` files on existing user disks are fine (the in-memory init still defaults them), but any user who has *not* yet downloaded a given model — or who deletes and re-downloads — will hit the new CDN's strict path. **This is the riskiest item.** Mitigation: re-ship every model listed in `AudioModelRepo` with `acervo ship` ≥ 0.16 before publishing the consumer upgrade.
  - **`Acervo.listModels()` validity filter (UPGRADING.md TL;DR row 6).** Not called from this codebase, so no direct break, but worth knowing if any future telemetry/diagnostic tooling is added.
  - **Filesystem anti-patterns (UPGRADING.md Step 5).** Pre-existing, NOT caused by this upgrade: three call sites enumerate `modelDir` with `FileManager.default.contentsOfDirectory(...)` to find `.safetensors` shards (`Qwen3TTS.swift:1796`, `Qwen3TTS.swift:1924`, `Qwen3.swift:loadWeights` callee, `MarvisTTSModel.swift:205`). The upgrade guide flags these as anti-patterns. They were not breaking before and will not become breaking in 0.16, but the guide's philosophy section is explicit about cleaning them up. Listed below as soft TODOs.

In short: this consumer was already tracking the most defensive end of the SwiftAcervo API surface (component-keyed only, no direct `ModelAvailability` switches, no slug-keyed APIs to migrate). The mechanical part of the upgrade is **a one-line pin bump plus a Package.resolved refresh**. Everything else is operational (re-ship models) or hygienic (clean up filesystem-poking patterns).

---

## Package.swift

- [ ] **Bump SwiftAcervo pin from `from: "0.14.0"` to `from: "0.16.0"`.**
  - File: `/Users/stovak/Projects/mlx-audio-swift/Package.swift`, line ~88–91.
  - Current shape:
    ```swift
    sibling(
      "SwiftAcervo",
      remote: "https://github.com/intrusive-memory/SwiftAcervo.git",
      from: "0.14.0"),
    ```
  - Required change: replace `from: "0.14.0"` with `from: "0.16.0"`. The `sibling(...)` helper uses `.upToNextMajor(from:)` so `0.16.0` will permit subsequent 0.16.x patch releases without further edits.
  - Driver: UPGRADING.md "Upgrading to 0.16.0" header (whole section); needed so SwiftPM resolves the new release.

## Package.resolved

- [ ] **Refresh `Package.resolved` after the pin change** so the SwiftAcervo entry points at `0.16.0`.
  - File: `/Users/stovak/Projects/mlx-audio-swift/Package.resolved`, the `"swiftacervo"` block (lines 94–102), currently pinned to `0.14.0` / revision `15fd376158be1c1d3c50a15fb8c31562034c9fc2`.
  - Required change: run `swift package update SwiftAcervo` (or `swift package resolve`) and commit the regenerated `Package.resolved`. Do not hand-edit.
  - Driver: standard SwiftPM hygiene after a `Package.swift` pin bump.

## Sources/MLXAudioCore/AudioModelManager.swift

This file is the single choke point for SwiftAcervo usage. After review, **no code changes are required for compatibility with 0.16.0** — every API touched here (`register`, `component`, `isComponentReady`, `ensureComponentReady`, `modelDirectory`, `slugify`, `AcervoManager.shared.withComponentAccess`) has unchanged signatures in 0.16 (UPGRADING.md "Step 4 — the symbol surface is the same, only the file layout under `Sources/SwiftAcervo/` changed").

- [ ] **Verify after pin bump that the file still compiles.** No edits anticipated. Lines touching SwiftAcervo:
  - `import SwiftAcervo` — line 17.
  - `Acervo.slugify(rawValue)` — lines 161, 163, 165 (Qwen3-TTS variants).
  - `Acervo.register(audioComponentDescriptors)` — line 621.
  - `Acervo.component(componentId)` — lines 857, 934, 975, 1042, 1163.
  - `Acervo.isComponentReady(componentId)` — lines 861, 1057, 1169, 1227.
  - `Acervo.ensureComponentReady(componentId[, progress:])` — lines 884, 891, 898, 1075, 1078, 1081, 1175.
  - `Acervo.modelDirectory(for:)` — lines 924, 973, 1111, 1190.
  - `AcervoManager.shared.withComponentAccess(componentId)` — line 1110.
  - Driver: UPGRADING.md Step 4 confirms the source-file decomposition is symbol-stable; this is a "do nothing, confirm" item.

- [ ] **(Soft / hygiene)** No `Acervo.availability(...)` or `ModelAvailability` consumers exist in this file, so the `.partial` case (UPGRADING.md Step 1) introduces no break here. Document this in a future Acervo-touching PR description so reviewers don't expect a switch-exhaustiveness fix.

## Sources/MLXAudioCodecs/Mimi/MimiModelManager.swift

- [ ] **Verify after pin bump.** Uses only `ComponentFile`, `ComponentDescriptor`, and `Acervo.register(_:)` (line 74). All unchanged in 0.16. No edits required.
  - Driver: UPGRADING.md Step 4 (symbol stability).

## Sources/MLXAudioCodecs/Mimi/Mimi.swift

- [ ] **Verify after pin bump.** `import SwiftAcervo` (line 7) is used indirectly through `AudioModelManager.loadWithAcervoStrict(componentId: "mimi-pytorch-bf16")` (line 570). No direct Acervo API call. No edits.

## Sources/MLXAudioCodecs/SNAC/SNACModelManager.swift

- [ ] **Verify after pin bump.** Same shape as MimiModelManager: declares `ComponentFile` + `ComponentDescriptor` + `Acervo.register(snacComponentDescriptors)` (line 77). No edits.

## Sources/MLXAudioCodecs/DACVAE/DACVAE.swift

- [ ] **Verify after pin bump.** Only touches Acervo via `AudioModelManager.loadWithAcervoStrict(componentId: "dac-vae")` (line 593). No direct Acervo API. No edits.

## Sources/MLXAudioTTS/Models/Qwen3TTS/Qwen3TTS.swift

- [ ] **Verify after pin bump.** Uses `Acervo.slugify(modelRepo)` (line 1770) and `Acervo.component(componentId)` (line 1772). Both unchanged. No edits.
- [ ] **(Soft / hygiene — UPGRADING.md Step 5 anti-pattern.)** The weight-loader closure inside `loadWithAcervoStrict` enumerates the model directory by hand:
  - Lines ~1795–1800 (talker weights): `FileManager.default.contentsOfDirectory(at: modelDir, ...)` filtered by `pathExtension == "safetensors"`.
  - Line 1924 (speech tokenizer weights): same pattern under a subdirectory `path`.
  - Replacement per the guide: iterate the manifest's `.safetensors`-suffixed entries (`manifest.files.filter { $0.path.hasSuffix(".safetensors") }`) instead of poking the filesystem. This requires plumbing the manifest down into the closure (e.g., extending `loadWithAcervoStrict` to expose the manifest, or fetching it via `Acervo.fetchManifest(for:)`).
  - Not blocking the 0.16 upgrade — these calls do not break — but the guide is explicit (Step 5 table row 1). File as a follow-up.

## Sources/MLXAudioTTS/Models/Qwen3/Qwen3.swift

- [ ] **Verify after pin bump.** Mirrors Qwen3TTS.swift: `Acervo.slugify` (line 874) + `Acervo.component` (line 876) inside `fromPretrained`. No edits.
- [ ] **(Soft / hygiene)** `loadWeights(from: modelDir)` callee (line 900) — confirm it does not enumerate the directory; if it does, same Step-5 anti-pattern note as Qwen3TTS above.

## Sources/MLXAudioTTS/Models/Marvis/MarvisTTSModel.swift

- [ ] **(Soft / hygiene — UPGRADING.md Step 5 anti-pattern.)** Lines ~204–211: enumerate `prompts/` subdirectory with `FileManager.default.contentsOfDirectory(...)` to find `.wav` audio prompts. The prompts directory is *inside* an Acervo-managed model directory, so per Step 5 it should iterate `manifest.files.filter { $0.path.hasPrefix("prompts/") && $0.path.hasSuffix(".wav") }`. Not blocking for 0.16; follow-up.

## Sources/MLXAudioCore/Telemetry/MLXAudioTelemetryEvent.swift

- [ ] **No action.** Only a doc-comment mention of "Acervo" (line 55). No API touchpoint.

## Tests/MLXAudioCodecsTests.swift

- [ ] **No action.** `ComponentDescriptorTests` (line 972 onwards) calls only `SNAC.ensureComponentsRegistered()` / `Mimi.ensureComponentsRegistered()` and inspects local enum properties; no direct SwiftAcervo API use. Switch-over-`ModelAvailability` is absent. No edits.

## Tests/MLXAudioTests/Telemetry/AudioModelManagerTelemetryTests.swift

- [ ] **Verify after pin bump.** Registers a synthetic `ComponentDescriptor(... files: [] ...)` (lines 72–82) and calls `Acervo.register(descriptor)`. Initializer signature is unchanged in 0.16. No edits.
- [ ] **No action on `isModelAvailable` fixture pattern.** UPGRADING.md Step 3 only applies to tests that write a bare `config.json` and then assert `Acervo.isModelAvailable(...) == true`. This file does neither — it uses `files: []` so `isComponentReady` short-circuits without any on-disk fixture. The whole class of test breakage described in UPGRADING.md 0.14 §Step 3 does not apply.

## Tests/MLXAudioTests/Telemetry/EndToEndTelemetryTests.swift

- [ ] **Verify after pin bump.** Same fixture shape as `AudioModelManagerTelemetryTests` (lines 91–101 register a `files: []` descriptor with `Acervo.register`). No edits.

## CDN / Operational (out-of-tree but on-mission)

- [ ] **Re-ship every model in `AudioModelRepo` (AudioModelManager.swift:26–100) with `acervo ship` ≥ 0.16.** This regenerates the CDN manifest with the now-required `primaryRepo` and `components` wire fields. Without this, any first-time download (no cached `.acervo-manifest.json` on the user's disk) against an old CDN manifest will strict-decode fail.
  - Affected slugs (15 total): `snac-24khz`, `mimi-pytorch-bf16`, `vyvo-tts-beta-4bit`, `orpheus-tts-3b`, `soprano-tts-80m`, `marvis-tts-250m-8bit`, `pocket-tts`, the three Qwen3-TTS slugs (resolved via `Acervo.slugify` of the raw HF id), `dac-vae`, `encodec-24khz`, `encodec-48khz`, `glm-asr`, `qwen3-asr`.
  - Driver: UPGRADING.md 0.16.0 "Step 3 — Audit any code that reads `CDNManifest` for `primaryRepo` / `components`" + TL;DR row 4.
  - Suggested ordering: re-ship *before* the consumer-side pin bump merges, so by the time users update SwiftAcervo, every model they may want is already living behind a 0.16-compliant manifest.

- [ ] **(Optional)** Adopt `--slug` on `acervo ship` for the Qwen3-TTS variants if their HF ids are unwieldy. The current code already calls `Acervo.slugify(rawValue)` to derive componentIds, so this is purely cosmetic — no consumer change needed.
  - Driver: UPGRADING.md 0.16.0 Step 6 (additive CLI flag).

## Docs (low priority)

- [ ] **(Optional)** Update any AGENTS.md / CLAUDE.md / docs sections that quote line ranges or file paths inside SwiftAcervo (e.g., "see `Acervo.swift:1234`"). In 0.16, `Acervo.swift` is a 51-line shell and symbols moved to `Acervo+*.swift` extensions. If any internal docs in this repo reference SwiftAcervo internals by line number, refresh them. A quick grep:
  ```
  grep -rn 'Acervo\.swift\|Sources/SwiftAcervo' /Users/stovak/Projects/mlx-audio-swift/docs /Users/stovak/Projects/mlx-audio-swift/AGENTS.md /Users/stovak/Projects/mlx-audio-swift/CLAUDE.md /Users/stovak/Projects/mlx-audio-swift/GEMINI.md 2>/dev/null
  ```
  Driver: UPGRADING.md 0.16.0 Step 4.

---

## Acceptance checklist (definition of done)

- [ ] `Package.swift` pinned to `from: "0.16.0"`.
- [ ] `Package.resolved` regenerated and committed.
- [ ] `swift build` succeeds against all targets (`MLXAudioCore`, `MLXAudioCodecs`, `MLXAudioTTS`, `MLXAudioSTT`, `MLXAudioSTS`, `MLXAudioUI`, `mlx-audio-swift-tts`).
- [ ] `swift test` succeeds for the Acervo-touching test files (`MLXAudioCodecsTests`, `AudioModelManagerTelemetryTests`, `EndToEndTelemetryTests`).
- [ ] Every model in `AudioModelRepo` has been re-shipped with `acervo ship` ≥ 0.16 (manifest carries `primaryRepo` + `components`).
- [ ] (Optional / soft) `FileManager.default.contentsOfDirectory(...)` anti-pattern follow-up filed as a separate hygiene issue.
