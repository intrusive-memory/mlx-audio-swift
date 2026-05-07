//
//  TelemetryCodecLifecycleSmokeTests.swift
//  MLXAudioTests
//
//  Sortie 7 of OPERATION LEAK BLOODHOUND — Codec model lifecycle hook coverage.
//  Exercises the paired `init`/`deinit` Telemetry.trackLifecycle call sites
//  added to the 5 codec model classes in S7.
//
//  Each test:
//    1. Resets the shared CounterStore.
//    2. Constructs the codec model with a synthetic config (no model download).
//    3. Waits for the fire-and-forget increment Task to land.
//    4. Drops the model (sets the binding to nil).
//    5. Waits for the fire-and-forget decrement Task to land.
//    6. Asserts `snapshot.liveCounts["<Codec>.Model"] == 0`.
//
//  All five codec families (SNAC, Mimi, Encodec, DAC, Vocos) use synthetic
//  configs / direct inits — no model downloads are required. All are CI-safe.
//
//  Concurrency: the suite is `.serialized` — every test mutates the shared
//  CounterStore singleton and calls `Telemetry.resetCounters()`.
//

import Foundation
import Testing
import MLX
import MLXNN

@testable import MLXAudioCore
@testable import MLXAudioCodecs

@Suite("TelemetryCodecLifecycleSmokeTests", .serialized)
struct TelemetryCodecLifecycleSmokeTests {

    // MARK: - Helpers

    private func resetForTest() async {
        await Telemetry.resetCounters()
    }

    /// Poll the counter store until the key reaches `target` or the attempt
    /// budget is exhausted (200 × 1 ms = up to 200 ms). Background-priority
    /// Tasks need an explicit `Task.sleep` to be scheduled.
    private func waitForCounter(
        _ key: String,
        target: Int,
        attempts: Int = 200
    ) async -> TelemetrySnapshot {
        var snap = await Telemetry.snapshot()
        for _ in 0..<attempts {
            if (snap.liveCounts[key] ?? 0) == target { return snap }
            try? await Task.sleep(nanoseconds: 1_000_000) // 1 ms
            snap = await Telemetry.snapshot()
        }
        return snap
    }

    // MARK: - SNAC.Model (CI-safe — synthetic config, no download)

    @Test("SNAC model lifecycle: liveCount returns to 0 after deinit")
    func snacModelLifecycle() async {
        await resetForTest()

        let key = "SNAC.Model"
        // Use the default parameters from SNAC.init — matches the config used
        // by SNACVQTests and SNACDecoder.swift fromConfig path. No download needed.
        var model: SNAC? = SNAC(
            samplingRate: 44100,
            encoderDim: 8,
            encoderRates: [2, 2],
            latentDim: nil,
            decoderDim: 16,
            decoderRates: [2, 2],
            attnWindowSize: nil,
            codebookSize: 64,
            codebookDim: 8,
            vqStrides: [2, 1],
            noise: false,
            depthwise: false
        )

        let snap = await waitForCounter(key, target: 1)
        #expect(snap.liveCounts[key] == 1, "Expected liveCount[\(key)] == 1 after init")

        model = nil

        let after = await waitForCounter(key, target: 0)
        #expect(
            after.liveCounts[key, default: 0] == 0,
            "Expected liveCount[\(key)] == 0 after deinit; observed \(after.liveCounts[key, default: 0])"
        )
    }

    // MARK: - Mimi.Model (CI-safe — synthetic config, no download)

    @Test("Mimi model lifecycle: liveCount returns to 0 after deinit")
    func mimiModelLifecycle() async {
        await resetForTest()

        let key = "Mimi.Model"
        // Use mimi_202407 with a tiny codebook count (1) to keep memory small.
        // This mirrors what MimiLayerTests uses for layer-level construction.
        let cfg = mimi_202407(numCodebooks: 1)
        var model: Mimi? = Mimi(cfg: cfg)

        let snap = await waitForCounter(key, target: 1)
        #expect(snap.liveCounts[key] == 1, "Expected liveCount[\(key)] == 1 after init")

        model = nil

        let after = await waitForCounter(key, target: 0)
        #expect(
            after.liveCounts[key, default: 0] == 0,
            "Expected liveCount[\(key)] == 0 after deinit; observed \(after.liveCounts[key, default: 0])"
        )
    }

    // MARK: - Encodec.Model (CI-safe — synthetic config, no download)

    @Test("Encodec model lifecycle: liveCount returns to 0 after deinit")
    func encodecModelLifecycle() async {
        await resetForTest()

        let key = "Encodec.Model"
        // Use default EncodecConfig — matches EncodecTests.testEncodecModel().
        let config = EncodecConfig()
        var model: Encodec? = Encodec(config: config)

        let snap = await waitForCounter(key, target: 1)
        #expect(snap.liveCounts[key] == 1, "Expected liveCount[\(key)] == 1 after init")

        model = nil

        let after = await waitForCounter(key, target: 0)
        #expect(
            after.liveCounts[key, default: 0] == 0,
            "Expected liveCount[\(key)] == 0 after deinit; observed \(after.liveCounts[key, default: 0])"
        )
    }

    // MARK: - DAC.Model (CI-safe — synthetic small config, no download)

    @Test("DACVAE model lifecycle: liveCount returns to 0 after deinit")
    func dacModelLifecycle() async {
        await resetForTest()

        let key = "DAC.Model"
        // Use tiny config — matches DACVAETests.testDACVAEModel().
        let config = DACVAEConfig(
            encoderDim: 32,
            encoderRates: [2, 4],
            latentDim: 64,
            decoderDim: 64,
            decoderRates: [4, 2],
            codebookDim: 32
        )
        var model: DACVAE? = DACVAE(config: config)

        let snap = await waitForCounter(key, target: 1)
        #expect(snap.liveCounts[key] == 1, "Expected liveCount[\(key)] == 1 after init")

        model = nil

        let after = await waitForCounter(key, target: 0)
        #expect(
            after.liveCounts[key, default: 0] == 0,
            "Expected liveCount[\(key)] == 0 after deinit; observed \(after.liveCounts[key, default: 0])"
        )
    }

    // MARK: - Vocos.Model (CI-safe — synthetic config, no download)

    @Test("Vocos model lifecycle: liveCount returns to 0 after deinit")
    func vocosModelLifecycle() async {
        await resetForTest()

        let key = "Vocos.Model"
        // Matches VocosTests.testVocosModel() — tiny backbone + head.
        let backbone = VocosBackbone(
            inputChannels: 32,
            dim: 64,
            intermediateDim: 128,
            numLayers: 2
        )
        let head = ISTFTHead(dim: 64, nFft: 256, hopLength: 64)
        var model: Vocos? = Vocos(backbone: backbone, head: head)

        let snap = await waitForCounter(key, target: 1)
        #expect(snap.liveCounts[key] == 1, "Expected liveCount[\(key)] == 1 after init")

        model = nil

        let after = await waitForCounter(key, target: 0)
        #expect(
            after.liveCounts[key, default: 0] == 0,
            "Expected liveCount[\(key)] == 0 after deinit; observed \(after.liveCounts[key, default: 0])"
        )
    }
}
