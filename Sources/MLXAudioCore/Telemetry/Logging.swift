import Foundation
import os

/// Per-subsystem `os.Logger` and `OSSignposter` map for the MLXAudio library.
///
/// One `public static let` `Logger` and one `internal static let`
/// `OSSignposter` are declared per subsystem. Each pair shares the same
/// subsystem string so Instruments groups them cleanly under a single
/// category lane.
///
/// Loggers are `public` so host apps can filter via `log` / Console.app.
/// Signposters are `internal` — host apps that want their own signposts
/// should declare their own subsystems rather than emitting on ours, to
/// keep Instruments traces cleanly separated (see requirements §5).
///
/// The 10 canonical subsystem identifiers match Section 5 of
/// `docs/TELEMETRY_REQUIREMENTS.md` exactly.
public enum MLXAudioLogging {

    // MARK: - MLXAudio.core

    /// Logger for core / shared infrastructure.
    public static let core = Logger(subsystem: "MLXAudio.core", category: "core")

    /// Signposter for core / shared infrastructure.
    internal static let coreSignposter = OSSignposter(subsystem: "MLXAudio.core", category: "core")

    // MARK: - MLXAudio.modelResolver

    /// Logger for `ModelResolver` / `Acervo` download operations.
    public static let modelResolver = Logger(subsystem: "MLXAudio.modelResolver", category: "modelResolver")

    /// Signposter for `ModelResolver` / `Acervo` download operations.
    internal static let modelResolverSignposter = OSSignposter(subsystem: "MLXAudio.modelResolver", category: "modelResolver")

    // MARK: - MLXAudio.qwen3TTS

    /// Logger for the Qwen3 TTS model family.
    public static let qwen3TTS = Logger(subsystem: "MLXAudio.qwen3TTS", category: "qwen3TTS")

    /// Signposter for the Qwen3 TTS model family.
    internal static let qwen3TTSSignposter = OSSignposter(subsystem: "MLXAudio.qwen3TTS", category: "qwen3TTS")

    // MARK: - MLXAudio.llamaTTS

    /// Logger for the LlamaTTS (Orpheus) model family.
    public static let llamaTTS = Logger(subsystem: "MLXAudio.llamaTTS", category: "llamaTTS")

    /// Signposter for the LlamaTTS (Orpheus) model family.
    internal static let llamaTTSSignposter = OSSignposter(subsystem: "MLXAudio.llamaTTS", category: "llamaTTS")

    // MARK: - MLXAudio.sopranoTTS

    /// Logger for the Soprano TTS model family.
    public static let sopranoTTS = Logger(subsystem: "MLXAudio.sopranoTTS", category: "sopranoTTS")

    /// Signposter for the Soprano TTS model family.
    internal static let sopranoTTSSignposter = OSSignposter(subsystem: "MLXAudio.sopranoTTS", category: "sopranoTTS")

    // MARK: - MLXAudio.pocketTTS

    /// Logger for the PocketTTS model family.
    public static let pocketTTS = Logger(subsystem: "MLXAudio.pocketTTS", category: "pocketTTS")

    /// Signposter for the PocketTTS model family.
    internal static let pocketTTSSignposter = OSSignposter(subsystem: "MLXAudio.pocketTTS", category: "pocketTTS")

    // MARK: - MLXAudio.marvisTTS

    /// Logger for the Marvis TTS (CSM / Sesame) model family.
    public static let marvisTTS = Logger(subsystem: "MLXAudio.marvisTTS", category: "marvisTTS")

    /// Signposter for the Marvis TTS (CSM / Sesame) model family.
    internal static let marvisTTSSignposter = OSSignposter(subsystem: "MLXAudio.marvisTTS", category: "marvisTTS")

    // MARK: - MLXAudio.qwen3ASR

    /// Logger for the Qwen3 ASR model family.
    public static let qwen3ASR = Logger(subsystem: "MLXAudio.qwen3ASR", category: "qwen3ASR")

    /// Signposter for the Qwen3 ASR model family.
    internal static let qwen3ASRSignposter = OSSignposter(subsystem: "MLXAudio.qwen3ASR", category: "qwen3ASR")

    // MARK: - MLXAudio.glmASR

    /// Logger for the GLM ASR model family.
    public static let glmASR = Logger(subsystem: "MLXAudio.glmASR", category: "glmASR")

    /// Signposter for the GLM ASR model family.
    internal static let glmASRSignposter = OSSignposter(subsystem: "MLXAudio.glmASR", category: "glmASR")

    // MARK: - MLXAudio.codecs

    /// Logger for codec model families (SNAC, Mimi, Encodec, DAC, Vocos).
    public static let codecs = Logger(subsystem: "MLXAudio.codecs", category: "codecs")

    /// Signposter for codec model families (SNAC, Mimi, Encodec, DAC, Vocos).
    internal static let codecsSignposter = OSSignposter(subsystem: "MLXAudio.codecs", category: "codecs")

    // MARK: - Subsystem table (internal — test verification)

    /// Maps every canonical subsystem identifier to its `Logger` and
    /// `OSSignposter`. Used by `TelemetryLoggingTests` to assert that each
    /// pair was constructed with the same subsystem string and that all 10
    /// canonical subsystems are present.
    ///
    /// The type is `(subsystem: String, logger: Logger, signposter: OSSignposter)`.
    /// Both `Logger` and `OSSignposter` are initialized with the same subsystem,
    /// so the table itself is the ground truth for the "subsystems match" assertion.
    internal static let subsystemTable: [(subsystem: String, logger: Logger, signposter: OSSignposter)] = [
        ("MLXAudio.core",          core,          coreSignposter),
        ("MLXAudio.modelResolver", modelResolver, modelResolverSignposter),
        ("MLXAudio.qwen3TTS",      qwen3TTS,      qwen3TTSSignposter),
        ("MLXAudio.llamaTTS",      llamaTTS,      llamaTTSSignposter),
        ("MLXAudio.sopranoTTS",    sopranoTTS,    sopranoTTSSignposter),
        ("MLXAudio.pocketTTS",     pocketTTS,     pocketTTSSignposter),
        ("MLXAudio.marvisTTS",     marvisTTS,      marvisTTSSignposter),
        ("MLXAudio.qwen3ASR",      qwen3ASR,      qwen3ASRSignposter),
        ("MLXAudio.glmASR",        glmASR,        glmASRSignposter),
        ("MLXAudio.codecs",        codecs,        codecsSignposter),
    ]
}
