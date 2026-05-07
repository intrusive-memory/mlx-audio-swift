# Sortie 4 — Counter Store actor + Telemetry snapshot/reset/trackLifecycle API — COMPLETE

**Mission**: OPERATION LEAK BLOODHOUND
**Work Unit**: WU-1 Telemetry Foundation (final sortie)
**Sortie**: 4 of 15
**Branch**: `mission/leak-bloodhound/01`
**Iteration**: 1

---

## Summary

Landed the actor-backed counter store and the public async `snapshot()` /
`resetCounters()` API plus the internal `trackLifecycle` /
`trackLifecycleEnd` helpers that WU-2 (Sorties 5–9) will wire into
production `init` / `deinit` call sites.

- `internal actor CounterStore` with `static let shared` singleton in
  `Sources/MLXAudioCore/Telemetry/CounterStore.swift`.
- `liveCounts: [String: Int]`, `perOpDeltas: [String: Int]` (placeholder
  for WU-4), and `mlxPeakBytes: Int` high-water mark live inside the actor.
- `increment(className:)` / `decrement(className:)` short-circuit when
  `Telemetry.level == .off`.
- `snapshot()` reads `MLX.Memory.activeMemory` (the modern non-deprecated
  API; `MLX.GPU.activeMemory` is `@available(*, deprecated, renamed:
  "Memory.activeMemory")`), bumps the high-water mark to
  `max(mlxPeakBytes, mlxActiveBytes)`, stamps `Date()`, and returns a
  `TelemetrySnapshot`. We maintain the peak ourselves rather than
  depending on MLX's own peak API per resolved Q1 in `EXECUTION_PLAN.md`.
- `reset()` zeros `liveCounts` and `perOpDeltas` but **preserves**
  `mlxPeakBytes` per requirements §9.
- `Telemetry.snapshot()` and `Telemetry.resetCounters()` are
  `public static async` and forward to `CounterStore.shared`.
- `Telemetry.trackLifecycle(_:className:)` and
  `Telemetry.trackLifecycleEnd(className:)` are `internal static func`
  fire-and-forget helpers: each spawns a `Task.detached(priority:
  .background)` that awaits the actor and returns synchronously, so
  `init` / `deinit` of instrumented classes do not block. The
  fire-and-forget contract is documented inline (single-line comment per
  the project's no-comment carve-out for non-obvious invariants).
- `deinit` cannot capture `self` for use after deallocation, so
  `trackLifecycleEnd` takes only `className: String`. The class label is
  the link between init and deinit.
- Added `Tests/TelemetryCounterStoreTests.swift` with 10 tests covering
  every requirement: balance, multi-class independence, reset clears
  `liveCounts`, reset preserves `mlxPeakBytes`, snapshot bumps peak,
  concurrent increment/decrement balance via `withTaskGroup`, concurrent
  unbalanced increment count, fire-and-forget `trackLifecycle` /
  `trackLifecycleEnd` enqueues, and snapshot field shape.
- The test suite is marked `.serialized` because every test mutates the
  shared singleton; without serialization, parallel `@Test` execution
  caused increments / decrements / resets to interleave across cases.

---

## Files Created or Modified

| Path | Change |
|------|--------|
| `Sources/MLXAudioCore/Telemetry/CounterStore.swift` | NEW — `internal actor CounterStore` with `static let shared`, `liveCounts`, `perOpDeltas`, `mlxPeakBytes`, plus `increment` / `decrement` / `snapshot` / `reset` and two `_*ForTesting` introspection helpers. |
| `Sources/MLXAudioCore/Telemetry/Telemetry.swift` | MODIFIED — added `public static func snapshot() async -> TelemetrySnapshot`, `public static func resetCounters() async`, `internal static func trackLifecycle(_:className:)`, and `internal static func trackLifecycleEnd(className:)`. The fire-and-forget contract is documented inline. |
| `Tests/TelemetryCounterStoreTests.swift` | NEW — 10 Swift Testing tests in a `.serialized` `TelemetryCounterStoreTests` suite. |
| `COMPLETE_S4_COUNTER_STORE.md` | NEW — this file. |

No other files were modified. `EXECUTION_PLAN.md`, `SUPERVISOR_STATE.md`,
`Package.swift`, `TelemetrySnapshot.swift`, `Logging.swift`, and all
prior sortie test files are unchanged per sergeant rules.

---

## Verification Evidence

### Exit criterion 1: `Telemetry.snapshot()` / `Telemetry.resetCounters()` are `public static async`

```
$ grep -E 'public static func (snapshot|resetCounters).*async' \
    Sources/MLXAudioCore/Telemetry/*.swift
Sources/MLXAudioCore/Telemetry/Telemetry.swift:    public static func snapshot() async -> TelemetrySnapshot {
Sources/MLXAudioCore/Telemetry/Telemetry.swift:    public static func resetCounters() async {
$ echo "exit: $?"
exit: 0
```

Both signatures present. ✓

### Exit criterion 2: `Telemetry.trackLifecycle` exists as an `internal` helper

```
$ grep -E 'internal static func trackLifecycle' \
    Sources/MLXAudioCore/Telemetry/*.swift
Sources/MLXAudioCore/Telemetry/Telemetry.swift:    internal static func trackLifecycle(_ instance: AnyObject, className: String) {
Sources/MLXAudioCore/Telemetry/Telemetry.swift:    internal static func trackLifecycleEnd(className: String) {
$ echo "exit: $?"
exit: 0
```

Both `trackLifecycle` (init-side) and `trackLifecycleEnd` (deinit-side)
are present. ✓

### Exit criterion 3: `mlxPeakBytes` survives `resetCounters()`

Covered by `TelemetryCounterStoreTests.testResetPreservesPeak` (line 110
of `Tests/TelemetryCounterStoreTests.swift`). The test seeds peak via
`_setPeakForTesting(1_234_567_890)`, calls `Telemetry.resetCounters()`,
re-snapshots, and asserts `after.mlxPeakBytes == observedPeak`. Test
passed: see Exit criterion 4 output below.

### Exit criterion 4: targeted suite passes

```
$ xcodebuild test -scheme MLXAudio-Package -destination 'platform=macOS' \
    -only-testing:MLXAudioTests/TelemetryCounterStoreTests \
    CODE_SIGNING_ALLOWED=NO
...
􀟈 Suite "TelemetryCounterStoreTests" started.
􀟈 Test "increment then decrement returns to zero" started.
􁁛 Test "increment then decrement returns to zero" passed after 0.021 seconds.
􀟈 Test "multiple class labels are tracked independently" started.
􁁛 Test "multiple class labels are tracked independently" passed after 0.001 seconds.
􀟈 Test "reset zeroes liveCounts" started.
􁁛 Test "reset zeroes liveCounts" passed after 0.001 seconds.
􀟈 Test "reset preserves mlxPeakBytes (monotonic across resets)" started.
􁁛 Test "reset preserves mlxPeakBytes (monotonic across resets)" passed after 0.001 seconds.
􀟈 Test "snapshot updates mlxPeakBytes when activeMemory exceeds it" started.
􁁛 Test "snapshot updates mlxPeakBytes when activeMemory exceeds it" passed after 0.001 seconds.
􀟈 Test "snapshot is consistent under concurrent increment/decrement" started.
􁁛 Test "snapshot is consistent under concurrent increment/decrement" passed after 0.001 seconds.
􀟈 Test "snapshot under concurrent unbalanced increments matches submitted total" started.
􁁛 Test "snapshot under concurrent unbalanced increments matches submitted total" passed after 0.001 seconds.
􀟈 Test "trackLifecycle enqueues an increment via detached Task" started.
􁁛 Test "trackLifecycle enqueues an increment via detached Task" passed after 0.001 seconds.
􀟈 Test "trackLifecycleEnd enqueues a decrement via detached Task" started.
􁁛 Test "trackLifecycleEnd enqueues a decrement via detached Task" passed after 0.001 seconds.
􀟈 Test "snapshot fields are populated and well-formed" started.
􁁛 Test "snapshot fields are populated and well-formed" passed after 0.001 seconds.
􁁛 Suite "TelemetryCounterStoreTests" passed after 0.024 seconds.
􁁛 Test run with 10 tests in 1 suite passed after 0.024 seconds.

** TEST SUCCEEDED **
```

10 / 10 tests pass. ✓

### Exit criterion 5: full CI-safe test block passes

```
$ xcodebuild test -scheme MLXAudio-Package -destination 'platform=macOS' \
    -only-testing:MLXAudioTests/VocosTests \
    [... all 38 suites from CLAUDE.md ...] \
    CODE_SIGNING_ALLOWED=NO
...
􁁛 Test run with 326 tests in 38 suites passed after 9.615 seconds.

** TEST SUCCEEDED **
```

326 / 326 tests pass. No regressions across the full CI-safe block. ✓

---

## Exact Verification Commands (Re-Executable)

```sh
# 1) Telemetry.snapshot() / Telemetry.resetCounters() are public static async
grep -E 'public static func (snapshot|resetCounters).*async' \
    Sources/MLXAudioCore/Telemetry/*.swift

# 2) Telemetry.trackLifecycle exists as internal
grep -E 'internal static func trackLifecycle' \
    Sources/MLXAudioCore/Telemetry/*.swift

# 3) Targeted suite
xcodebuild test -scheme MLXAudio-Package -destination 'platform=macOS' \
  -only-testing:MLXAudioTests/TelemetryCounterStoreTests \
  CODE_SIGNING_ALLOWED=NO

# 4) Full CI-safe block (from CLAUDE.md)
xcodebuild test -scheme MLXAudio-Package -destination 'platform=macOS' \
  -only-testing:MLXAudioTests/VocosTests \
  -only-testing:MLXAudioTests/EncodecTests \
  -only-testing:MLXAudioTests/DACVAETests \
  -only-testing:MLXAudioTests/GLMASRModuleSetupTests \
  -only-testing:MLXAudioTests/GLMASRModelTests \
  -only-testing:MLXAudioTests/Qwen3ASRModuleSetupTests \
  -only-testing:MLXAudioTests/ForceAlignProcessorTests \
  -only-testing:MLXAudioTests/ForcedAlignResultTests \
  -only-testing:MLXAudioTests/Qwen3ASRHelperTests \
  -only-testing:MLXAudioTests/SplitAudioIntoChunksTests \
  -only-testing:MLXAudioTests/Qwen3TTSSpeechTokenizerTests \
  -only-testing:MLXAudioTests/Qwen3TTSSpeechTokenizerEncodeTests \
  -only-testing:MLXAudioTests/Qwen3TTSSpeechTokenizerWeightTests \
  -only-testing:MLXAudioTests/Qwen3TTSLanguageTests \
  -only-testing:MLXAudioTests/Qwen3TTSConfigTests \
  -only-testing:MLXAudioTests/Qwen3TTSRoutingTests \
  -only-testing:MLXAudioTests/Qwen3TTSPrepareBaseInputsTests \
  -only-testing:MLXAudioTests/Qwen3TTSGenerateCustomVoiceTests \
  -only-testing:MLXAudioTests/Qwen3TTSSpeakerEncoderTests \
  -only-testing:MLXAudioTests/Qwen3TTSSpeakerEncoderWeightTests \
  -only-testing:MLXAudioTests/Qwen3TTSSpeakerEmbeddingTests \
  -only-testing:MLXAudioTests/Qwen3TTSPrepareICLInputsTests \
  -only-testing:MLXAudioTests/Qwen3TTSGenerateICLTests \
  -only-testing:MLXAudioTests/Qwen3TTSSpeakerEncoderSmokeTests \
  -only-testing:MLXAudioTests/LlamaTTSModuleSetupTests \
  -only-testing:MLXAudioTests/ParityFixtureLoaderSmokeTests \
  -only-testing:MLXAudioTests/PocketTTSModuleSetupTests \
  -only-testing:MLXAudioTests/SopranoModuleSetupTests \
  -only-testing:MLXAudioTests/MarvisTTSModuleSetupTests \
  -only-testing:MLXAudioTests/MLXAudioCoreDSPTests \
  -only-testing:MLXAudioTests/ModelUtilsTests \
  -only-testing:MLXAudioTests/MimiLayerTests \
  -only-testing:MLXAudioTests/SNACVQTests \
  -only-testing:MLXAudioTests/DACVAEWatermarkerTests \
  -only-testing:MLXAudioTests/UnigramTokenizerRoundTripTests \
  -only-testing:MLXAudioTests/ConvWeightedTests \
  -only-testing:MLXAudioTests/AudioUtilsTests \
  -only-testing:MLXAudioTests/AudioIORoundTripTests \
  CODE_SIGNING_ALLOWED=NO
```

---

## Design Notes

### Why `MLX.Memory.activeMemory` instead of `MLX.GPU.activeMemory`

The execution plan referenced `MLX.GPU.activeMemory()` but allowed the
executing agent to confirm the correct module path. In the current
mlx-swift checkout, `GPU.activeMemory` is `@available(*, deprecated,
renamed: "Memory.activeMemory")`. Using the deprecated name would emit
a build warning every time `CounterStore.swift` compiled. The semantics
are identical (`GPU.activeMemory` is implemented as `Memory.activeMemory`),
so we use `MLX.Memory.activeMemory` directly.

### Why `.serialized` on the test suite

Swift Testing runs `@Test` methods in parallel by default. Every test
in this suite mutates `CounterStore.shared` (a single global actor
instance) and calls `Telemetry.resetCounters()` between scenarios. With
parallel execution, an increment from test A could land between
`reset()` and the snapshot of test B, producing flaky failures (we
observed exactly this on the first run — 7 / 10 tests failed before the
serialization trait was added). `.serialized` forces test methods within
the suite to run one at a time. The whole suite runs in ~24 ms, so the
serialization cost is negligible.

### Why `_setPeakForTesting` exists

`mlxPeakBytes` is updated only by `snapshot()`. To test the
"reset preserves peak" semantic deterministically, we need to seed peak
to a known value without depending on a real MLX allocation (which
unit tests don't have a way to force). `_setPeakForTesting(_:)` is
prefixed with `_` to mark it as test-only API and lives on the actor so
only `@testable import MLXAudioCore` can reach it. It's `internal`, so
release builds and host apps cannot see it.

### Fire-and-forget Task contract

Both `trackLifecycle` and `trackLifecycleEnd` use
`Task.detached(priority: .background) { await CounterStore.shared.… }`.
This deliberately:

1. Does not await — the calling `init` / `deinit` returns immediately,
   so model construction and tear-down stay synchronous.
2. Uses `.background` priority so counter updates do not preempt
   real work.
3. Captures `instance` only by reference (no retention) so the
   `AnyObject` parameter exists purely as a future hook for per-instance
   signpost IDs (planned in S5+).
4. Re-checks `Telemetry.level != .off` on the call-site side AND inside
   the actor's `increment` / `decrement`. The double check is
   intentional: the call-site early-return avoids spawning a Task at
   all when telemetry is off (zero overhead), and the actor-side guard
   protects against direct callers that bypass `trackLifecycle`.

### `perOpDeltas` is a placeholder

The plan explicitly carves out: "The `perOpDeltas` field is just a
placeholder dictionary for now." It exists inside the actor and is
zeroed on `reset()`, but is **not** surfaced in `TelemetrySnapshot` (the
struct already shipped in S1 has no `perOpDeltas` field). WU-4 / S12
will extend the snapshot struct additively when it lands the per-op
accumulation logic.

### `deinit` cannot take `AnyObject`

The asymmetric API (`trackLifecycle(_ instance:, className:)` vs
`trackLifecycleEnd(className:)`) is forced by Swift's `deinit` rules: a
class instance is no longer valid to capture by the time `deinit` runs.
The `className` string is the link between init and deinit; instrumented
classes are responsible for using the same string in both calls.

---

## Out of Scope (per sergeant rules)

- Did NOT instrument any production `init` / `deinit` (S5+ work).
- Did NOT implement `perOpDeltas` accumulation (S12 / WU-4).
- Did NOT extend `TelemetrySnapshot` to include `perOpDeltas` (the
  comment in S1's TelemetrySnapshot.swift already noted that field is
  S4-defined; S12 will extend it additively when the time comes).
- Did NOT modify `EXECUTION_PLAN.md` or `SUPERVISOR_STATE.md`.
- Did NOT touch `main`; all work stayed on `mission/leak-bloodhound/01`.
- Did NOT use `swift build` / `swift test` — only `xcodebuild` per
  `CLAUDE.md`.
