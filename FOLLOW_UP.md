# FOLLOW_UP.md — OPERATION ECHO DRAGNET aftermath

Five resolved decisions from the Echo Dragnet brief that need follow-up work, plus one deferred. Treat this as the seed for a single follow-up mission (~5 sorties) or, at minimum, a hot-fix PR for #1.

Source: `docs/complete/echo-dragnet-01-brief.md` § Section 3.

---

## P0 — `AudioUtils` 1024-frame round-trip truncation — **RESOLVED in `5724250`**

**Original diagnosis (Sortie 14):** silent truncation in `saveAudioArray`. Wrong.

**Actual diagnosis:** the bug was on the READ side, not the write side. `AVAudioFile.read(into:)` silently fills only part of the buffer for non-1024-aligned WAV file lengths, regardless of whether you use the 1-arg or 2-arg variant. Standalone repro confirmed:
- Hand-rolled WAV writer produces a byte-exact 145964-byte file
- `AVAudioFile.length` parses the file as 36480 frames
- `AVAudioFile.read(into:)` returns with `buffer.frameLength = 35829` despite buffer capacity 36480

**Fix (commit `5724250`):**
- Added a hand-rolled RIFF/WAVE parser as a fast path in `loadAudioArray` (`Sources/MLXAudioCore/AudioUtils.swift`). Handles Int16 PCM, Int32 PCM, IEEE float at 16/32-bit. Non-WAV containers fall back to AVAudioFile.
- `saveAudioArray` is unchanged — its output was byte-exact all along; AVAudioFile was dropping samples on read-back.
- `Tests/AudioIORoundTripTests.swift`: removed `withKnownIssue` wrapper. Asserts byte-exact sample count and full-range allclose at `atol=1e-6` on `intention.wav` round-trip.
- `make test`: 219/219 PASS.

**Carry forward:** the Sortie 14 finding's framing — "saveAudioArray silently truncates" — was a misdiagnosis that survived through the brief and into this FOLLOW_UP. The original investigator only verified the round-trip output, not which leg of it was wrong. Future bug intake should require root-cause isolation (a standalone read-side OR write-side test), not just round-trip evidence. Add this lesson to the Echo Dragnet brief's process-discoveries when next consulted.

---

## P1 — DACVAE Watermarker: channel mismatches + embed-only port — **RESOLVED (parked)**

**Decision:** Park the dead path with a fail-fast precondition. Don't fix the channel mismatches; don't port extraction; don't deprecate the types.

**Investigation findings:**
- `grep` of `Sources/`, `Tests/`, `Examples/` for `decodeWithWatermark` / `.watermark(` returns ZERO production call sites. The only references are in `Tests/DACVAEWatermarkerTests.swift` (header comments + shape tests of the watermarker types' constructors) and a comment in the test file itself.
- The watermarker **types** (`DACVAEWatermarker`, `DACVAEWatermarkEncoderBlock`, `DACVAEWatermarkDecoderBlock`) ARE referenced by `@ModuleInfo` in `DACVAEFullDecoder` — needed for weight loading. Removing them would break `DACVAE.decode`.
- The watermark **forward pass** (`DACVAEFullDecoder.watermark()` / `decodeWithWatermark` with non-nil message) is genuinely dead code: `DACVAE.decode` only calls `decoder(emb)` → `DACVAEFullDecoder.callAsFunction` (line 144), which never invokes the watermark path.

**Fix (current commit):**
- `Sources/MLXAudioCodecs/DACVAE/DACVAE.swift::DACVAEFullDecoder.decodeWithWatermark`: replaced the `if message != nil { return watermark(...) }` branch with `preconditionFailure("DACVAE watermark embedding is not yet ported — see FOLLOW_UP.md P1")`. The no-message path still works.
- `Tests/DACVAEWatermarkerTests.swift`: header comments updated. The "BUG-1 / BUG-2 not fixed" framing replaced with a "parked dead code" framing that names the precondition and points to this FOLLOW_UP entry.
- `make test`: 219/219 PASS.

**Carry forward:**
- The two channel-mismatch bugs and the missing extract path remain unfixed. They are now unreachable. Reviving the watermarker is a separate mission that requires upstream-Python parity validation and an extract port.
- The original Sortie 18 brief framed these as "production bugs" — they are NOT, because no production code reaches them. The next brief should distinguish "dead-path bug" from "live-path bug" so the urgency is clearer up front.

---

## P1 — PocketTTS Sortie-4 scope-creep audit — **RESOLVED (static audit, no behavioral change)**

**Audit verdict:** Sortie 4's additions are defensible. Leave them in place. No change to production logic; doc-only addition that records the audit trail.

**Findings:**

1. **`PocketTTSModel.sanitize(weights:)`** — strips `_`-prefix per dotted-path segment; drops keys matching `.time_embed.*.freqs`. Logic is sound on static analysis:
   - Both transformations are idempotent. Clean keys pass through unchanged.
   - The `freqs` filter is path-gated on `.time_embed.`, so unrelated `*.freqs` keys (if any exist in other modules) survive.
   - The PyTorch `_`-prefix convention is real, so the strip is the right transform if such keys ever appear.

2. **`PocketTTSModel.init(config:flowLM:mimi:)`, `SentencePieceTokenizer.init(__testStub:)`, `LUTConditioner.init(nBins:dim:outputDim:)`** — all explicitly `internal`, all labeled "Testing-only" in doc comments. The `__testStub` naming convention makes the testing-only intent visible at every call site. Standard Swift pattern when the production init requires async I/O (loading `tokenizer.json` from disk) but unit tests need synchronous in-memory construction.

**Coverage:**
- `Tests/PocketTTSModuleSetupTests.swift::sanitizeStripsUnderscorePrefixes` and `sanitizeDropsTimeEmbedFreqsKeys` already cover the structural assertions in CI.
- The local-only `PocketTTSTests` suite loads the real upstream checkpoint and runs forward passes end-to-end — any sanitize regression would surface there as a load failure or shape error. That test serves as the runtime parity check.

**Action taken:**
- Added an audit-trail doc comment to `sanitize(weights:)` recording: idempotence, gating rationale, structural test coverage in CI, runtime check via local-only suite.
- No code change to the sanitize logic or to the testing-only inits.

**Carry forward:**
- Static audit was done without an actual upstream checkpoint dump. The "is `_`-prefix actually present in the wild?" question stays unanswered, but is unfalsifiable without the file. The existing local-only suite is the runtime check.
- Process note for the next brief: when an agent invents a missing API to satisfy a test, the next sortie's first action should be a static review of the addition. The current audit took ~30 min, well below the original 1-2 hour estimate.

---

## P2 — `Qwen3ASR.mergeAudioFeatures` access change — **RESOLVED in commit follows**

- `private` → `internal` on `Qwen3ASRModel.mergeAudioFeatures(inputsEmbeds:audioFeatures:inputIds:)` at `Sources/MLXAudioSTT/Models/Qwen3ASR/Qwen3ASR.swift:760`. Doc comment added explaining the access level.
- `Tests/KVCacheCorrectnessTests.swift::qwen3ASRKVCacheCorrectness`: replaced the `try #require(Bool(false), ...)` API-gap stub with a full single-shot vs prefill+merge assertion using `MLX.allClose(rtol: 1e-4, atol: 1e-4)`. Now mirrors the LlamaTTS test pattern.
- Runtime guard switched from "stub-skip" to `MLXAUDIO_NIGHTLY_RUN=1` env-var gate (matches LlamaTTS sibling test).
- File header reframed from "API GAP FINDINGS" → "API SURFACE". Both LlamaTTS and Qwen3ASR are now PUBLIC API COMPLETE for KV-cache parity.
- `make test`: 219/219 PASS. `xcodebuild build-for-testing` exit 0.
- The runtime assertion has not yet been validated against a real Qwen3-ASR checkpoint — that's nightly + manual local work.

---

## P2 — Promote Sortie 22/23 to CI-safe via synthetic small-config harness — **TRACKED in [#19](https://github.com/intrusive-memory/mlx-audio-swift/issues/19)**

Open opportunity. Currently nightly-only — promoting to CI-safe means every PR catches autoregressive-correctness and weight-serialization regressions instead of waiting up to 24h for the nightly run.

The work, friction points, acceptance criteria, and risks are documented in issue [#19](https://github.com/intrusive-memory/mlx-audio-swift/issues/19). Estimated cost: 4-6 hours of focused work in a separate sortie. The prerequisite (P2 access change) is already done in commit `65cbf4e`.

---

## P3 — Swift resampler 48k→24k — **TRACKED in [#20](https://github.com/intrusive-memory/mlx-audio-swift/issues/20)**

Deferred. No Swift resampler exists in `Sources/`; `AVAudioConverter` covers all current I/O-boundary needs. The only forcing function is a future parity test that requires deterministic cross-Apple-platform conversion at precision below what `AVAudioConverter` guarantees. See issue [#20](https://github.com/intrusive-memory/mlx-audio-swift/issues/20) for the trigger condition and acceptance criteria.

---

## Status

All FOLLOW_UP items are now either resolved on `development` or tracked in GitHub issues. This file can be archived to `docs/complete/` (matching the `echo-dragnet-01-brief.md` / `echo-dragnet-01-plan.md` pattern) when convenient.
