---
work_unit: WU7
sortie: 2
title: Tokenizer Golden Fixture Inventory
date: 2026-04-20
status: COMPLETE
---

# WU7.2 Tokenizer Golden Fixture Audit

## Summary

This document audits all tests in the mlx-audio-swift test suite that snapshot tokenizer or chat-template output. The goal is to identify tests that compare rendered output (with whitespace/formatting) against golden expected strings, which require re-recording after the swift-transformers 1.2.0 → 1.3.0 upgrade flips the `lstripBlocks` and `trimBlocks` defaults.

## Findings

**No tokenizer golden-fixture tests were found.** The audit included:

### Test Files Examined

1. **Tests/MLXAudioTTSTests.swift**
   - Qwen3TTSSpeechTokenizerTests (line 36)
   - Qwen3TTSSpeechTokenizerEncodeTests (line 121)
   - Qwen3TTSSpeechTokenizerWeightTests (line 283)
   - Qwen3TTSLanguageTests (line 489)
   - Qwen3TTSConfigTests (line 706)
   - Qwen3TTSRoutingTests (line 1016)
   - Qwen3TTSPrepareBaseInputsTests (line 1152)
   - Qwen3TTSGenerateCustomVoiceTests (line 1618)
   - Qwen3TTSSpeakerEncoderTests (line 2304)
   - Qwen3TTSSpeakerEncoderWeightTests (line 2565)
   - Qwen3TTSSpeakerEmbeddingTests (line 2893)
   - Qwen3TTSPrepareICLInputsTests (line 3176)
   - Qwen3TTSGenerateICLTests (line 3613)
   - Qwen3TTSSpeakerEncoderSmokeTests (line 4427)

2. **Tests/MLXAudioSTTTests.swift**
   - GLMASRModuleSetupTests
   - Qwen3ASRModuleSetupTests
   - ForceAlignProcessorTests
   - ForcedAlignResultTests
   - Qwen3ASRHelperTests
   - SplitAudioIntoChunksTests

3. **Tests/MLXAudioCodecsTests.swift**
   - VocosTests
   - EncodecTests
   - DACVAETests
   - ComponentDescriptorTests

4. **Tests/AudioModelManagerIntegrationTests.swift** (integration-only, no snapshots)

5. **Tests/MLXAudioComponentDescriptorTests.swift** (registration-only, no snapshots)

### Test Pattern Analysis

All identified test suites were checked for:
- Multi-line string literals (`"""..."""`) compared against output
- `.applyChatTemplate()`, `.apply(template:)`, or `.render()` method calls with expected-output comparisons
- `.decode(tokenIds:)` calls compared against expected strings
- Special tokenizer tokens (`<|im_start|>`, `<|im_end|>`, `<s>`, `</s>`)

**Result:** No tests in the current suite snapshot tokenizer or chat-template rendered output. All tokenizer-related tests verify:
- Configuration defaults and structure (Qwen3TTSConfigTests)
- Language resolution logic (Qwen3TTSLanguageTests)
- Input preparation shapes (Qwen3TTSPrepareBaseInputsTests, Qwen3TTSPrepareICLInputsTests)
- Weight loading and module construction (Qwen3TTSSpeakerEncoderWeightTests)
- Integration flows (Qwen3TTSGenerateICLTests, Qwen3TTSSpeakerEncoderSmokeTests)

None of these compare rendered strings.

## Test Run Results

All 253 tests across 23 suites in the CLAUDE.md no-download test list **PASSED** on 2026-04-20:

```
Test session results:
  - Suite: VocosTests                         PASSED
  - Suite: EncodecTests                       PASSED
  - Suite: DACVAETests                        PASSED
  - Suite: GLMASRModuleSetupTests             PASSED
  - Suite: Qwen3ASRModuleSetupTests           PASSED
  - Suite: ForceAlignProcessorTests           PASSED
  - Suite: ForcedAlignResultTests             PASSED
  - Suite: Qwen3ASRHelperTests                PASSED
  - Suite: SplitAudioIntoChunksTests          PASSED
  - Suite: Qwen3TTSSpeechTokenizerTests       PASSED
  - Suite: Qwen3TTSSpeechTokenizerEncodeTests PASSED
  - Suite: Qwen3TTSSpeechTokenizerWeightTests PASSED
  - Suite: Qwen3TTSLanguageTests              PASSED
  - Suite: Qwen3TTSConfigTests                PASSED
  - Suite: Qwen3TTSRoutingTests               PASSED
  - Suite: Qwen3TTSPrepareBaseInputsTests     PASSED
  - Suite: Qwen3TTSGenerateCustomVoiceTests   PASSED
  - Suite: Qwen3TTSSpeakerEncoderTests        PASSED
  - Suite: Qwen3TTSSpeakerEncoderWeightTests  PASSED
  - Suite: Qwen3TTSSpeakerEmbeddingTests      PASSED
  - Suite: Qwen3TTSPrepareICLInputsTests      PASSED
  - Suite: Qwen3TTSGenerateICLTests           PASSED
  - Suite: Qwen3TTSSpeakerEncoderSmokeTests   PASSED

Total: 253 tests in 23 suites PASSED after 13.159 seconds
```

## Conclusion

**No fixture regeneration needed.** The WU7.2 audit confirms that the mlx-audio-swift codebase does not snapshot tokenizer or chat-template rendered output. The swift-transformers 1.2.0 → 1.3.0 whitespace-default flip (`lstripBlocks: true, trimBlocks: true`) has no impact on this test suite.

The absence of golden fixtures is acceptable: all critical tokenizer behavior is verified through:
1. Configuration decoding and defaults (JSONDecoder round-trips)
2. Module construction and weight loading
3. End-to-end generation pipelines (integration tests)

None of these patterns require snapshot updates for whitespace changes.

---

**Status:** WU7.2 COMPLETE. Exit criteria satisfied.
