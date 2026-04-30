# FOLLOW_UP.md — OPERATION ECHO DRAGNET aftermath

Five resolved decisions from the Echo Dragnet brief that need follow-up work, plus one deferred. Treat this as the seed for a single follow-up mission (~5 sorties) or, at minimum, a hot-fix PR for #1.

Source: `docs/complete/echo-dragnet-01-brief.md` § Section 3.

---

## P0 — `AudioUtils.saveAudioArray` silent 1024-sample truncation

**Status:** open
**Blast radius:** Every caller of the public audio-save API loses up to ~42 ms of trailing audio (≤1023 samples short of the next 1024-frame boundary). Silent. No error, no warning.
**Evidence:** `Tests/AudioIORoundTripTests.swift:28-42`. `intention.wav` 36480 → 35840 samples (= 35×1024) on round-trip.
**Likely cause:** `AVAudioFile`'s internal 1024-frame I/O buffer doesn't flush its trailing partial buffer before ARC releases the local `let audioFile` in `Sources/MLXAudioCore/AudioUtils.swift:66-86`. The same project's `StreamingWAVWriter.finalize()` (line 145) already uses `audioFile = nil` to force this — the pattern just wasn't applied to the one-shot variant.

### TODO

- [ ] Reproduce with the existing `intentionWav_loadSaveReload_float32Allclose` test by removing the `withKnownIssue` wrapper.
- [ ] Try the 1-line fix: change `let audioFile` → `var audioFile` and add `audioFile = nil` after `try audioFile.write(from: buffer)` in `Sources/MLXAudioCore/AudioUtils.swift:66`. Re-run the round-trip test and assert `MLX.allclose(atol: 1e-6)` on byte counts AND samples.
- [ ] **If the 1-line fix doesn't make round-trip byte-exact**, replace `AVAudioFile` with a direct WAV writer using `Data` + RIFF header (~50 lines). The existing `loadAudioArray` parses raw WAV — use it as a format reference.
- [ ] Remove `withKnownIssue` from `Tests/AudioIORoundTripTests.swift`. Convert the documented finding-comment into a confirmation that it's fixed.
- [ ] Run `make test` — should still be 219+/total PASS.

**Cost:** 30 min for the 1-line attempt, +1-2 hours if direct WAV writer is needed.
**Model:** sonnet (numerical edge cases warrant care).

---

## P1 — DACVAE Watermarker: channel mismatches + embed-only port

**Status:** open
**Blast radius:** Default-config watermark path crashes at runtime. Bit-extraction is missing entirely.
**Evidence:**
- `Sources/MLXAudioCodecs/DACVAE/DACVAEWatermark.swift:177` — `postProcess` declares `inChannels=32` against an LSTM hidden of 512.
- `Sources/MLXAudioCodecs/DACVAE/DACVAE.swift:175` — `DACVAEFullDecoder.watermark()` has the same downstream mismatch.
- No bit-extraction code path exists in `Sources/MLXAudioCodecs/DACVAE/`.

### TODO

- [ ] **Pre-decision step:** `grep -rn "DACVAEWatermark\|DACVAEFullDecoder.watermark\|\.watermark(" Sources/ Examples/ Tests/` to find callers.
- [ ] **If zero non-test callers:** mark the public surface `@available(*, unavailable, message: "Watermark feature not yet ported — embed-only, default config crashes")`. Don't fix dead code.
- [ ] **If callers exist:** fix `inChannels` at both sites (likely change 32 → 512 to match `lstmHidden`). Add a runtime assertion that the channel counts agree at construction time so the failure mode becomes a fail-fast instead of silent crash. Verify via a unit test that exercises the default-config path.
- [ ] **Bit-extraction port:** explicitly OUT OF SCOPE for this follow-up. File a separate tracking issue with the upstream Python reference. Only revisit when a real consumer needs it.
- [ ] Update `Tests/MLXAudioCodecsTests.swift::DACVAEWatermarkerTests` to either re-assert round-trip (if extraction lands) or document the embed-only contract permanently.

**Cost:** 15 min grep + 30-90 min depending on caller-count branch.
**Model:** sonnet.

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
