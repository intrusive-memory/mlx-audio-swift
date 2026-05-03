---
title: "mlx-audio-swift — Tokenizer Package Migration (swift-transformers → swift-tokenizers-mlx)"
date: 2026-04-21
supersedes: "REQUIREMENTS.md v3.0 (2026-04-20)"
version: "4.0"
status: "READY FOR EXECUTION"
---

# mlx-audio-swift — Tokenizer Package Migration

## Goal

Replace `huggingface/swift-transformers` with `DePasqualeOrg/swift-tokenizers-mlx` (Swift trait only) to match SwiftBruja's pattern. Eliminate the duplicate-`Tokenizers`-module collision that occurs when both libraries are composed into the same app, and drop the Rust tokenizer xcframework from the build.

Three outcomes, one branch off `development`:

1. **Swap the tokenizer package.** Drop `swift-transformers`; add `swift-tokenizers-mlx` (primary) and `swift-tokenizers` (for the `Tokenizers` module access used by existing call sites). Both with trait `["Swift"]` — no Rust backend.
2. **Migrate all `AutoTokenizer.from(modelFolder:)` call sites** to `AutoTokenizer.from(directory:)`. 10 sites across TTS/STT models.
3. **Close out v3.0's leftover items:** Migrate the 6 remaining `tokenizer.decode(tokens:)` call sites to `decode(tokenIds:)`.

## Non-Goals

- Replacing `AutoTokenizer.from(directory:)` with the higher-level `LLMModelFactory.loadContainer(from:)` convenience pattern that SwiftBruja uses. That's a follow-up refactor — this pass preserves the current explicit-tokenizer-loading pattern to keep the diff narrow and reviewable.
- Introducing any SwiftAcervo-side changes. SwiftAcervo 0.7.2 stays pinned.
- Re-opening any v3.0 decisions (SwiftAcervo v2 adoption, `mlx-swift-lm` 3.x bump, `swift-huggingface` removal). Those are locked in.
- Bumping `mlx-swift` / `mlx-swift-lm` / SwiftAcervo / Apple deps. Nothing except the tokenizer swap changes here.

---

## Motivation

SwiftBruja and mlx-audio-swift are both consumed by downstream apps (Produciesta, et al.). Today they use different tokenizer packages that each vend a module named `Tokenizers`:

| Library | Package | `Tokenizers` module source | Rust xcframework |
|---|---|---|---|
| SwiftBruja | `DePasqualeOrg/swift-tokenizers-mlx` (+ transitive `swift-tokenizers` via `Swift` trait) | `DePasqualeOrg/swift-tokenizers` | No |
| mlx-audio-swift (today) | `huggingface/swift-transformers` | `huggingface/swift-transformers` | Yes |

Any app consuming both hits a module-name collision in SPM — the `Tokenizers` module is claimed by two unrelated package URLs. Even if SPM resolves by precedence, the `Tokenizer` *types* end up different between the two libraries, breaking any cross-library type handoff at the `MLXLMCommon` boundary. The Rust xcframework also creeps back in via `swift-transformers`, defeating SwiftBruja's explicit `Swift` trait choice.

SwiftBruja already declared this direction in its Package.swift comment: *"Tokenizer adapter for mlx-swift-lm 3.x (replaces bundled swift-transformers dep). Explicit Swift trait avoids pulling the Rust backend (binary xcframework)."*

v3.0's Risk Ledger flagged this as follow-up work: *"swift-transformers is still a direct dep even though mlx-swift-lm 3.x dropped it. We keep it for AutoTokenizer. If a cleaner alternative emerges (e.g. SwiftAcervo ships a tokenizer loader), swift-transformers becomes a removal candidate in a follow-up — not this pass."*

This is that pass.

---

## Target Dependency Versions

| Package | Current | Target | Rationale |
|---|---|---|---|
| `huggingface/swift-transformers` | 1.3.0 | **REMOVED** | Replaced by DePasqualeOrg fork via `swift-tokenizers-mlx`. |
| `DePasqualeOrg/swift-tokenizers-mlx` | — | **0.2.0** (trait `Swift`) | MLX bridge layer; matches SwiftBruja. |
| `DePasqualeOrg/swift-tokenizers` | — | **0.3.2** (trait `Swift`) | Transitively required by `swift-tokenizers-mlx`; declared directly for explicit `Tokenizers` product access. |
| `ml-explore/mlx-swift` | 0.31.3 | **0.31.3** (unchanged) | Hold. |
| `ml-explore/mlx-swift-lm` | 3.31.3 | **3.31.3** (unchanged) | Hold. |
| `intrusive-memory/SwiftAcervo` | 0.7.2 | **0.7.2** (unchanged) | Hold. |
| `apple/swift-numerics` | 1.1.1 | **1.1.1** (unchanged) | Hold. |
| `apple/swift-collections` | 1.4.1 | **1.4.1** (unchanged) | Hold. |
| `apple/swift-crypto` | 4.4.0 | **4.4.0** (unchanged) | Hold. |
| `ibireme/yyjson` | 0.12.0 | **0.12.0** (unchanged) | Hold. |

## Package.swift Target State — dependencies block

```swift
dependencies: [
    .package(url: "https://github.com/ml-explore/mlx-swift.git", .upToNextMajor(from: "0.31.3")),
    .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", .upToNextMajor(from: "3.31.3")),

    // Tokenizer adapter for mlx-swift-lm 3.x (replaces swift-transformers).
    // Explicit Swift trait avoids pulling the Rust backend (binary xcframework).
    .package(
        url: "https://github.com/DePasqualeOrg/swift-tokenizers-mlx",
        .upToNextMajor(from: "0.2.0"),
        traits: ["Swift"]
    ),
    // Direct declaration of the fork that backs swift-tokenizers-mlx so the
    // `Tokenizers` product is available to target dependencies that still call
    // `AutoTokenizer.from(directory:)` directly.
    .package(
        url: "https://github.com/DePasqualeOrg/swift-tokenizers.git",
        .upToNextMajor(from: "0.3.2"),
        traits: ["Swift"]
    ),

    .package(url: "https://github.com/intrusive-memory/SwiftAcervo.git", .upToNextMajor(from: "0.7.2")),

    // Transitive dependencies for Xcode 26 compatibility
    .package(url: "https://github.com/apple/swift-numerics", .upToNextMajor(from: "1.1.1")),
    .package(url: "https://github.com/apple/swift-collections.git", .upToNextMajor(from: "1.4.1")),
    .package(url: "https://github.com/apple/swift-crypto.git", .upToNextMajor(from: "4.4.0")),
    .package(url: "https://github.com/ibireme/yyjson.git", .upToNextMajor(from: "0.12.0")),
],
```

### Target-level product swaps

In the `MLXAudioTTS` and `MLXAudioSTT` target blocks:

```swift
// REMOVE:
.product(name: "Transformers", package: "swift-transformers"),

// ADD:
.product(name: "MLXLMTokenizers", package: "swift-tokenizers-mlx"),
.product(name: "Tokenizers", package: "swift-tokenizers"),
```

`MLXAudioCore`, `MLXAudioCodecs`, `MLXAudioSTS`, `MLXAudioUI`, and `mlx-audio-swift-tts` do not currently depend on `Transformers` and do not need changes.

---

## API Changes

### `AutoTokenizer.from(modelFolder:)` → `AutoTokenizer.from(directory:)`

The DePasqualeOrg fork renamed the argument label. The return type (`any Tokenizer`) and async-throws signature are unchanged. No logic changes — argument label only.

```swift
// Before (swift-transformers 1.3.0):
model.tokenizer = try await AutoTokenizer.from(modelFolder: modelDir)

// After (swift-tokenizers 0.3.2):
model.tokenizer = try await AutoTokenizer.from(directory: modelDir)
```

The fork's signature is `static func from(directory: URL, strict: Bool = true) async throws -> Tokenizer` — `strict` defaults to `true`, matching the intent of the current call sites.

### `tokenizer.decode(tokens:)` → `tokenizer.decode(tokenIds:)`

Carried over from v3.0's acceptance checklist (not yet executed). The `Tokenizer` protocol's decode method uses `tokenIds:` in both `swift-transformers` 1.3.0 and `swift-tokenizers` 0.3.2. These sites are stale regardless of the package swap.

### `import Tokenizers`

Source-level import statement stays `import Tokenizers`. The module name is the same; only the backing package URL changes. No source edit required for imports.

---

## File-Level Change Plan

### `Package.swift` — one file, one block

- Remove `.package(url: "huggingface/swift-transformers", ...)`.
- Add `.package(url: "DePasqualeOrg/swift-tokenizers-mlx", ..., traits: ["Swift"])`.
- Add `.package(url: "DePasqualeOrg/swift-tokenizers", ..., traits: ["Swift"])`.
- In `MLXAudioTTS` target: swap `.product(name: "Transformers", ...)` for `.product(name: "MLXLMTokenizers", ...)` + `.product(name: "Tokenizers", ...)`.
- In `MLXAudioSTT` target: same swap.

### `AutoTokenizer.from(modelFolder:)` call sites — 10 files

| File | Line | Action |
|---|---|---|
| `Sources/MLXAudioSTT/Models/GLMASR/GLMASR.swift` | 634 | `modelFolder:` → `directory:` |
| `Sources/MLXAudioSTT/Models/Qwen3ASR/Qwen3ForcedAligner.swift` | 577 | `modelFolder:` → `directory:` |
| `Sources/MLXAudioSTT/Models/Qwen3ASR/Qwen3ASR.swift` | 1594 | `modelFolder:` → `directory:` |
| `Sources/MLXAudioTTS/Models/Llama/LlamaTTS.swift` | 586 | `modelFolder:` → `directory:` |
| `Sources/MLXAudioTTS/Models/Qwen3/Qwen3.swift` | 521 | `modelFolder:` → `directory:` |
| `Sources/MLXAudioTTS/Models/Soprano/Soprano.swift` | 903 | `modelFolder:` → `directory:` |
| `Sources/MLXAudioTTS/Models/Marvis/MarvisTTSModel.swift` | 63 | `modelFolder:` → `directory:` |
| `Sources/MLXAudioTTS/Models/Marvis/MarvisTTSModel.swift` | 190 | `modelFolder:` → `directory:`. Also update the `// swift-transformers 1.3.0 API (...)` comment at line 189 to reference `swift-tokenizers 0.3.2`. |
| `Sources/MLXAudioTTS/Models/Qwen3TTS/Qwen3TTS.swift` | 1703 | `modelFolder:` → `directory:` |

**Discovery command (run before and after to confirm zero leftovers):**

```bash
grep -rn "AutoTokenizer\.from(modelFolder:" Sources Tests
```

Expect 0 matches after migration.

### `tokenizer.decode(tokens:)` call sites — 2 files, 6 sites

| File | Lines | Action |
|---|---|---|
| `Sources/MLXAudioSTT/Models/GLMASR/GLMASR.swift` | 275, 280 | `tokens:` → `tokenIds:` |
| `Sources/MLXAudioSTT/Models/Qwen3ASR/Qwen3ASR.swift` | 1014, 1073, 1290, 1362 | `tokens:` → `tokenIds:` |

**Discovery command:**

```bash
grep -rn "\.decode(tokens:" Sources Tests
```

Expect 0 matches after migration.

### Documentation comment refreshes

Any prose comment referencing `swift-transformers` should be updated to reference `swift-tokenizers` / `swift-tokenizers-mlx`. Known hit:

- `Sources/MLXAudioTTS/Models/Marvis/MarvisTTSModel.swift:189` — comment block above the `AutoTokenizer` call.

**Discovery command:**

```bash
grep -rn "swift-transformers" Sources Tests docs
```

Treat each hit individually — some may be historical context in `docs/complete/` that should stay as-is. Source comments under `Sources/` should be updated or removed.

---

## Testing Requirements

- **Unit tests (no downloads):** Full unit test suite (per `CLAUDE.md` test list) must pass on `macos-26` after the swap. Zero network access required.
- **Integration tests (require downloads):** At least one TTS model (Marvis or Soprano), one STT model (Qwen3ASR or GLMASR), and one codec must successfully load their tokenizer via `AutoTokenizer.from(directory:)` against a real downloaded component. The tokenizer instance must be `any Tokenizer` (the protocol from `Tokenizers` module) — verify at runtime that encode/decode round-trip a known prompt.
- **Composed-consumer smoke (manual, one-time):** In a scratch directory, create an SPM package that depends on both SwiftBruja and mlx-audio-swift at their respective post-merge SHAs. `swift package resolve` must succeed with no duplicate-module diagnostic and `swift build` must link without `Tokenizers` ambiguity. This is the acceptance test for the motivation — do not skip.
- **Tokenizer golden outputs:** If any test snapshots compare rendered chat templates, re-record. The DePasqualeOrg fork and huggingface/swift-transformers share the same upstream `PreTrainedTokenizer.applyChatTemplate` logic (both track HF Python tokenizers), but whitespace defaults may drift between forks. Verify.
- **CI:** No workflow changes expected. Required status checks under branch protection stay as-is.

---

## Risk Ledger (candid)

- **Not using `swift-tokenizers-mlx`'s `LLMModelFactory.loadContainer(from:)` convenience.** SwiftBruja uses that wrapper and doesn't call `AutoTokenizer` directly at all. mlx-audio-swift has 10 explicit `AutoTokenizer.from(...)` sites with model-specific logic around them (custom vocab handling, speaker tokenizer construction, etc.). Refactoring to the convenience form is a larger change that would obscure the package-swap diff; explicitly deferred to a future cleanup pass. The cost is that the two libraries look stylistically different for a while.

- **Adding `swift-tokenizers` as a direct package dep is a slight duplication.** It's already a transitive dep of `swift-tokenizers-mlx`. Declaring it directly is for explicit `.product(name: "Tokenizers", ...)` access at the target level. If SPM complains about the duplicate package declaration under Swift 6.2's stricter resolver, drop the direct declaration and rely on the transitive `Tokenizers` module being in the build graph via `MLXLMTokenizers`. Test this during execution.

- **Trait composition in transitive packages.** `swift-tokenizers-mlx` declares its `swift-tokenizers` dependency with conditional traits (`Swift` enables `Swift`, `Rust` enables `Rust`). If we ALSO declare `swift-tokenizers` directly with `traits: ["Swift"]`, the resolver must unify. Expected behavior: both paths agree on `Swift` trait, no Rust xcframework is pulled. If the resolver instead unions traits, the Rust binary creeps back in and defeats the whole exercise. **Verification step:** after `swift package resolve`, check `.build/` for any `*.xcframework` directory under a tokenizer-related checkout. Presence = failure; revisit trait declarations.

- **Fork drift between DePasqualeOrg/swift-tokenizers and huggingface/swift-transformers.** The DePasqualeOrg fork tracks upstream but is not a byte-identical mirror. Any tokenizer that depends on undocumented or edge-case HF behavior may produce subtly different outputs. Unit tests for existing models should catch this, but custom vocab models (VyvoTTS, Marvis) warrant a manual encode/decode round-trip check.

- **Composed-consumer smoke test is load-bearing.** The entire justification for this migration is composition with SwiftBruja. If the smoke test fails, the migration doesn't actually solve the problem and should not merge. Do not waive this test even under time pressure.

---

## Acceptance Checklist

- [ ] `Package.swift` removes `huggingface/swift-transformers`; adds `swift-tokenizers-mlx` (0.2.0, `Swift` trait) and `swift-tokenizers` (0.3.2, `Swift` trait).
- [ ] `MLXAudioTTS` and `MLXAudioSTT` target deps swap `Transformers` for `MLXLMTokenizers` + `Tokenizers`.
- [ ] Zero matches for `grep -rn "swift-transformers" Package.swift`.
- [ ] Zero matches for `grep -rn "AutoTokenizer\.from(modelFolder:" Sources Tests`.
- [ ] Zero matches for `grep -rn "\.decode(tokens:" Sources Tests`.
- [ ] `.build/` contains no Rust tokenizer xcframework after `swift package resolve`.
- [ ] All safe-to-run unit tests (per `CLAUDE.md` test list) pass on `macos-26`.
- [ ] Integration tests pass for at least one TTS, one STT, and one codec model with the new tokenizer path.
- [ ] Composed-consumer smoke test: a scratch SPM package depending on both SwiftBruja and mlx-audio-swift resolves and builds without duplicate-`Tokenizers` diagnostics.
- [ ] Source comments referencing `swift-transformers` under `Sources/` updated or removed.
- [ ] `docs/complete/REQUIREMENTS_V3_TOKENIZER_FOLLOWUP.md` — v3.0 is archived here once v4.0 merges (or left at `REQUIREMENTS.md` git history; decide at merge time).

---

**Status:** READY FOR EXECUTION. Single branch off `development`. Narrow, mechanical diff — should be reviewable in one sitting.
