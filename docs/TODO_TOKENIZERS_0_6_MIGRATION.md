# swift-tokenizers 0.5.0 → 0.6.0 Migration

**Status:** Not started. swift-tokenizers is currently pinned in `Package.swift` to `.upToNextMinor(from: "0.5.0")` (resolves to 0.5.0). Bump to `.upToNextMinor(from: "0.6.0")` after this checklist is complete.

**Owner:** TBD
**Last updated:** 2026-05-10

---

## Why this migration

[swift-tokenizers 0.6.0](https://github.com/DePasqualeOrg/swift-tokenizers/releases/tag/0.6.0) (PR [#29](https://github.com/DePasqualeOrg/swift-tokenizers/pull/29)) aligns the `Tokenizer` protocol with the upstream Rust crate's fallible/infallible split:

- Methods that run through the model/decoder pipeline now use **typed throws**: `throws(TokenizerError)`.
- Pure vocabulary lookups (`convertTokenToId`, `convertIdToToken`) and size queries stay infallible.
- A new `StreamingDetokenizer` is exposed via `Tokenizer.streamingDetokenizer(skipSpecialTokens:)`.
- 0.6.0 also adds Linux support (PR [#31](https://github.com/DePasqualeOrg/swift-tokenizers/pull/31)). Additive — no migration required.

The previous behaviour silently returned empty strings or `assertionFailure`d on bad input. The throwing API exposes those failures (`.invalidTokenId`, `.invalidStreamingPrefix`) at the call site.

This is a **source-breaking** change: every existing call to one of the now-throwing methods will fail to compile until `try` is added and the call chain accepts the throw.

---

## 0.6.0 API surface (target)

### Protocol methods that gain `throws(TokenizerError)`

```swift
public protocol Tokenizer: Sendable {
    func tokenize(text: String) throws(TokenizerError) -> [String]
    func encode(text: String, textPair: String?, addSpecialTokens: Bool) throws(TokenizerError) -> [Int]
    func encodeBatch(_ inputs: [(text: String, textPair: String?)], addSpecialTokens: Bool) throws(TokenizerError) -> [[Int]]
    func encodeWithMetadata(...) throws(TokenizerError) -> EncodingOutput
    func encodeBatchWithMetadata(...) throws(TokenizerError) -> [EncodingOutput]
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) throws(TokenizerError) -> String
    func applyChatTemplate(...) throws(TokenizerError) -> [Int]
    // …
}
```

### Convenience extensions (also throwing)

```swift
extension Tokenizer {
    func encode(text: String, addSpecialTokens: Bool = true) throws(TokenizerError) -> [Int]
    func encodeBatch(texts: [String], addSpecialTokens: Bool = true) throws(TokenizerError) -> [[Int]]
    func callAsFunction(_ text: String, addSpecialTokens: Bool = true) throws(TokenizerError) -> [Int]
    func decode(tokenIds: [Int]) throws(TokenizerError) -> String
}
```

### Methods that stay infallible

- `convertTokenToId(_:)`, `convertIdToToken(_:)`
- Size/property accessors (`vocabSize`, `bosTokenId`, etc.)

### New API (additive, opt-in)

- `TokenizerError` enum with cases `.invalidTokenId(Int)`, `.invalidStreamingPrefix(tokenId:expectedPrefix:actualString:)`, plus pre-existing cases.
- `StreamingDetokenizer` final class:
  ```swift
  let stream = tokenizer.streamingDetokenizer(skipSpecialTokens: true)
  for tokenId in tokens {
      if let chunk = try stream.consume(tokenId) {
          // emit chunk
      }
  }
  ```
  Useful for streaming generators currently calling `decode(tokenIds: [singleToken])` per step.

---

## Codebase usage audit (current — 0.5.0)

**Total call sites on `Tokenizers` protocol methods that gain `throws` in 0.6.0: 30**

| Method | Count | Files |
|--------|-------|-------|
| `encode(text:)` / `encode(text:addSpecialTokens:)` | 23 | Qwen3ASR, GLMASR, Qwen3TTS, Qwen3, Marvis, Soprano, LlamaTTS, Qwen3ForcedAligner |
| `decode(tokenIds:)` | 7 | Qwen3ASR (4×), GLMASR (2×), Qwen3TTS (1×) |
| `tokenize`, `encodeBatch`, `encodeWithMetadata`, `encodeBatchWithMetadata`, `applyChatTemplate` | 0 | — |

**Not affected by this migration:**
- `Sources/MLXAudioCodecs/Mimi/Mimi.swift` — imports `Tokenizers` but contains no call sites; the `import` may be removable.
- `Sources/MLXAudioTTS/Models/PocketTTS/PocketTTSTextUtils.swift` and `PocketTTSConditioners.swift` — `tokenizer.encode(...)` and `tokenizer.encodeWithByteFallback(...)` are calls against the codebase's own `SentencePieceTokenizer` / `UnigramTokenizer` types, not the upstream `Tokenizer` protocol.
- `Tests/MLXAudioTTSTests.swift` — `tokenizer.encode(...)` calls are against an audio codec (Mimi), not the text tokenizer.

---

## File-by-file checklist

### 1. `Sources/MLXAudioSTT/Models/Qwen3ASR/Qwen3ASR.swift` (5 call sites)

- [ ] **L981** — `tokenizer.encode(text: prompt)` inside `buildPrompt(numAudioTokens:language:) -> MLXArray`. Function is non-throwing — must gain `throws`.
- [ ] **L1060** — `tokenizer.decode(tokenIds: generatedTokens)` inside `generateSingleChunk(...)`. Function must gain `throws`.
- [ ] **L1128** — `tokenizer.decode(tokenIds: generatedTokens)` inside `generateSingleChunkFromAudioFeatures(...)`. Function must gain `throws`.
- [ ] **L1450** — `tokenizer.decode(tokenIds: [nextToken])` inside `_generateStreamImpl(...)` (already inside an `AsyncThrowingStream` closure). Mechanical `try` only.
- [ ] **L1527** — `tokenizer.decode(tokenIds: allGeneratedTokens)` inside `_generateStreamImpl(...)`. Mechanical `try` only.

**Signature changes propagate to callers** of `buildPrompt`, `generateSingleChunk`, and `generateSingleChunkFromAudioFeatures` — audit and update each call chain.

**Streaming opportunity:** L1450 decodes one token per loop iteration. Consider adopting `StreamingDetokenizer` here instead of the per-token `decode` loop.

### 2. `Sources/MLXAudioSTT/Models/Qwen3ASR/Qwen3ForcedAligner.swift` (1 call site)

- [ ] **L455** — `tokenizer.encode(text: expandedText)` inside `generate(audio:text:language:) -> ForcedAlignResult`. Function is non-throwing — must gain `throws`. Update all callers of `Qwen3ForcedAligner.generate`.

### 3. `Sources/MLXAudioSTT/Models/GLMASR/GLMASR.swift` (5 call sites — design issue)

- [ ] **L275** — `tokenizer.decode(tokenIds: [token])` inside `GenerationContext.decode(_ token: Int) -> String`. **Design issue** — see below.
- [ ] **L280** — `tokenizer.decode(tokenIds: tokens)` inside `GenerationContext.decode(_ tokens: [Int]) -> String`. **Design issue** — see below.
- [ ] **L891** — `tokenizer.encode(text: PromptTemplate.userPrefix)` inside `prepareGeneration(audio:tokenizer:)`. Function must gain `throws`.
- [ ] **L893** — `tokenizer.encode(text: PromptTemplate.userSuffix)` inside `prepareGeneration(audio:tokenizer:)`. Function must gain `throws`.
- [ ] **L898** — `tokenizer.encode(text: PromptTemplate.userPrefix).count` inside `prepareGeneration(audio:tokenizer:)`. Same `throws` propagation.

**`GenerationContext.decode(_:)` design issue.** Both overloads return `String` directly from a struct method. In 0.6.0 they need either:
- **Option A (preferred):** Make the methods `throws`. Audit every call chain that uses `GenerationContext.decode(...)` — if those callers run inside the generation loop, propagate `throws` upward.
- **Option B:** Pre-decode the token to `String` before storing it in the context. Removes the live tokenizer reference from the struct entirely. More invasive but eliminates the throwing-from-a-data-struct pattern.
- Pick one and apply consistently.

### 4. `Sources/MLXAudioTTS/Models/Qwen3TTS/Qwen3TTS.swift` (11 call sites — easiest file)

All call sites are already inside `throws` functions. Mechanical `try` addition only:
- [ ] L255, L262, L351 — inside `prepareICLInputs(...)`
- [ ] L1074 — inside `generateWithClonePrompt(...)`
- [ ] L1158 — inside `generateStreamWithClonePrompt(...)`
- [ ] L1255 — inside `generateWithVoiceDesign(...)`
- [ ] L1349 — inside `generateStreamWithVoiceDesign(...)`
- [ ] L1476, L1533 — inside `generateWithCustomVoice(...)`
- [ ] L1591, L1638 — inside `generateStreamWithCustomVoice(...)`

### 5. `Sources/MLXAudioTTS/Models/Qwen3/Qwen3.swift` (2 call sites — force-unwrap issue)

- [ ] **L416** — `tokenizer!.encode(text: refText)` inside `prepareInputIds(prompts:voice:refAudio:refText:) -> (MLXArray, MLXArray)`.
- [ ] **L429** — `tokenizer!.encode(text: prompt)` inside the same function.

The function is **public** and **non-throwing** — adding `throws` is a public-API breaking change for any consumer of `MLXAudioTTS`. Decide:
- Make `prepareInputIds` `throws`. Update consumers.
- *Or* drop the force-unwrap and propagate the `Optional` (`encode` requires a non-nil tokenizer; if `nil`, throw a domain-specific error from this layer).

Address the force-unwrap as part of the migration regardless — silent `assertionFailure` is exactly the failure mode 0.6.0 surfaces.

### 6. `Sources/MLXAudioTTS/Models/Llama/LlamaTTS.swift` (2 call sites — force-unwrap issue)

- [ ] **L498** — `tokenizer!.encode(text: refText)` inside `prepareInputIds(prompts:voice:refAudio:refText:)`.
- [ ] **L518** — `tokenizer!.encode(text: prompt)` inside the same function.

Same shape as Qwen3.swift — public non-throwing function with force-unwrap. Apply the same decision consistently across both.

### 7. `Sources/MLXAudioTTS/Models/Marvis/MarvisTTSModel.swift` (1 call site)

- [ ] **L111** — `_textTokenizer.encode(text: prompt)` inside `tokenizeTextSegment(text:speaker:) -> (MLXArray, MLXArray)` (private). Function must gain `throws`. Update private callers.

### 8. `Sources/MLXAudioTTS/Models/Marvis/CSMModel.swift`

Imports `Tokenizers` but the audit found no direct protocol-method call sites in this file. Verify by re-grep before declaring done; if confirmed unused, the import can be removed.

### 9. `Sources/MLXAudioTTS/Models/Soprano/Soprano.swift` (2 call sites)

- [ ] **L505** — `tokenizer.encode(text: segment, addSpecialTokens: false)` inside `tokenize(_:language:) -> MLXArray`.
- [ ] **L522** — `tokenizer.encode(text: chunk, addSpecialTokens: false)` inside the same function.

The `addSpecialTokens:` parameter is supported by the 0.6.0 `Tokenizer` extension (`encode(text:addSpecialTokens:)`), so the call shape is fine — only `try` needs to be added. The enclosing `tokenize(...)` function must gain `throws` (it's currently non-throwing). Update callers.

### 10. `Sources/MLXAudioCodecs/Mimi/Mimi.swift` (no call sites)

- [ ] Verify the `import Tokenizers` at L6 is unused and remove it.

---

## Helper / signature-propagation summary

Functions that need to gain `throws` (or change return type) as a result of the migration:

| File | Function | Visibility | Notes |
|------|----------|------------|-------|
| `Qwen3ASR.swift` | `buildPrompt(numAudioTokens:language:)` | private | Update callers |
| `Qwen3ASR.swift` | `generateSingleChunk(audio:maxTokens:temperature:language:)` | private | |
| `Qwen3ASR.swift` | `generateSingleChunkFromAudioFeatures(...)` | private | |
| `Qwen3ForcedAligner.swift` | `generate(audio:text:language:)` | public | **Public API change** |
| `GLMASR.swift` | `prepareGeneration(audio:tokenizer:)` | private | |
| `GLMASR.swift` | `GenerationContext.decode(_ token: Int)` | internal | **Design decision needed** |
| `GLMASR.swift` | `GenerationContext.decode(_ tokens: [Int])` | internal | **Design decision needed** |
| `Qwen3.swift` | `prepareInputIds(prompts:voice:refAudio:refText:)` | public | **Public API change**, address force-unwrap |
| `LlamaTTS.swift` | `prepareInputIds(prompts:voice:refAudio:refText:)` | public | **Public API change**, address force-unwrap |
| `MarvisTTSModel.swift` | `tokenizeTextSegment(text:speaker:)` | private | |
| `Soprano.swift` | `tokenize(_:language:)` | public | **Public API change** |

The four public-API changes (`Qwen3ForcedAligner.generate`, `Qwen3.prepareInputIds`, `LlamaTTS.prepareInputIds`, `Soprano.tokenize`) cascade to consumers of the `MLXAudioTTS` / `MLXAudioSTT` modules. This is what gates the 0.6.0 bump from being purely mechanical.

---

## Optional follow-ups (do not block the bump)

- Adopt `StreamingDetokenizer` in `Qwen3ASR._generateStreamImpl` (L1450) instead of the per-token `decode(tokenIds: [nextToken])` pattern. The new API rolls back state on a failed `consume`, so a partial stream stays consistent.
- Audit any tests that previously asserted `decode([invalidId])` returns `""` — under 0.6.0 the same call throws `TokenizerError.invalidTokenId(_)`. Update assertions.
- Decide whether `MLXAudio` should re-export `TokenizerError` so consumers don't need to add `import Tokenizers` just to catch the typed error.

---

## Validation plan

1. Bump `Package.swift` constraint from `.upToNextMinor(from: "0.5.0")` to `.upToNextMinor(from: "0.6.0")` once every checkbox above is ticked.
2. Run the full CI-safe test suite from `CLAUDE.md` (the `make test` block). All ~50 telemetry / module-setup / round-trip suites must compile and pass.
3. Run the local-only model-download suites that exercise the throwing path end-to-end:
   - `Qwen3ASRTests`, `GLMASRTests` — exercise `decode` on real model output.
   - `Qwen3TTSTests`, `LlamaTTSTests`, `SopranoTTSTests`, `MarvisTTSGenerateTests` — exercise `encode` on real prompts.
4. Spot-check the `_generateStreamImpl` async path for behavioural regressions (now-explicit errors that were previously silent empty strings may surface as test-visible failures even when the tokenizer is healthy).

When this file is fully checked off, ship the `Package.swift` bump as its own commit/release. The bump itself is one line; the work is everything above.
