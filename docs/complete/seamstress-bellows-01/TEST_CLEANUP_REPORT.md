---
feature_name: OPERATION SEAMSTRESS BELLOWS
iteration: 1
state: completed
---

# TEST_CLEANUP_REPORT.md — OPERATION SEAMSTRESS BELLOWS

Post-mission test-cleanup pass. Scope = test files in the mission diff
(`7f6493b..HEAD` on `mission/seamstress-bellows/01`). CI is the primary build
mechanism; this pass prunes tests added during the mission that cannot reliably
run in CI. Conservative by default — flag rather than delete when ambiguous.

## Test files in scope
- `Tests/Qwen3TTSBreathSplitTests.swift` (added — Sortie 2)
- `Tests/Qwen3TTSBreathGenerateTests.swift` (added — Sortie 5)

## Removed
| file:test | reason | confidence |
|-----------|--------|------------|
| _(none)_ | No test matched a high-confidence CI-failure pattern. | — |

## Flagged for Review
| file:test | concern | recommended action |
|-----------|---------|---------------------|
| _(none)_ | — | — |

## Reviewed and Kept (with rationale)
| file | review |
|------|--------|
| `Tests/Qwen3TTSBreathSplitTests.swift` | Pure, hermetic unit tests (string/unicode-scalar arithmetic only). No filesystem paths, no network, no time/date assertions, no unseeded randomness, no skip markers. Already registered in the CI-safe `-only-testing` block and passes there in <1s. **CI-safe — keep.** |
| `Tests/Qwen3TTSBreathGenerateTests.swift` | Nightly/local-only by design (gated on `MLXAUDIO_NIGHTLY_RUN`), but **not** a deletion candidate: it skips gracefully via `try #require(...)` when the env var/model is absent (so it never hard-fails in CI), uses **seeded** determinism (`MLXRandom.seed(42)` + greedy), contains **no** hardcoded paths or network calls, and is verified compile-only in CI via `build-for-testing`. It deliberately mirrors the repo's pre-existing accepted local-only pattern (`DeterministicGenerationTests`) and is registered ONLY in the local-only table, NOT the CI-safe block. **Intentional local-only suite — keep.** |

## Build Verification
Skipped — no deletions were made, so there is nothing to re-verify. (The two
suites' own gates were already verified during their sorties: the split suite
passes in CI; the generate suite compiles via `build-for-testing`.)

## Outcome
0 removed, 0 flagged. The mission added no CI-unsafe tests. No cleanup commit required.
