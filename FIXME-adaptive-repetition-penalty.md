# FIXME: Adaptive Repetition Penalty for Long Generations

## Problem

Audio drift occurs in long ICL (In-Context Learning) generations (20-30s) because the repetition penalty (1.3) is applied across the full code history (300-400 codes). This suppresses legitimately-repeating audio codes in sustained vowels and rhythmic speech patterns, distorting prosody.

**Evidence**: Chapter 2 analysis shows drift starting at element 11 (~23s duration, 289 generated codes). The 1.3 penalty applied across 358 total codes (refCodes + generated) distorts prosody as the generation progresses.

**Root cause**: The current implementation applies a constant `repetitionPenalty` to the full `generatedTokens` history in `sampleToken()`, regardless of generation length. This penalty was tuned for short-text generation and becomes pathological for long utterances.

## Solution

Implement **adaptive repetition penalty** that decays or disables as `fullCodes` grows past a threshold.

### Strategy Options

Choose **ONE** of these approaches:

1. **Exponential Decay** (Recommended)
   - Decay penalty from 1.3 → 1.0 as fullCodes grows
   - Formula: `effectivePenalty = 1.0 + (basePenalty - 1.0) * exp(-fullCodes / decayConstant)`
   - Example: `1.0 + 0.3 * exp(-fullCodes / 200)` → approaches 1.0 for 400+ code generations

2. **Hard Threshold**
   - Use full penalty below threshold, disable above
   - Formula: `effectivePenalty = fullCodes < 150 ? basePenalty : 1.0`
   - Simpler but creates a discontinuity

3. **Sliding Window**
   - Apply penalty only to last N codes instead of full history
   - Pass `generatedTokens.suffix(100)` instead of full array
   - More principled but changes penalty semantics

**Recommendation**: Start with **exponential decay** (option 1) because:
- Smooth transition, no discontinuities
- Penalty still active for short generations (good)
- Gradually releases for long generations (prevents distortion)
- One tunable parameter (decayConstant)

## Implementation

### File to Modify

**`Sources/MLXAudioTTS/Models/Qwen3TTS/Qwen3TTS.swift`**

### Code Location

Function: `generateFromEmbeddings()` (lines 912-1018)

Specifically, the `sampleToken` call at lines 943-951:

```swift
let nextToken = sampleToken(
    logits,
    temperature: temperature,
    topP: topP,
    repetitionPenalty: repetitionPenalty,  // ← Currently constant
    generatedTokens: generatedCodes.map { Int($0[0, 0].item(Int32.self)) },
    suppressTokens: suppressTokens,
    eosTokenId: eosTokenId
)
```

### Changes Required

#### 1. Add adaptive penalty calculation before the generation loop

**Location**: After line 932 (before `for step in 0 ..< maxTokens`)

```swift
// Adaptive repetition penalty: decay from basePenalty to 1.0 as generation grows
// to prevent pathological suppression of sustained vowels in long generations.
let basePenalty = repetitionPenalty
let decayConstant: Float = 200.0  // Tunable: controls how quickly penalty decays
```

#### 2. Calculate effective penalty inside the loop

**Location**: After line 933 (inside the `for step` loop, before `talker()` call)

```swift
for step in 0 ..< maxTokens {
    // Compute adaptive repetition penalty based on current generation length
    let fullCodes = generatedCodes.count + Int(refCodesLen)  // Total codes in context
    let decayFactor = exp(-Float(fullCodes) / decayConstant)
    let effectiveRepPenalty = 1.0 + (basePenalty - 1.0) * decayFactor
    
    // Forward pass through talker
    let (logits, hidden) = talker(inputEmbeds, cache: cache)
    // ... rest of loop
```

**Note**: `refCodesLen` is not currently available in `generateFromEmbeddings()`. Two options:
- **Option A** (Simpler): Use `generatedCodes.count` only (ignores ref codes in decay calculation)
- **Option B** (More accurate): Add `refCodesLen: Int` parameter to `generateFromEmbeddings()` and pass it from callers

**Recommendation**: Use **Option A** for simplicity. The decay is based on generated code length, not total context length.

#### 3. Update the sampleToken call to use adaptive penalty

**Location**: Line 943, replace `repetitionPenalty:` parameter

```swift
let nextToken = sampleToken(
    logits,
    temperature: temperature,
    topP: topP,
    repetitionPenalty: effectiveRepPenalty,  // ← Use adaptive penalty
    generatedTokens: generatedCodes.map { Int($0[0, 0].item(Int32.self)) },
    suppressTokens: suppressTokens,
    eosTokenId: eosTokenId
)
```

#### 4. Add telemetry logging (optional but recommended)

**Location**: After the sampleToken call, add logging every 50 steps

```swift
// Log adaptive penalty every 50 steps for telemetry
if step > 0 && step % 50 == 0 {
    FileHandle.standardError.write(Data(
        "[AdaptiveRepPenalty] step=\(step), fullCodes=\(generatedCodes.count), effectivePenalty=\(String(format: "%.3f", effectiveRepPenalty))\n".utf8
    ))
}
```

### Complete Diff Preview

```swift
func generateFromEmbeddings(
    inputEmbeds inputEmbedsInit: MLXArray,
    trailingTextHidden: MLXArray,
    ttsPadEmbed: MLXArray,
    temperature: Float,
    topP: Float,
    repetitionPenalty: Float,  // Base penalty, will be adapted dynamically
    maxTokens: Int,
    onToken: ((Int) -> Void)? = nil
) -> [MLXArray] {
    let talkerConfig = config.talkerConfig!
    let cache = talker.makeCache()
    var generatedCodes = [MLXArray]()
    let eosTokenId = talkerConfig.codecEosTokenId

    // Suppress special tokens
    let suppressTokens = (talkerConfig.vocabSize - 1024 ..< talkerConfig.vocabSize)
        .filter { $0 != eosTokenId }

    var trailingIdx = 0
    var inputEmbeds = inputEmbedsInit

+   // Adaptive repetition penalty: decay from basePenalty to 1.0 as generation grows
+   let basePenalty = repetitionPenalty
+   let decayConstant: Float = 200.0

    for step in 0 ..< maxTokens {
+       // Compute adaptive repetition penalty
+       let decayFactor = exp(-Float(generatedCodes.count) / decayConstant)
+       let effectiveRepPenalty = 1.0 + (basePenalty - 1.0) * decayFactor
+
        // Forward pass through talker
        let (logits, hidden) = talker(inputEmbeds, cache: cache)

        asyncEval(logits, hidden)

        // Sample first codebook token
        let nextToken = sampleToken(
            logits,
            temperature: temperature,
            topP: topP,
-           repetitionPenalty: repetitionPenalty,
+           repetitionPenalty: effectiveRepPenalty,
            generatedTokens: generatedCodes.map { Int($0[0, 0].item(Int32.self)) },
            suppressTokens: suppressTokens,
            eosTokenId: eosTokenId
        )

        // Check EOS
        let tokenId = Int(nextToken[0, 0].item(Int32.self))
        onToken?(tokenId)
        if tokenId == eosTokenId { break }

+       // Telemetry: log adaptive penalty every 50 steps
+       if step > 0 && step % 50 == 0 {
+           FileHandle.standardError.write(Data(
+               "[AdaptiveRepPenalty] step=\(step), codes=\(generatedCodes.count), penalty=\(String(format: "%.3f", effectiveRepPenalty))\n".utf8
+           ))
+       }

        // ... rest of loop unchanged
```

## Testing

### 1. Re-render Chapter 2

```bash
cd /Users/stovak/Projects/podcast-tao-de-jing
bin/produciesta generate episodes/chapter-02.fountain \
    --output episodes/audio/chapter-02-fixed.m4a \
    --verbose > episodes/chapter-02-fixed.log 2>&1
```

### 2. Compare drift at 1:30 mark

Listen to both files:
- `episodes/audio/chapter-02.m4a` (original, drifts at 1:30)
- `episodes/audio/chapter-02-fixed.m4a` (fixed)

### 3. Check telemetry logs

```bash
grep "AdaptiveRepPenalty" episodes/chapter-02-fixed.log
```

Expected output for element 11 (~289 codes):
```
[AdaptiveRepPenalty] step=50, codes=50, penalty=1.236
[AdaptiveRepPenalty] step=100, codes=100, penalty=1.182
[AdaptiveRepPenalty] step=150, codes=150, penalty=1.133
[AdaptiveRepPenalty] step=200, codes=200, penalty=1.091
[AdaptiveRepPenalty] step=250, codes=250, penalty=1.060
```

### 4. Verify prosody quality

- No drift at 1:30?
- Natural sustained vowels preserved?
- No excessive repetition/stuttering?

## Tuning Parameters

If the fix doesn't fully resolve drift or introduces new issues:

- **`decayConstant` too small** (e.g., 100): Penalty drops too quickly, may introduce repetition in short/medium utterances
- **`decayConstant` too large** (e.g., 400): Penalty decays too slowly, drift may persist
- **Sweet spot**: 150-250 (start with 200)

Try adjusting `decayConstant` and re-testing if needed.

## Success Criteria

- [ ] No prosody drift at 1:30 in chapter-02-fixed.m4a
- [ ] Natural sustained vowels in long exposition passages
- [ ] No new stuttering or repetition artifacts
- [ ] Adaptive penalty telemetry shows smooth decay
- [ ] Short utterances (< 10s) still sound natural (penalty still active)

## Notes

- This fix is **complementary** to auto-chunking (which will be implemented separately)
- Adaptive penalty addresses the pathological penalty application in long generations
- Auto-chunking addresses the reference-anchor dilution problem
- Both fixes together should eliminate drift comprehensively
