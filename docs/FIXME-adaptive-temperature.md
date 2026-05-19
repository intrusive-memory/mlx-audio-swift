# FIXME: Adaptive Temperature Scaling for Long Generations

## Problem

Audio drift in long ICL generations (20-30s) is partially caused by **sampling variance compounding** across 289-373 sequential sampling steps. Each code is sampled from a distribution at `temperature=0.7`, which introduces mild noise per step. Over hundreds of steps, prosody trajectories can wander, especially once the reference anchor has weakened.

**Evidence**: Chapter 2 element 11 generates 289 codes (~23s). At 0.7 temperature, cumulative sampling variance allows prosody to drift from the reference pattern as generation progresses.

**Contributing factor**: This is **not** the dominant cause of drift (reference-anchor dilution is), but it's a measurable contributor. Reducing temperature for long generations reduces prosodic wander.

## Solution

Implement **adaptive temperature scaling** that lowers temperature as estimated generation length increases.

### Strategy

Scale temperature down as a function of expected output length:

```swift
adaptiveTemp = baseTemp * (1.0 - scaleFactor * min(1.0, estimatedCodes / maxCodes))
```

Where:
- `baseTemp`: Original temperature (e.g., 0.7)
- `scaleFactor`: How much to reduce temperature (e.g., 0.3 means reduce by up to 30%)
- `estimatedCodes`: Estimated number of codes based on text length
- `maxCodes`: Threshold at which temperature is fully reduced (e.g., 400)

**Example**: For a 400-code generation with `scaleFactor=0.3`:
- `adaptiveTemp = 0.7 * (1.0 - 0.3 * 1.0) = 0.49`

For a 100-code generation:
- `adaptiveTemp = 0.7 * (1.0 - 0.3 * 0.25) = 0.6475`

**Trade-off**: Lower temperature makes prosody flatter/less expressive, but reduces drift. This is acceptable for long expositions where clarity matters more than expressiveness.

## Implementation

### File to Modify

**`Sources/MLXAudioTTS/Models/Qwen3TTS/Qwen3TTS.swift`**

### Code Location

Function: `generateWithClonePrompt()` in `Qwen3TTSVoiceClonePrompt.swift` (lines 230-327)

Specifically, the section that computes `effectiveMaxTokens` (lines 258-259):

```swift
// Step 2: Cap max tokens based on text length
let targetTokenCount = tokenizer.encode(text: text).count
let effectiveMaxTokens = min(maxTokens, max(200, targetTokenCount * 12))
```

### Changes Required

#### 1. Add adaptive temperature calculation after effectiveMaxTokens

**Location**: After line 259 in `Qwen3TTSVoiceClonePrompt.swift`

```swift
// Step 2: Cap max tokens based on text length
let targetTokenCount = tokenizer.encode(text: text).count
let effectiveMaxTokens = min(maxTokens, max(200, targetTokenCount * 12))

// Step 2.5: Adaptive temperature scaling for long generations
// Reduces sampling variance in long utterances to prevent prosodic drift
let estimatedCodes = targetTokenCount * 4  // Rough estimate: 1 text token ≈ 4 audio codes
let temperatureScaleFactor: Float = 0.3  // Reduce by up to 30% for very long generations
let maxCodesForScaling: Float = 400.0  // Full scaling kicks in at 400 codes
let scalingRatio = min(1.0, Float(estimatedCodes) / maxCodesForScaling)
let adaptiveTemperature = temperature * (1.0 - temperatureScaleFactor * scalingRatio)

// Telemetry: Log adaptive temperature calculation
FileHandle.standardError.write(Data(
    "[AdaptiveTemp] estimatedCodes=\(estimatedCodes), scalingRatio=\(String(format: "%.3f", scalingRatio)), baseTemp=\(temperature), adaptiveTemp=\(String(format: "%.3f", adaptiveTemperature))\n".utf8
))
```

#### 2. Update the generateFromEmbeddings call to use adaptive temperature

**Location**: Line 270-278 in `Qwen3TTSVoiceClonePrompt.swift`

```swift
// Step 4: Run shared autoregressive generation loop
let generatedCodes = generateFromEmbeddings(
    inputEmbeds: inputEmbeds,
    trailingTextHidden: trailingTextHidden,
    ttsPadEmbed: ttsPadEmbed,
-   temperature: temperature,
+   temperature: adaptiveTemperature,  // ← Use adaptive temperature
    topP: topP,
    repetitionPenalty: effectiveRepPenalty,
    maxTokens: effectiveMaxTokens
)
```

#### 3. Apply same pattern to other generation paths

The same adaptive temperature logic should be applied to:

1. **`generateICL()` in `Qwen3TTS.swift`** (lines 1308-1400)
2. **`generateBase()` in `Qwen3TTS.swift`** (lines 1117-1200)
3. **`generateVoiceDesign()` in `Qwen3TTS.swift`** (lines 1037-1110)

**Note**: Only `generateWithClonePrompt` and `generateICL` are ICL paths where drift occurs. The other paths are lower priority but should be updated for consistency.

### Complete Diff Preview (generateWithClonePrompt)

```swift
public func generateWithClonePrompt(
    text: String,
    clonePrompt: VoiceClonePrompt,
    language: String? = nil,
    instruct: String? = nil,
    temperature: Float = 0.9,
    topP: Float = 1.0,
    repetitionPenalty: Float = 1.5,
    maxTokens: Int = 4096
) throws -> MLXArray {
    guard let speechTokenizer, let tokenizer else {
        throw AudioGenerationError.modelNotInitialized("Speech tokenizer or text tokenizer not loaded")
    }

    let effectiveLanguage = language ?? clonePrompt.language
    let refCodes = clonePrompt.refCodes

    // Step 1: Prepare ICL inputs
    let (inputEmbeds, trailingTextHidden, ttsPadEmbed) = try prepareICLInputs(
        text: text,
        refCodes: refCodes,
        speakerEmbedding: clonePrompt.speakerEmbedding,
        refText: clonePrompt.refText,
        language: effectiveLanguage,
        instruct: instruct
    )

    // Step 2: Cap max tokens based on text length
    let targetTokenCount = tokenizer.encode(text: text).count
    let effectiveMaxTokens = min(maxTokens, max(200, targetTokenCount * 12))

+   // Step 2.5: Adaptive temperature scaling
+   let estimatedCodes = targetTokenCount * 4
+   let temperatureScaleFactor: Float = 0.3
+   let maxCodesForScaling: Float = 400.0
+   let scalingRatio = min(1.0, Float(estimatedCodes) / maxCodesForScaling)
+   let adaptiveTemperature = temperature * (1.0 - temperatureScaleFactor * scalingRatio)
+   FileHandle.standardError.write(Data(
+       "[AdaptiveTemp] estimatedCodes=\(estimatedCodes), scalingRatio=\(String(format: "%.3f", scalingRatio)), baseTemp=\(temperature), adaptiveTemp=\(String(format: "%.3f", adaptiveTemperature))\n".utf8
+   ))

    // Step 3: Use caller's repetition penalty
    let effectiveRepPenalty = repetitionPenalty

    // Telemetry: Log effective generation parameters
    FileHandle.standardError.write(Data("[ICL] refText=\"\(clonePrompt.refText.prefix(50))\", targetText=\"\(text.prefix(50))\"\n".utf8))
    FileHandle.standardError.write(Data("[ICL] targetTokens=\(targetTokenCount), effectiveMaxTokens=\(effectiveMaxTokens), effectiveRepPenalty=\(effectiveRepPenalty)\n".utf8))
    FileHandle.standardError.write(Data("[ICL] refCodes shape=\(refCodes.shape), speakerEmbedding=\(clonePrompt.speakerEmbedding != nil)\n".utf8))

    // Step 4: Run shared autoregressive generation loop
    let generatedCodes = generateFromEmbeddings(
        inputEmbeds: inputEmbeds,
        trailingTextHidden: trailingTextHidden,
        ttsPadEmbed: ttsPadEmbed,
-       temperature: temperature,
+       temperature: adaptiveTemperature,
        topP: topP,
        repetitionPenalty: effectiveRepPenalty,
        maxTokens: effectiveMaxTokens
    )

    // ... rest unchanged
```

## Testing

### 1. Re-render Chapter 2

```bash
cd /Users/stovak/Projects/podcast-tao-de-jing
bin/produciesta generate episodes/chapter-02.fountain \
    --output episodes/audio/chapter-02-adaptive-temp.m4a \
    --verbose > episodes/chapter-02-adaptive-temp.log 2>&1
```

### 2. Check telemetry logs

```bash
grep "AdaptiveTemp" episodes/chapter-02-adaptive-temp.log
```

Expected output for element 11 (421 chars, ~77 text tokens, ~308 estimated codes):

```
[AdaptiveTemp] estimatedCodes=308, scalingRatio=0.770, baseTemp=0.7, adaptiveTemp=0.538
```

For element 12 (502 chars, ~96 text tokens, ~384 estimated codes):

```
[AdaptiveTemp] estimatedCodes=384, scalingRatio=0.960, baseTemp=0.7, adaptiveTemp=0.499
```

### 3. Compare drift

Listen to:
- `episodes/audio/chapter-02.m4a` (original, temp=0.7)
- `episodes/audio/chapter-02-adaptive-temp.m4a` (adaptive temp, ~0.5 for long segments)

Expected: Less prosodic variance in long expositions, possibly flatter but more consistent.

### 4. Verify prosody quality

- **Reduced drift?** Yes, less wander in long passages
- **Too flat?** If yes, reduce `temperatureScaleFactor` from 0.3 to 0.2 or 0.15
- **Still expressive in short segments?** Yes, short segments use near-full temperature

## Tuning Parameters

### `temperatureScaleFactor` (Default: 0.3)

Controls how much to reduce temperature:

- **0.15**: Gentle reduction (0.7 → 0.595 for 400-code gen) — more expressive, less drift reduction
- **0.3**: Moderate reduction (0.7 → 0.49) — balanced (recommended)
- **0.5**: Aggressive reduction (0.7 → 0.35) — very stable, may sound robotic

### `maxCodesForScaling` (Default: 400)

Threshold at which full scaling kicks in:

- **300**: Earlier scaling, affects 15s+ utterances
- **400**: Recommended, affects 20s+ utterances
- **500**: Later scaling, only affects 25s+ utterances

## Success Criteria

- [ ] Adaptive temperature logged correctly in telemetry
- [ ] Long segments (>20s) use reduced temperature (~0.5)
- [ ] Short segments (<10s) use near-full temperature (~0.65-0.7)
- [ ] Reduced prosodic variance in long expositions
- [ ] No robotic/flat delivery in short conversational segments

## Notes

- This fix is **complementary** to adaptive repetition penalty and auto-chunking
- Temperature scaling alone won't eliminate drift (reference-anchor dilution is dominant)
- Combined with adaptive repPenalty, this reduces drift severity
- Auto-chunking (implemented separately) is the primary fix
- This is a conservative companion fix with minimal downside
