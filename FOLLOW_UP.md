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

## P1 — PocketTTS Sortie-4 scope-creep audit

**Status:** open (unaudited production code in main)
**Blast radius:** If the agent-invented sanitize semantics are wrong, every PocketTTS load silently corrupts weights.
**Evidence:** Sortie 4 commit `66c7db7` added a `sanitize(weights:)` impl + testing-only `internal` inits to `Sources/MLXAudioTTS/Models/PocketTTS/PocketTTSModel.swift` and `Sources/MLXAudioTTS/Models/PocketTTS/PocketTTSConditioners.swift`. The plan asserted `sanitize` existed. It didn't. The agent wrote one. Defensible at a glance (strips `_`-prefixed PyTorch keys, drops computed `freqs` buffer keys), but not reviewed against an upstream checkpoint.

### TODO

- [ ] Download an upstream PocketTTS PyTorch checkpoint (HF or wherever upstream publishes). Dump the raw key list: `python -c "import safetensors.torch; from safetensors import safe_open; f = safe_open('checkpoint.safetensors', framework='pt'); print('\n'.join(f.keys()))"`.
- [ ] Compare against the Swift `sanitize(weights:)` transformations:
  - [ ] `_`-prefix stripping: do the upstream keys actually begin with `_`? Confirm or refute.
  - [ ] `freqs` buffer dropping: confirm `freqs` is a computed (non-learned) buffer in PyTorch, not a learned param the Swift port needs.
  - [ ] Casing rules: any snake_case → camelCase conversions? Verify each one.
- [ ] Run a forward-pass parity test: load upstream weights via `sanitize`, run a fixed input through Swift, compare to upstream Python output at `atol: 1e-3` (use the existing parity-fixture pattern from Sortie 1+2).
- [ ] **If audit passes:** leave the diff. Add a comment in `sanitize` referencing this audit + the checkpoint hash that validated it.
- [ ] **If audit fails:** revert the sortie-4 production edits. Re-author with explicit human spec. File a separate sortie for that.

**Cost:** 1-2 hours.
**Model:** sonnet — needs to read both PyTorch and Swift carefully.

---

## P2 — `Qwen3ASR.mergeAudioFeatures` access change

**Status:** trivial; one-token change unlocks Sortie 22's STT branch
**Blast radius:** None on production. Currently `private`; testing of KV-cache correctness on the STT path is stub-skipped (`Tests/KVCacheCorrectnessTests.swift`).

### TODO

- [ ] Find `mergeAudioFeatures` in `Sources/MLXAudioSTT/...` (likely `Qwen3ASR.swift` or sibling). Change `private` → `internal`.
- [ ] In `Tests/KVCacheCorrectnessTests.swift` — restore the full STT assertion. The test target uses `@testable import MLXAudioSTT`, which gives access to `internal` symbols. No public surface added.
- [ ] Run `xcodebuild build-for-testing -scheme MLXAudio-Package -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO` to verify the test compiles.
- [ ] Update the test header comment to remove the "PARTIAL — API gap" note.

**Cost:** 5-10 min.
**Model:** haiku — well-defined, single-token change with verification.

---

## P2 — Promote Sortie 22/23 to CI-safe via synthetic small-config harness

**Status:** open opportunity
**Blast radius:** Currently nightly-only. Promoting to CI-safe means every PR catches autoregressive-correctness and weight-serialization regressions, not just the nightly run on `mlx-models-v2` cache.

### TODO

- [ ] Author a tiny synthetic LlamaTTS config in a new test helper `Tests/Helpers/SyntheticConfigs.swift`:
  - [ ] `numLayers: 1`, `hiddenSize: 32`, `numHeads: 4`, `vocabSize: 256`.
  - [ ] Random init via `MLXRandom.normal(shape:)` with a fixed `MLXRandom.seed(42)`.
  - [ ] Verify forward pass on a 16-token sequence runs in <1s on macOS.
- [ ] Same pattern for Qwen3ASR: tiny config + synthetic mel-spectrogram input.
- [ ] In `Tests/KVCacheCorrectnessTests.swift`:
  - [ ] Add a synthetic-harness test that runs at every CI invocation (no `MLXAUDIO_NIGHTLY_RUN=1` gate).
  - [ ] Keep the full-model variant gated on the env flag.
- [ ] Same pattern for `Tests/WeightRoundTripTests.swift`.
- [ ] Wire both synthetic-harness tests into the CI-safe `make test` block in `CLAUDE.md`.
- [ ] Verify total CI-safe `make test` wall time stays under reasonable budget (target: synthetic harness adds <60s).

**Cost:** 2-4 hours.
**Model:** sonnet.

---

## P3 — Swift resampler 48k→24k — defer until forced

**Status:** deferred (no current blocker)
**Rationale:** No Swift resampler exists in `Sources/`. Sortie 16 documented this with `resample48to24kIsNotYetImplemented`. `AVAudioConverter` covers any I/O-boundary need today. The only forcing function for a Swift impl is a future parity test that requires deterministic, cross-Apple-platform sample-rate conversion at numerical precision below what `AVAudioConverter` guarantees.

### TODO

- [ ] File a tracking issue (GitHub) titled "Swift 48k→24k resampler — implement when first parity test forces it." Link to:
  - `Tests/MLXAudioCoreDSPTests.swift::resample48to24kIsNotYetImplemented`
  - `docs/complete/echo-dragnet-01-brief.md` § Section 3, item 4
- [ ] No code change. Close this entry as deferred.

**Cost:** 5 min.
**Model:** N/A (admin task).

---

## Suggested mission shape

Package P0–P2 (5 entries) as a single follow-up mission. P3 is admin and can be done in passing.

| Sortie | Task | Model | Est. cost |
|--------|------|-------|-----------|
| 1 | AudioUtils saveAudioArray flush fix + assertion re-enable | sonnet | 30 min – 2 hr |
| 2 | DACVAE Watermarker: grep callers, fix-or-deprecate | sonnet | 30-90 min |
| 3 | PocketTTS sanitize audit against upstream checkpoint | sonnet | 1-2 hr |
| 4 | Qwen3ASR private→internal + restore KV-cache STT assertion | haiku | 10 min |
| 5 | Synthetic-config harness; promote KV/weight-RT to CI-safe | sonnet | 2-4 hr |

Total: half a day to a full day of agent time. Sorties 1–4 are independent; Sortie 5 stands alone. No dependency layering needed beyond Sortie 4 → Sortie 5 (the synthetic harness benefits from but doesn't strictly require the access change).

P0 can ship as a standalone hot-fix PR before the rest of the mission starts if the AudioUtils truncation is causing immediate consumer pain.

---

## Mission-naming note

Per the mission-supervisor `name-feature` ritual, the next mission gets its own operation name (NOT "Echo Dragnet 02" — that would be an iteration of the same scope, but this is new follow-up work). When ready to start: `/mission-supervisor breakdown FOLLOW_UP.md`.
