# Requirements: Qwen3-TTS "breath" phrasing seams

## Summary

Add support for **silent breath seams** to the Qwen3-TTS generation pipeline,
faithfully implementing the `<breath/>` semantic from the `glosa-av` project.

A "breath" in glosa-av is **not** an audible inhalation or pause. It is a
**silent phrasing hint** — a chunking directive that tells the TTS engine where
to split a long dialogue line into separate sub-utterances, each re-seeded with
the same speaker conditioning. Its purpose is to stop ICL-cloned voices (exactly
Qwen3-TTS) from drifting in cadence and pitch on long run-on sentences. It is
orthogonal to glosa-av's `<pause/>` tag, which is the *audible* silence tag and
is **out of scope here**.

This work introduces text chunking above the existing `generate` entry point. It
requires **no model, weight, config, or tokenizer changes**.

## Background (verified against current code)

- Entry point: `Qwen3TTS.generate(text:voice:refAudio:refText:language:instruct:generationParameters:)`
  at `Sources/MLXAudioTTS/Models/Qwen3TTS/Qwen3TTS.swift:504`.
- `generate` wraps `_generateImpl` (`Qwen3TTS.swift:566`), which resolves one of
  four paths (`voiceDesign`, `customVoice`, `base`, ICL) and returns a 1-D
  `MLXArray` waveform (`audio.dim(0)` = sample count).
- There is currently **no phrasing/segmentation logic** in the pipeline — text is
  processed as a single continuous sequence. This feature introduces it.
- Frame rate is 12.5 Hz (~80 ms per codec token). Sample-level concatenation of
  waveforms is the integration point.
- Speaker identity is stable across chunks for free: Base/Custom key off `voice`;
  ICL re-derives the same x-vector from the unchanged `refAudio`. Independent
  per-chunk generation therefore preserves the speaker while resetting prosody —
  which is the intended behavior.

## Decisions already made (do not re-litigate)

1. **Semantic:** Silent chunk-seam (faithful glosa-av `<breath/>`). ~0 audible
   silence. `<pause/>` / audible silence is explicitly out of scope.
2. **API surface:** Caller passes **offsets**, not inline markers. glosa-av
   already strips its markup and emits `Breath.characterOffset` values, so no
   in-text parser is needed in this library and there is no marker-collision risk.
3. **Offset units:** **unicode-scalar indices** into `text`, matching glosa-av's
   `Breath.characterOffset` (measured in `unicodeScalars.count`) exactly.
4. **No `strength` parameter:** glosa-av decides *whether* to split upstream (its
   budget/strength heuristics). By the time offsets reach this library the
   decision is final; this library only honors the seams.

## Goals

- `generate` accepts a list of breath offsets and, when present, produces one
  continuous waveform assembled from per-segment generations re-seeded at each
  seam.
- Zero behavioral change when no breath offsets are supplied (empty list ==
  today's exact behavior and code path, no added overhead).
- The text-splitting logic is a pure, deterministic, separately testable unit
  that needs no model download to test.

## Non-goals

- Audible breath sounds or silence insertion (that is `<pause/>`, out of scope).
- Parsing inline `<breath/>` / `[breath]` markers from the text string.
- A `strength` attribute or any budget/placement heuristics (those live in
  glosa-av).
- Changes to model weights, config, tokenizer, or codec.
- Wiring glosa-av itself to call this API (separate downstream work).

## Functional requirements

### FR1 — Public API

Add a defaulted `breathOffsets` parameter to the public `generate` method
(source-compatible; existing call sites unaffected):

```swift
public func generate(
    text: String,
    voice: String?,
    refAudio: MLXArray? = nil,
    refText: String? = nil,
    language: String? = nil,
    instruct: String? = nil,
    breathOffsets: [Int] = [],          // NEW — unicodeScalar indices into `text`
    generationParameters: GenerateParameters
) async throws -> MLXArray
```

### FR2 — Orchestration refactor

- Rename the current `_generateImpl` (`Qwen3TTS.swift:566`) to `_generateSingle`
  with its body unchanged (resolves the path, returns one waveform).
- Introduce a new `_generateImpl` orchestrator that:
  - When `breathOffsets` is empty → calls `_generateSingle` exactly once (today's
    behavior, no added work).
  - Otherwise → sorts, de-duplicates, and clamps offsets to the valid range;
    splits `text` at those unicode-scalar boundaries; calls `_generateSingle` once
    per **non-empty** segment with **identical** `voice / refAudio / refText /
    language / instruct / generationParameters`; concatenates the resulting
    waveforms via `MLX.concatenated(_, axis: 0)`.
- Preserve existing `generate`-level telemetry (one start/complete for the whole
  utterance). Per-chunk telemetry is optional and may be deferred.

### FR3 — Pure helpers (new file `Qwen3TTSBreath.swift`)

- `splitTextAtBreaths(_ text: String, offsets: [Int]) -> [String]`
  - Splits on unicode-scalar offsets.
  - Sorts and de-duplicates offsets.
  - Clamps/ignores out-of-range offsets (< 0 or > scalar count).
  - Offset 0 and offset == end produce no spurious empty leading/trailing chunk
    behavior that would change output (empty segments are dropped before
    generation).
  - Deterministic and side-effect free.
- `concatenateChunks(_ chunks: [MLXArray]) -> MLXArray`
  - Concatenates 1-D waveforms along axis 0.
  - Defined behavior for a single chunk (returns it) and for the empty case.

### FR4 — Seam handling

- Default: **direct concatenation** (glosa-av = ~0 silence).
- Provide an optional, **default-off** equal-power crossfade of a few ms behind a
  named constant, to be enabled only if raw concatenation produces audible clicks
  at boundaries. Must be verified against real audio before being enabled by
  default — do not enable by default in this mission without that verification.

## Testing requirements

### TR1 — CI-safe unit tests (no model download)

Add `Qwen3TTSBreathSplitTests` exercising the pure splitter:

- Empty offsets → single segment equal to input.
- Unsorted offsets → same result as sorted.
- Duplicate offsets → de-duplicated, no empty segments leak through.
- Out-of-range offsets (negative, > length) → ignored/clamped.
- Offset at 0 and at end → no spurious empty chunks affecting output.
- Multibyte / emoji / combining-mark boundaries split on scalar counts correctly
  (asserts parity with glosa-av's `unicodeScalars.count` convention).
- Concatenation of N segments reconstructs the original text (round-trip).

Add the new suite name to the CI-safe `-only-testing` list in `CLAUDE.md`.

### TR2 — Local-only audio test (model download)

Add one gated audio test (alongside the existing model-download suites, excluded
from CI) asserting that `generate(..., breathOffsets:)` returns a waveform whose
total sample count is approximately the sum of the per-chunk sample counts, and
that the empty-offsets path is byte-identical to calling `generate` without the
parameter. Gate consistently with the other local-only suites documented in
`CLAUDE.md`.

## Constraints

- Branch from and commit to `development`; never `main`. PR `development` → `main`.
- Never use `swift build` / `swift test`. Use
  `xcodebuild ... -scheme MLXAudio-Package -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO`,
  preferring `make` targets where available.
- CI-safe unit suite must pass (the `-only-testing` block in `CLAUDE.md`).
- No regression to the empty-`breathOffsets` path — it must remain the existing
  code path.
- Update `CLAUDE.md` (and any relevant docs) to register the new CI-safe test
  suite and document the `breathOffsets` parameter.

## Acceptance criteria

- [ ] `generate` accepts `breathOffsets: [Int] = []`; existing call sites compile
      unchanged.
- [ ] Empty `breathOffsets` reproduces today's behavior via the unchanged
      single-generation path.
- [ ] Non-empty `breathOffsets` yields one concatenated waveform built from
      per-segment generations sharing identical speaker conditioning.
- [ ] `splitTextAtBreaths` is pure, splits on unicode scalars, and handles
      unsorted/duplicate/out-of-range/boundary offsets per FR3.
- [ ] `Qwen3TTSBreathSplitTests` passes in CI and is registered in `CLAUDE.md`.
- [ ] Local-only audio test passes locally and is gated out of CI.
- [ ] No model/weight/config/tokenizer changes.
- [ ] CI-safe `xcodebuild test` block passes.

## Open trade-off to validate (non-blocking)

Per-chunk generation pays one talker warm-up per segment and intentionally drops
cross-boundary prosodic continuity (the drift reset is the feature). On a line
split into many very short fragments this can sound stop-start. Upstream glosa-av
budget heuristics are what keep fragments sensibly sized. Recommend an A/B listen
on one real long line before finalizing seam defaults (relates to FR4).
