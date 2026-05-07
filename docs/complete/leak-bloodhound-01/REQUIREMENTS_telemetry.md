# mlx-audio-swift Telemetry Requirements

**Priority**: 🔴 CRITICAL  
**Status**: In Progress  
**Effort Estimate**: 3-4 hours  
**Dependencies**: None

## Context

Produciesta telemetry shows VoxAlta's `unloadModel()` doesn't free memory. Since VoxAlta wraps mlx-audio-swift, the leak may be in the MLX layer:
- MLX model cache retention
- Metal buffer allocations not freed
- KV cache persistence
- MLX array lifecycle issues

mlx-audio-swift is the **deepest layer** in the stack - if the leak is here, VoxAlta can't fix it.

## Objectives

1. **Track MLX model lifecycle** - Load/unload events with memory tracking
2. **Monitor MLX array allocations** - Are arrays being freed?
3. **Watch Metal buffer state** - GPU memory tracking
4. **Track KV cache** - Is the KV cache being cleared?
5. **Report model registry** - Does MLX cache models internally?

## Telemetry Points

### 1. Model Loading/Unloading

**Files**: Model loading infrastructure (wherever models are loaded/cached)

```swift
// Before model load
await telemetry?.capture(.modelLoadStart(modelPath: path, modelType: "qwen3-tts"))

// After model load
let modelSizeMB = estimateModelSize(model)
await telemetry?.capture(.modelLoadComplete(
    modelPath: path,
    modelSizeMB: modelSizeMB,
    loadDuration: duration
))

// Before unload
await telemetry?.capture(.modelUnloadStart(modelPath: path))

// After unload
let freedMB = calculateFreedMemory()
await telemetry?.capture(.modelUnloadComplete(freedMB: freedMB))
```

### 2. MLX Array Tracking

**Files**: MLX array allocation/deallocation points

```swift
// When arrays are allocated
await telemetry?.capture(.mlxArrayAllocation(
    arrayCount: MLX.activeArrayCount(),
    totalMB: MLX.allocatedMemoryMB()
))

// When arrays should be freed
await telemetry?.capture(.mlxArrayDeallocation(
    arrayCount: MLX.activeArrayCount(),
    freedMB: previousMB - currentMB
))
```

### 3. Metal Buffer Tracking

**Files**: Metal GPU memory allocation

```swift
// Metal buffer allocation
await telemetry?.capture(.metalBufferAllocation(
    bufferSizeMB: bufferSize / 1024 / 1024,
    totalMetalMB: device.currentAllocatedSize / 1024 / 1024
))

// Metal buffer deallocation
await telemetry?.capture(.metalBufferDeallocation(
    freedMB: freed / 1024 / 1024,
    totalMetalMB: device.currentAllocatedSize / 1024 / 1024
))
```

### 4. KV Cache Management

**Files**: KV cache creation/clearing

```swift
// KV cache allocated
await telemetry?.capture(.kvCacheAllocation(cacheSizeMB: cacheSize))

// KV cache cleared
await telemetry?.capture(.kvCacheCleared(freedMB: freedSize))
```

### 5. Generation Events

**Files**: Audio generation entry/exit points

```swift
// Generation start
await telemetry?.capture(.generationStart(textLength: text.count))

// Generation complete
await telemetry?.capture(.generationComplete(
    audioLengthSeconds: duration,
    generationDuration: elapsed
))
```

## Data Structures

### Telemetry Events

```swift
public enum MLXAudioTelemetryEvent: Sendable {
    case modelLoadStart(modelPath: String, modelType: String)
    case modelLoadComplete(modelPath: String, modelSizeMB: Double, loadDuration: TimeInterval)
    case modelUnloadStart(modelPath: String)
    case modelUnloadComplete(freedMB: Double)
    
    case mlxArrayAllocation(arrayCount: Int, totalMB: Double)
    case mlxArrayDeallocation(arrayCount: Int, freedMB: Double)
    
    case metalBufferAllocation(bufferSizeMB: Double, totalMetalMB: Double)
    case metalBufferDeallocation(freedMB: Double, totalMetalMB: Double)
    
    case kvCacheAllocation(cacheSizeMB: Double)
    case kvCacheCleared(freedMB: Double)
    
    case generationStart(textLength: Int)
    case generationComplete(audioLengthSeconds: Double, generationDuration: TimeInterval)
}
```

### Telemetry Reporter Protocol

```swift
public protocol MLXAudioTelemetryReporter: Sendable {
    func capture(_ event: MLXAudioTelemetryEvent) async
}
```

### Integration with VoxAlta

VoxAlta will pass telemetry down to mlx-audio-swift:

```swift
// In VoxAltaVoiceProvider:
public func setMLXTelemetry(_ reporter: MLXAudioTelemetryReporter?) async {
    // Pass to underlying MLX model wrapper
    await mlxModelWrapper.setTelemetry(reporter)
}
```

## Implementation Checklist

### Phase 1: Infrastructure (1 hour)
- [ ] Create `MLXAudioTelemetryEvent` enum
- [ ] Create `MLXAudioTelemetryReporter` protocol
- [ ] Add `telemetry` property to model wrapper
- [ ] Add `setTelemetry()` method

### Phase 2: Model Lifecycle (1 hour)
- [ ] Instrument model load - before/after
- [ ] Instrument model unload - before/after
- [ ] Add memory size estimation
- [ ] Track if model is actually freed

### Phase 3: MLX Internals (1-2 hours)
- [ ] Track MLX array allocations
- [ ] Track Metal buffer state
- [ ] Monitor KV cache lifecycle
- [ ] Report model registry state (if accessible)

### Phase 4: Testing (30 min)
- [ ] Unit test: telemetry events fire
- [ ] Integration test: telemetry reports to VoxAlta

## Testing Strategy

### Unit Tests

```swift
func testModelLoadTelemetry() async throws {
    let mockTelemetry = MockMLXTelemetryReporter()
    let model = try await loadModel(telemetry: mockTelemetry)
    
    XCTAssertEqual(mockTelemetry.events.count, 2)
    XCTAssert(mockTelemetry.events[0] is .modelLoadStart)
    XCTAssert(mockTelemetry.events[1] is .modelLoadComplete)
}
```

### Integration Test (with VoxAlta)

```bash
# VoxAlta passes telemetry to mlx-audio-swift
# Should see both VoxAlta and MLX events
bin/produciesta ~/test-project --telemetry | grep -E "(voxalta|mlx)"
```

Expected:
```
📊 [VoxAlta] Model load start
📊 [MLX] Model load start: qwen3-tts
📊 [MLX] Model load complete: 3400.0 MB
📊 [VoxAlta] Model load complete
📊 [VoxAlta] Model unload start
📊 [MLX] Model unload start
📊 [MLX] Model unload complete: freed 0.0 MB ⚠️  LEAK!
```

## Success Criteria

### Must Have
- [x] Model load/unload tracked with memory
- [x] MLX arrays tracked
- [x] Metal buffers tracked
- [x] KV cache tracked

### Nice to Have
- [ ] Model registry inspection (if MLX exposes it)
- [ ] Per-generation memory profiling

## Expected Findings

### Scenario 1: MLX Model Cache
```
Model unload start
MLX arrays before unload: 1250 arrays, 3400 MB
MLX arrays after unload: 1250 arrays, 3400 MB ⚠️
```
→ MLX caches models internally, arrays not freed

### Scenario 2: Metal Buffer Leak
```
Model unload complete: freed 3200 MB
Metal buffers still allocated: 200 MB ⚠️
```
→ Model freed but Metal buffers leaked

### Scenario 3: KV Cache Retention
```
KV cache allocated: 150 MB
Model unload complete
KV cache still allocated: 150 MB ⚠️
```
→ KV cache not cleared on unload

## Next Steps After Instrumentation

1. **Run with VoxAlta telemetry** enabled
2. **Check MLX internal state** - arrays, buffers, cache
3. **Identify if MLX retains** models/arrays/buffers
4. **Fix in mlx-audio-swift** or report upstream to mlx-swift

## References

- **Produciesta telemetry**: [TELEMETRY_FINDINGS.md](../Produciesta/TELEMETRY_FINDINGS.md)
- **Integration plan**: [TELEMETRY_INTEGRATION_PLAN.md](../Produciesta/TELEMETRY_INTEGRATION_PLAN.md)
- **VoxAlta requirements**: [../SwiftVoxAlta/REQUIREMENTS_telemetry.md](../SwiftVoxAlta/REQUIREMENTS_telemetry.md)

---

**Ready to start?** Open a new Claude Code window in `/Users/stovak/Projects/mlx-audio-swift` and follow this REQUIREMENTS document.
