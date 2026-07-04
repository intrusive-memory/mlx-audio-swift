# REQUIREMENTS — Glosa Integration (mlx-audio-swift)

**Status:** Draft / proposed
**Owner repo role:** TTS synthesis engine — consumes `breathOffsets: [Int]`.
**Primary deliverable:** Pin the `breathOffsets` contract for upstream consumers. **No code change is required for the breath happy-path** — the API already exists (shipped v0.9.0). This doc scopes the contract plus *optional* future work (pause/silence API, strength-aware chunking).

> One of four coordinated docs. See also:
> - `SwiftCompartido/REQUIREMENTS-glosa-integration.md` (produces offsets)
> - `SwiftVoxAlta/REQUIREMENTS-glosa-integration.md` (calls `generate`)
> - `glosa-av/REQUIREMENTS-glosa-integration.md`

---

## 1. Current state (no change needed for breaths)

`Qwen3TTSModel.generate(text:voice:refAudio:refText:language:instruct:breathOffsets:generationParameters:)` already accepts:
- `breathOffsets: [Int]` — unicode-scalar indices into `text` that split the utterance into independently-synthesised, concatenated sub-utterances (silent breath seams).

Implementation: `Sources/MLXAudioTTS/Models/Qwen3TTS/Qwen3TTSBreath.swift` (`splitTextAtBreaths`, `concatenateChunks`) and `Qwen3TTS.swift` `_generateImpl`. Empty `breathOffsets` is byte-identical to the no-parameter overload (verified by `Qwen3TTSBreathGenerateTests`, nightly).

**The offset convention already matches glosa exactly** (`unicodeScalars` indices into notes-stripped prose). So the integration requires **nothing** from this repo for breaths.

## 2. Contract requirements (documentation / guarantees)

### CR1 — Stability of the `breathOffsets` contract
- `breathOffsets` are `unicodeScalars` indices into the exact `text` passed to `generate`. Callers must pass the **notes-stripped spoken text** with offsets measured against that same string.
- Out-of-range / unsorted / duplicate offsets are tolerated (sorted, de-duped, clamped; empty segments dropped) per `splitTextAtBreaths`. This behavior is part of the contract and must remain stable (covered by `Qwen3TTSBreathSplitTests`, CI-safe).
- Empty `breathOffsets` MUST remain byte-identical to the non-breath path. Do not regress this.

## 3. Optional / future work (NOT required for v1 breath integration)

### FW1 — Pause / silence insertion API
Glosa distinguishes **breaths** (chunk seams, ~0 silence) from **pauses** (deliberate audible silence of a named or explicit duration: comma ≈150ms … beat ≈1000ms, or explicit ms/s). This engine has **no pause API** — only breath chunking. To render glosa `pausePoints`, add an API such as:
```swift
// e.g. parallel to breathOffsets:
pausePoints: [(offset: Int, durationSeconds: Double)] = []
```
that inserts silence of the given duration at the offset (concatenating a zero-filled buffer at the engine's sample rate). Until this exists, downstream consumers (VoxAlta) **cannot** render pauses — and must not pretend to.

### FW2 — Strength-aware chunking
Glosa `BreathStrength` (`weak`/`medium`/`strong`) encodes whether a seam is mandatory or budget-dependent. The current `breathOffsets: [Int]` flattens this away. If future quality work wants the engine to honor strength (e.g. only cut on `weak` when over a duration budget), a richer parameter would be needed:
```swift
breakPoints: [(offset: Int, strength: BreathStrength-equivalent)]
```
Doing this would couple a synthesis concept to a glosa concept — prefer a neutral enum owned here, not a glosa import. Lower priority; the offset-only path is sufficient for v1.

### FW3 — Optional crossfade seam
`crossfadeConcatenateChunks` + `breathSeamCrossfadeEnabled` already exist as a **dormant, default-off** scaffold. If breath seams ever sound abrupt in real audio, this can be enabled — but only after human A/B verification (per the existing code comment). Not part of this integration.

## 4. Non-goals
- **No** dependency on glosa-av or SwiftCompartido. This library stays a pure synthesis engine that consumes plain `[Int]` (and, if FW1 lands, plain offset/duration tuples) — never glosa types.
- No markup/`[[ ]]` parsing here (SwiftCompartido owns that).

## 5. Acceptance criteria
- AC1 (regression guard): existing `Qwen3TTSBreathSplitTests` (CI-safe) and `Qwen3TTSBreathGenerateTests` (nightly) continue to pass; empty-`breathOffsets` byte-identity preserved.
- AC2 (if FW1 implemented): a pause-insertion test asserts inserted silence length equals `round(durationSeconds * sampleRate)` samples at each offset, and empty `pausePoints` is byte-identical to today.
