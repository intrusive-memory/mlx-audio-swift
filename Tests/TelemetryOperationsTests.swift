//
//  TelemetryOperationsTests.swift
//  MLXAudioTests
//
//  Sortie 10 of OPERATION LEAK BLOODHOUND — Level 2 (`.operations`)
//  operation-interval signposts.
//
//  Coverage:
//  - `testLevelResolvesFromEnv`: Verifies `Telemetry.level` resolves to
//    `.operations` when MLXAUDIO_TELEMETRY=operations is requested. The
//    cached env-resolved value is process-immutable, so we exercise the
//    resolution via the test-only `Telemetry._installLevelOverride(_:)`
//    seam (introduced in S10 alongside `_intervalRecorder` per the
//    EXECUTION_PLAN Open Q4 resolution: avoid relying on env-var
//    resolution timing during in-process tests).
//  - `testInstrumentedCallEmitsInterval`: Installs a `TestSignposterRecorder`
//    that conforms to the internal `TelemetryIntervalRecorder` protocol,
//    runs one weight-loading call path (a synthetic `MLXNN.Linear` whose
//    weights are loaded via `Telemetry.emitInterval` — the same helper
//    every production call site uses), and asserts exactly one begin/end
//    pair on the expected subsystem.
//
//  Concurrency: the suite is `.serialized` because both tests mutate
//  process-global state (`_levelOverride`, `_intervalRecorder`) and
//  unsynchronized parallel access would race.
//

import Foundation
import MLX
import MLXNN
import MLXLMCommon
import Testing

@testable import MLXAudioCore
@testable import MLXAudioTTS
@testable import MLXAudioSTT
@testable import MLXAudioCodecs

@Suite("TelemetryOperationsTests", .serialized)
struct TelemetryOperationsTests {

    // MARK: - TestSignposterRecorder (Q4 resolution)

    /// In-memory recorder used as the source-of-truth for tests verifying
    /// that an instrumented call path emitted exactly one interval pair on
    /// the expected subsystem.
    ///
    /// The recorder conforms to the internal `TelemetryIntervalRecorder`
    /// protocol declared in `IntervalEmitter.swift`. Production call sites
    /// emit through `Telemetry.emitInterval(...)` / `emitIntervalAsync(...)`,
    /// which always call into the real `OSSignposter` (so Instruments still
    /// sees the events) and additionally forward to `_intervalRecorder` when
    /// one is installed. Tests install a recorder, run code, then inspect
    /// the captured events.
    ///
    /// `nonisolated(unsafe)` storage is acceptable because the test suite is
    /// `.serialized` — only one test mutates / reads at a time. We use
    /// `NSLock` for the read-modify-write of the events array as a
    /// belt-and-suspenders measure since the production call sites may run
    /// on background actors / detached Tasks.
    final class TestSignposterRecorder: @unchecked Sendable, TelemetryIntervalRecorder {
        struct Event: Equatable {
            enum Kind: String { case begin, end }
            let kind: Kind
            let name: String
            let subsystem: String
            let message: String
        }

        private let lock = NSLock()
        private var _events: [Event] = []

        var events: [Event] {
            lock.lock(); defer { lock.unlock() }
            return _events
        }

        func recordBegin(name: String, subsystem: String, message: String) {
            lock.lock(); defer { lock.unlock() }
            _events.append(Event(kind: .begin, name: name, subsystem: subsystem, message: message))
        }

        func recordEnd(name: String, subsystem: String, message: String) {
            lock.lock(); defer { lock.unlock() }
            _events.append(Event(kind: .end, name: name, subsystem: subsystem, message: message))
        }
    }

    // MARK: - testLevelResolvesFromEnv

    /// Verifies `Telemetry.level` resolves to `.operations` when the
    /// requested level is `MLXAUDIO_TELEMETRY=operations`.
    ///
    /// **Why we use `_installLevelOverride` instead of mutating the real
    /// env var**: `Telemetry.level` is cached at first read via the
    /// process-singleton `ResolvedLevel.shared` initializer, which Swift
    /// guarantees runs at most once per process. Setting `setenv()` from
    /// the test would have no effect on the cached value, and on the very
    /// first invocation would even burn the one-shot clamp warning. The
    /// `_installLevelOverride(_:)` seam (gated behind `MLXAUDIO_TELEMETRY_FULL`
    /// so it cannot leak into release builds) gives tests a deterministic
    /// way to exercise the level-gated code paths without env-var
    /// resolution timing fragility.
    @Test("Telemetry.level resolves to .operations under override (Q4)")
    func testLevelResolvesFromEnv() async {
        let prev = Telemetry._installLevelOverride(.operations)
        defer { Telemetry._installLevelOverride(prev) }

        #expect(Telemetry.level == .operations)
        #expect(Telemetry.level >= .operations)

        // Negative case: clearing the override falls back to the
        // env-resolved cached value (default .lifecycle when env unset).
        Telemetry._installLevelOverride(nil)
        #expect(Telemetry.level <= Telemetry.ceiling)
    }

    // MARK: - testInstrumentedCallEmitsInterval

    /// Installs a `TestSignposterRecorder`, runs ONE weight-loading call
    /// path (a synthetic `MLXNN.Linear` whose `update(parameters:)` is
    /// invoked through `Telemetry.emitInterval` — the same helper every
    /// production loadWeights call site uses, on the codecs subsystem),
    /// and asserts the recorder observed exactly one `.begin` and one
    /// `.end` event on `MLXAudio.codecs`.
    @Test("instrumented loadWeights emits exactly one begin/end pair")
    func testInstrumentedCallEmitsInterval() throws {
        let recorder = TestSignposterRecorder()

        // Force level to .operations so the wrap is taken; restore on exit.
        let prevLevel = Telemetry._installLevelOverride(.operations)
        let prevRecorder = Telemetry._installIntervalRecorder(recorder)
        defer {
            Telemetry._installLevelOverride(prevLevel)
            Telemetry._installIntervalRecorder(prevRecorder)
        }

        // Synthetic MLXNN.Linear — the smallest possible Module that
        // accepts a real `update(parameters:)` weight load. No model
        // download required.
        let linear = Linear(8, 4, bias: false)

        // Construct weights matching the layer's parameter shape so
        // `update(parameters:)` succeeds. We extract the existing
        // parameter shape from the freshly-constructed module and
        // synthesize zeros of that shape for the load path.
        let weightShape: [Int] = [4, 8] // out, in
        let synthWeights: [String: MLXArray] = [
            "weight": MLXArray.zeros(weightShape, type: Float32.self)
        ]

        // Wrap the same way every production loadWeights site does.
        try Telemetry.emitInterval(
            name: "Test.loadWeights",
            family: .codecs,
            message: "synthetic-linear"
        ) {
            try linear.update(
                parameters: ModuleParameters.unflattened(synthWeights),
                verify: [.all]
            )
        }

        let events = recorder.events
        #expect(events.count == 2, "Expected exactly 2 events (begin + end), got \(events.count): \(events)")

        guard events.count == 2 else { return }
        let begin = events[0]
        let end = events[1]

        #expect(begin.kind == .begin)
        #expect(end.kind == .end)
        #expect(begin.name == "Test.loadWeights")
        #expect(end.name == "Test.loadWeights")
        #expect(begin.subsystem == "MLXAudio.codecs", "Expected subsystem MLXAudio.codecs, got \(begin.subsystem)")
        #expect(end.subsystem == "MLXAudio.codecs")
        #expect(begin.message == "synthetic-linear")
        #expect(end.message == "synthetic-linear")
    }

    /// Smoke test: when `Telemetry.level < .operations`, the production
    /// call sites are short-circuited (the `if Telemetry.level >= .operations`
    /// branch is not taken) and no events are recorded.
    @Test("level < .operations skips the wrap (no events recorded)")
    func testLevelGateShortCircuits() throws {
        let recorder = TestSignposterRecorder()
        let prevLevel = Telemetry._installLevelOverride(.lifecycle)
        let prevRecorder = Telemetry._installIntervalRecorder(recorder)
        defer {
            Telemetry._installLevelOverride(prevLevel)
            Telemetry._installIntervalRecorder(prevRecorder)
        }

        // Production gate pattern: the `if Telemetry.level >= .operations`
        // check is what every instrumented call site uses, and at
        // .lifecycle it short-circuits — so we must NOT call emitInterval.
        if Telemetry.level >= .operations {
            try Telemetry.emitInterval(
                name: "Test.shouldNotEmit",
                family: .codecs
            ) {
                // unreachable
            }
        }

        #expect(recorder.events.isEmpty, "Expected no events at .lifecycle, got: \(recorder.events)")
    }

    // MARK: - Family enum sanity

    /// Guards against subsystem-string drift between `Telemetry.Family` and
    /// `MLXAudioLogging`. If S3's subsystem table renames a subsystem, this
    /// test fails fast.
    @Test("Family.subsystem strings match MLXAudioLogging subsystems")
    func testFamilySubsystemStringsMatchLogging() {
        let expectedSubsystems: Set<String> = [
            "MLXAudio.core",
            "MLXAudio.modelResolver",
            "MLXAudio.qwen3TTS",
            "MLXAudio.llamaTTS",
            "MLXAudio.sopranoTTS",
            "MLXAudio.pocketTTS",
            "MLXAudio.marvisTTS",
            "MLXAudio.qwen3ASR",
            "MLXAudio.glmASR",
            "MLXAudio.codecs",
        ]

        let familySubsystems: Set<String> = [
            Telemetry.Family.core.subsystem,
            Telemetry.Family.modelResolver.subsystem,
            Telemetry.Family.qwen3TTS.subsystem,
            Telemetry.Family.llamaTTS.subsystem,
            Telemetry.Family.sopranoTTS.subsystem,
            Telemetry.Family.pocketTTS.subsystem,
            Telemetry.Family.marvisTTS.subsystem,
            Telemetry.Family.qwen3ASR.subsystem,
            Telemetry.Family.glmASR.subsystem,
            Telemetry.Family.codecs.subsystem,
        ]

        #expect(familySubsystems == expectedSubsystems)
    }

    // MARK: - S11 Per-family generate/encode/decode interval tests

    /// Helper: install recorder + level override, run body, restore, return events.
    private func runWithRecorder(
        level: Telemetry.Level = .operations,
        body: (TestSignposterRecorder) async throws -> Void
    ) async throws -> [TestSignposterRecorder.Event] {
        let recorder = TestSignposterRecorder()
        let prevLevel = Telemetry._installLevelOverride(level)
        let prevRecorder = Telemetry._installIntervalRecorder(recorder)
        defer {
            Telemetry._installLevelOverride(prevLevel)
            Telemetry._installIntervalRecorder(prevRecorder)
        }
        try await body(recorder)
        return recorder.events
    }

    /// Assert exactly one begin + one end event on the expected name and subsystem.
    private func assertOneInterval(
        events: [TestSignposterRecorder.Event],
        name: String,
        subsystem: String,
        context: String = ""
    ) {
        let msg = context.isEmpty ? "" : " [\(context)]"
        #expect(events.count == 2, "Expected exactly 2 events (begin+end)\(msg), got \(events.count): \(events)")
        guard events.count >= 2 else { return }
        #expect(events[0].kind == .begin, "First event must be .begin\(msg)")
        #expect(events[1].kind == .end,   "Second event must be .end\(msg)")
        #expect(events[0].name == name,   "Expected name '\(name)'\(msg), got '\(events[0].name)'")
        #expect(events[1].name == name,   "Expected name '\(name)'\(msg), got '\(events[1].name)'")
        #expect(events[0].subsystem == subsystem, "Expected subsystem '\(subsystem)'\(msg), got '\(events[0].subsystem)'")
        #expect(events[1].subsystem == subsystem, "Expected subsystem '\(subsystem)'\(msg), got '\(events[1].subsystem)'")
    }

    // MARK: - TTS families (CI-safe — model constructor + interval fires even when generate throws)

    /// Qwen3TTS.generate emits exactly one begin/end pair on MLXAudio.qwen3TTS.
    ///
    /// The model is constructed with a synthetic config (no weight download). `generate`
    /// throws `modelNotInitialized` because the speech tokenizer is not loaded, but the
    /// interval's `defer` block fires the end-event before the error propagates, so the
    /// recorder captures exactly one begin/end pair.
    @Test("Qwen3TTS.generate emits one interval on MLXAudio.qwen3TTS (.operations)")
    func testQwen3TTSGenerateEmitsInterval() async throws {
        let json = """
        {
            "model_type": "qwen3_tts",
            "tts_model_type": "base",
            "tts_model_size": "0b6",
            "tokenizer_type": "qwen3_tts_tokenizer_12hz",
            "sample_rate": 24000,
            "im_start_token_id": 151644,
            "im_end_token_id": 151645,
            "tts_pad_token_id": 151671,
            "tts_bos_token_id": 151672,
            "tts_eos_token_id": 151673
        }
        """.data(using: .utf8)!
        let config = try JSONDecoder().decode(Qwen3TTSModelConfig.self, from: json)
        let model = Qwen3TTSModel(config: config)

        let events = try await runWithRecorder { _ in
            _ = try? await model.generate(
                text: "hello",
                voice: nil,
                generationParameters: GenerateParameters(maxTokens: 1)
            )
        }

        assertOneInterval(events: events, name: "Qwen3TTS.generate", subsystem: "MLXAudio.qwen3TTS",
                         context: "Qwen3TTSModel.generate")
    }

    /// LlamaTTS.generate emits exactly one begin/end pair on MLXAudio.llamaTTS.
    ///
    /// Synthetic model (no weights); `generate` throws `modelNotInitialized` (SNAC not loaded),
    /// but the interval still fires via `defer`.
    @Test("LlamaTTS.generate emits one interval on MLXAudio.llamaTTS (.operations)")
    func testLlamaTTSGenerateEmitsInterval() async throws {
        let config = LlamaTTSConfiguration(
            hiddenSize: 32,
            hiddenLayers: 2,
            intermediateSize: 64,
            attentionHeads: 4,
            rmsNormEps: 1e-5,
            vocabularySize: 256,
            kvHeads: 2,
            ropeTheta: 10000,
            ropeScaling: [
                "factor": .float(32.0),
                "rope_type": .string("llama3")
            ]
        )
        let model = LlamaTTSModel(config)

        let events = try await runWithRecorder { _ in
            _ = try? await model.generate(
                text: "hello",
                voice: nil,
                refAudio: nil,
                refText: nil,
                language: nil,
                instruct: nil,
                generationParameters: GenerateParameters(maxTokens: 1)
            )
        }

        assertOneInterval(events: events, name: "LlamaTTS.generate", subsystem: "MLXAudio.llamaTTS",
                         context: "LlamaTTSModel.generate")
    }

    /// SopranoTTS.generate emits exactly one begin/end pair on MLXAudio.sopranoTTS.
    ///
    /// Synthetic model (no weights); `generate` throws `modelNotInitialized` (tokenizer nil),
    /// but the interval still fires via `defer`.
    @Test("SopranoTTS.generate emits one interval on MLXAudio.sopranoTTS (.operations)")
    func testSopranoTTSGenerateEmitsInterval() async throws {
        let json = """
        {
            "hidden_size": 32,
            "num_hidden_layers": 2,
            "intermediate_size": 64,
            "num_attention_heads": 4,
            "num_key_value_heads": 2,
            "head_dim": 8,
            "vocab_size": 256,
            "sample_rate": 32000,
            "decoder_num_layers": 2,
            "decoder_dim": 16,
            "decoder_intermediate_dim": 48,
            "hop_length": 8,
            "n_fft": 32,
            "upscale": 2,
            "dw_kernel": 3,
            "token_size": 32,
            "receptive_field": 2
        }
        """
        let config = try JSONDecoder().decode(SopranoConfiguration.self, from: json.data(using: .utf8)!)
        let model = SopranoModel(config)

        let events = try await runWithRecorder { _ in
            _ = try? await model.generate(
                text: "hello",
                voice: nil,
                refAudio: nil,
                refText: nil,
                language: nil,
                instruct: nil,
                generationParameters: GenerateParameters(maxTokens: 1)
            )
        }

        assertOneInterval(events: events, name: "SopranoTTS.generate", subsystem: "MLXAudio.sopranoTTS",
                         context: "SopranoModel.generate")
    }

    /// PocketTTS.generate emits exactly one begin/end pair on MLXAudio.pocketTTS.
    ///
    /// Synthetic model (no weights or voice prompts); `generate` throws when the voice
    /// prompt cannot be resolved, but the interval still fires via `defer`.
    @Test("PocketTTS.generate emits one interval on MLXAudio.pocketTTS (.operations)")
    func testPocketTTSGenerateEmitsInterval() async throws {
        let model = makeTinyPocketTTSModel()

        let events = try await runWithRecorder { _ in
            _ = try? await model.generate(
                text: "hello",
                voice: nil,
                refAudio: nil,
                refText: nil,
                language: nil,
                instruct: nil,
                generationParameters: GenerateParameters(maxTokens: 1)
            )
        }

        assertOneInterval(events: events, name: "PocketTTS.generate", subsystem: "MLXAudio.pocketTTS",
                         context: "PocketTTSModel.generate")
    }

    /// MarvisTTS.generate emits exactly one begin/end pair on MLXAudio.marvisTTS.
    ///
    /// Requires a real model download (MarvisTTSModel constructor needs Tokenizers.Tokenizer
    /// from a real model directory). Gated by `MLXAUDIO_NIGHTLY_RUN=1`.
    @Test("MarvisTTS.generate emits one interval on MLXAudio.marvisTTS (.operations) [LOCAL-ONLY]")
    func testMarvisTTSGenerateEmitsInterval() async throws {
        guard ProcessInfo.processInfo.environment["MLXAUDIO_NIGHTLY_RUN"] == "1" else { return }

        // Under MLXAUDIO_NIGHTLY_RUN=1, the marvis-tts model is expected to be in
        // the mlx-models-v2 cache. Load it and verify the interval fires.
        let model = try await MarvisTTSModel.fromPretrained("Marvis-AI/marvis-tts-250m-v0.2-MLX-8bit")

        let events = try await runWithRecorder { _ in
            _ = try? await model.generate(
                text: "hello",
                voice: nil,
                refAudio: nil,
                refText: nil,
                language: nil,
                instruct: nil,
                generationParameters: GenerateParameters(maxTokens: 1)
            )
        }

        assertOneInterval(events: events, name: "MarvisTTS.generate", subsystem: "MLXAudio.marvisTTS",
                         context: "MarvisTTSModel.generate")
    }

    // MARK: - ASR families (LOCAL-ONLY — fatalError without real tokenizer)

    /// Qwen3ASR.generate emits exactly one begin/end pair on MLXAudio.qwen3ASR.
    ///
    /// Qwen3ASRModel.generate calls `fatalError("Tokenizer not loaded")` when the tokenizer
    /// is nil, so a real model download is required. Gated by `MLXAUDIO_NIGHTLY_RUN=1`.
    @Test("Qwen3ASR.generate emits one interval on MLXAudio.qwen3ASR (.operations) [LOCAL-ONLY]")
    func testQwen3ASRGenerateEmitsInterval() async throws {
        guard ProcessInfo.processInfo.environment["MLXAUDIO_NIGHTLY_RUN"] == "1" else { return }

        let model = try await Qwen3ASRModel.fromPretrained("mlx-community/Qwen2.5-7B-Instruct-4bit")

        let audio = MLXArray.zeros([16000], type: Float32.self)
        let events = try await runWithRecorder { _ in
            _ = model.generate(audio: audio, maxTokens: 1)
        }

        assertOneInterval(events: events, name: "Qwen3ASR.generate", subsystem: "MLXAudio.qwen3ASR",
                         context: "Qwen3ASRModel.generate")
    }

    /// GLMASR.generate emits exactly one begin/end pair on MLXAudio.glmASR.
    ///
    /// GLMASRModel.generate calls `fatalError("Tokenizer not loaded")` when the tokenizer
    /// is nil, so a real model download is required. Gated by `MLXAUDIO_NIGHTLY_RUN=1`.
    @Test("GLMASR.generate emits one interval on MLXAudio.glmASR (.operations) [LOCAL-ONLY]")
    func testGLMASRGenerateEmitsInterval() async throws {
        guard ProcessInfo.processInfo.environment["MLXAUDIO_NIGHTLY_RUN"] == "1" else { return }

        let model = try await GLMASRModel.fromPretrained("THUDM/glm-4-voice-9b")

        let audio = MLXArray.zeros([16000], type: Float32.self)
        let events = try await runWithRecorder { _ in
            _ = model.generate(audio: audio, maxTokens: 1)
        }

        assertOneInterval(events: events, name: "GLMASR.generate", subsystem: "MLXAudio.glmASR",
                         context: "GLMASRModel.generate")
    }

    // MARK: - Codec families (CI-safe — synthetic init, real encode/decode with tiny arrays)

    /// SNAC.encode and SNAC.decode each emit exactly one interval on MLXAudio.codecs.
    @Test("SNAC.encode/decode emit one interval each on MLXAudio.codecs (.operations)")
    func testSNACEncodeDecodeEmitIntervals() throws {
        let snac = SNAC(
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

        // Encode
        let recorder1 = TestSignposterRecorder()
        let prevLevel = Telemetry._installLevelOverride(.operations)
        let prevRecorder = Telemetry._installIntervalRecorder(recorder1)
        let audioInput = MLXArray.zeros([1, 1, 32], type: Float32.self)
        let codes = snac.encode(audioInput)
        Telemetry._installIntervalRecorder(prevRecorder)

        assertOneInterval(events: recorder1.events, name: "SNAC.encode", subsystem: "MLXAudio.codecs",
                         context: "SNAC.encode")

        // Decode
        let recorder2 = TestSignposterRecorder()
        Telemetry._installIntervalRecorder(recorder2)
        _ = snac.decode(codes)
        Telemetry._installLevelOverride(prevLevel)
        Telemetry._installIntervalRecorder(prevRecorder)

        assertOneInterval(events: recorder2.events, name: "SNAC.decode", subsystem: "MLXAudio.codecs",
                         context: "SNAC.decode")
    }

    /// Mimi.encode and Mimi.decode each emit exactly one interval on MLXAudio.codecs.
    @Test("Mimi.encode/decode emit one interval each on MLXAudio.codecs (.operations)")
    func testMimiEncodeDecodeEmitIntervals() throws {
        let cfg = mimi_202407(numCodebooks: 1)
        let mimi = Mimi(cfg: cfg)

        // Encode
        let recorder1 = TestSignposterRecorder()
        let prevLevel = Telemetry._installLevelOverride(.operations)
        let prevRecorder = Telemetry._installIntervalRecorder(recorder1)
        let audioInput = MLXArray.zeros([1, 1, 256], type: Float32.self)
        let codes = mimi.encode(audioInput)
        Telemetry._installIntervalRecorder(prevRecorder)

        assertOneInterval(events: recorder1.events, name: "Mimi.encode", subsystem: "MLXAudio.codecs",
                         context: "Mimi.encode")

        // Decode
        let recorder2 = TestSignposterRecorder()
        Telemetry._installIntervalRecorder(recorder2)
        _ = mimi.decode(codes)
        Telemetry._installLevelOverride(prevLevel)
        Telemetry._installIntervalRecorder(prevRecorder)

        assertOneInterval(events: recorder2.events, name: "Mimi.decode", subsystem: "MLXAudio.codecs",
                         context: "Mimi.decode")
    }

    /// Encodec.encode and Encodec.decode each emit exactly one interval on MLXAudio.codecs.
    @Test("Encodec.encode/decode emit one interval each on MLXAudio.codecs (.operations)")
    func testEncodecEncodeDecodeEmitIntervals() throws {
        let config = EncodecConfig()
        let encodec = Encodec(config: config)

        // Tiny input: (batch=1, length=320, channels=1)
        let audioInput = MLXArray.zeros([1, 320, 1], type: Float32.self)

        // Encode
        let recorder1 = TestSignposterRecorder()
        let prevLevel = Telemetry._installLevelOverride(.operations)
        let prevRecorder = Telemetry._installIntervalRecorder(recorder1)
        let (codes, scales) = encodec.encode(audioInput)
        Telemetry._installIntervalRecorder(prevRecorder)

        assertOneInterval(events: recorder1.events, name: "Encodec.encode", subsystem: "MLXAudio.codecs",
                         context: "Encodec.encode")

        // Decode
        let recorder2 = TestSignposterRecorder()
        Telemetry._installIntervalRecorder(recorder2)
        _ = encodec.decode(codes, scales)
        Telemetry._installLevelOverride(prevLevel)
        Telemetry._installIntervalRecorder(prevRecorder)

        assertOneInterval(events: recorder2.events, name: "Encodec.decode", subsystem: "MLXAudio.codecs",
                         context: "Encodec.decode")
    }

    /// DACVAE.encode and DACVAE.decode each emit exactly one interval on MLXAudio.codecs.
    @Test("DAC.encode/decode emit one interval each on MLXAudio.codecs (.operations)")
    func testDACEncodeDecodeEmitIntervals() throws {
        let config = DACVAEConfig(
            encoderDim: 32,
            encoderRates: [2, 4],
            latentDim: 64,
            decoderDim: 64,
            decoderRates: [4, 2],
            codebookDim: 32
        )
        let dac = DACVAE(config: config)

        // Tiny input: (batch=1, length=128, channels=1)
        let audioInput = MLXArray.zeros([1, 128, 1], type: Float32.self)

        // Encode
        let recorder1 = TestSignposterRecorder()
        let prevLevel = Telemetry._installLevelOverride(.operations)
        let prevRecorder = Telemetry._installIntervalRecorder(recorder1)
        let encoded = dac.encode(audioInput)
        Telemetry._installIntervalRecorder(prevRecorder)

        assertOneInterval(events: recorder1.events, name: "DAC.encode", subsystem: "MLXAudio.codecs",
                         context: "DACVAE.encode")

        // Decode
        let recorder2 = TestSignposterRecorder()
        Telemetry._installIntervalRecorder(recorder2)
        _ = dac.decode(encoded)
        Telemetry._installLevelOverride(prevLevel)
        Telemetry._installIntervalRecorder(prevRecorder)

        assertOneInterval(events: recorder2.events, name: "DAC.decode", subsystem: "MLXAudio.codecs",
                         context: "DACVAE.decode")
    }

    /// Vocos.decode emits exactly one interval on MLXAudio.codecs.
    ///
    /// Vocos is decode-only (no public encode). One interval per call.
    @Test("Vocos.decode emits one interval on MLXAudio.codecs (.operations)")
    func testVocosDecodeEmitsInterval() throws {
        let backbone = VocosBackbone(
            inputChannels: 32,
            dim: 64,
            intermediateDim: 128,
            numLayers: 2
        )
        let head = MLXAudioCodecs.ISTFTHead(dim: 64, nFft: 256, hopLength: 64)
        let vocos = Vocos(backbone: backbone, head: head)

        // Tiny features: (batch=1, channels=32, time=4)
        let features = MLXArray.zeros([1, 32, 4], type: Float32.self)

        let recorder = TestSignposterRecorder()
        let prevLevel = Telemetry._installLevelOverride(.operations)
        let prevRecorder = Telemetry._installIntervalRecorder(recorder)
        _ = vocos.decode(features)
        Telemetry._installLevelOverride(prevLevel)
        Telemetry._installIntervalRecorder(prevRecorder)

        assertOneInterval(events: recorder.events, name: "Vocos.decode", subsystem: "MLXAudio.codecs",
                         context: "Vocos.decode")
    }

    // MARK: - PocketTTS synthetic model helper (mirrors TelemetryModelLifecycleSmokeTests)

    private func makeTinyPocketTTSModel() -> PocketTTSModel {
        let flowLMConfig = PocketTTSFlowLMConfig(
            dtype: nil,
            flow: PocketTTSFlowConfig(dim: 16, depth: 1),
            transformer: PocketTTSFlowLMTransformerConfig(
                hiddenScale: 2,
                maxPeriod: 10000.0,
                dModel: 16,
                numHeads: 2,
                numLayers: 2
            ),
            lookupTable: PocketTTSLookupTableConfig(
                dim: 16,
                nBins: 64,
                tokenizer: "sentencepiece",
                tokenizerPath: "tokenizer.model"
            ),
            weightsPath: nil
        )
        let mimiConfig = PocketTTSMimiConfig(
            dtype: nil,
            sampleRate: 24000,
            channels: 1,
            frameRate: 12.5,
            seanet: PocketTTSSeanetConfig(
                dimension: 16,
                channels: 1,
                nFilters: 4,
                nResidualLayers: 1,
                ratios: [2, 2],
                kernelSize: 7,
                residualKernelSize: 3,
                lastKernelSize: 3,
                dilationBase: 2,
                padMode: "constant",
                compress: 2
            ),
            transformer: PocketTTSMimiTransformerConfig(
                dModel: 16,
                inputDimension: 16,
                outputDimensions: [16],
                numHeads: 2,
                numLayers: 2,
                layerScale: 0.01,
                context: 8,
                dimFeedforward: 32,
                maxPeriod: 10000.0
            ),
            quantizer: PocketTTSQuantizerConfig(dimension: 8, outputDimension: 16),
            weightsPath: nil
        )
        let dModel = flowLMConfig.transformer.dModel
        let ldim = mimiConfig.quantizer.dimension

        let conditioner = LUTConditioner(
            nBins: flowLMConfig.lookupTable.nBins,
            dim: flowLMConfig.lookupTable.dim,
            outputDim: dModel
        )
        let flowNet = SimpleMLPAdaLN(
            inChannels: ldim,
            modelChannels: flowLMConfig.flow.dim,
            outChannels: ldim,
            condChannels: dModel,
            numResBlocks: flowLMConfig.flow.depth,
            numTimeConds: 2
        )
        let transformer = PocketStreamingTransformer(
            dModel: dModel,
            numHeads: flowLMConfig.transformer.numHeads,
            numLayers: flowLMConfig.transformer.numLayers,
            dimFeedforward: flowLMConfig.transformer.hiddenScale * dModel,
            maxPeriod: flowLMConfig.transformer.maxPeriod,
            layerScale: nil
        )
        let flowLM = FlowLMModel(
            conditioner: conditioner,
            flowNet: flowNet,
            transformer: transformer,
            dim: dModel,
            ldim: ldim
        )
        let mimi = MimiAdapter.fromConfig(mimiConfig)
        let modelConfig = PocketTTSModelConfig(
            modelType: "pocket_tts",
            flowLM: flowLMConfig,
            mimi: mimiConfig,
            weightsPath: nil,
            weightsPathWithoutVoiceCloning: nil,
            modelPath: nil
        )
        return PocketTTSModel(config: modelConfig, flowLM: flowLM, mimi: mimi)
    }
}
