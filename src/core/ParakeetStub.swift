import Foundation

/// P2-1: stub providers for the two LOCAL engine candidates (plan §3 step 4).
///
/// INTERFACE + CONFIG PLUMBING ONLY — no provider implementation. The seam
/// exists so a future swap task can fill in `transcribe(audioFileURL:)`
/// without touching config, validation, or TranscriptionService again.
/// Per plan §3 step 4, local candidates additionally need (before adoption):
/// a reproducible runtime story on Dan's Mac, a memory-budget check, and a
/// fallback path — TranscriptionService already degrades to whisper-1 on any
/// provider failure, which satisfies the fallback requirement today.
///
/// Status notes (from the plan §3 landscape table):
///   - Parakeet TDT 0.6B v2/v3: on-device, open (CC-BY-4.0), 2.01/3.40 WER
///     (v3, third-party measured); AMI 11.31. Biasing surface weak/absent
///     (initial-prompt conditioning is weak) — compensate with the P1-1
///     dictionary flywheel + P1-2 verification pass. Runtime: GGUF via
///     NeMo-Speech.cpp. Memory: ~1.3 GB for the 0.6B model. Diarization:
///     none built in — pair with the existing `diarize_audio_fast.py`.
///   - Apple SpeechAnalyzer (macOS 26): on-device, free, 2.12/4.56 WER
///     (int8, third-party measured). No biasing surface documented. No
///     diarization — same external-diarizer pairing. Memory: OS-managed,
///     effectively free. Requires macOS 26 SDK + runtime; NFR-12 posture
///     improves (nothing leaves the device).
///
/// [needs-Mac-build] — both stubs require macOS runtimes/SDKs that do not
/// exist on this Linux host.
enum LocalEngineStubs {

    /// Config provider identifiers accepted (validated) but not yet implemented.
    /// TranscriptionService falls back to the default chain when one is
    /// selected before its provider lands.
    static let reservedProviderIDs: Set<String> = ["parakeet", "apple-speechanalyzer"]
}

/// Parakeet TDT via the NeMo-Speech.cpp GGUF runtime.
/// TODO(future swap task): shell out to the NeMo-Speech.cpp binary with the
/// resampled 16 kHz WAV (reuse LocalWhisperProvider.resampleAudio), parse the
/// text output, keep whisper-1 as the on-failure fallback.
class ParakeetTDTProvider: TranscriptionProvider {
    private let modelPath: URL
    private let binaryPath: URL

    init(modelPath: URL, binaryPath: URL) {
        self.modelPath = modelPath
        self.binaryPath = binaryPath
    }

    func transcribe(audioFileURL: URL) async throws -> String {
        throw TranscriptionError.apiError(
            "Parakeet TDT provider is a stub (plan §3 step 4). Implement via NeMo-Speech.cpp GGUF runtime — see LocalEngineStubs docs in ParakeetStub.swift.")
    }
}

/// Apple SpeechAnalyzer (macOS 26 on-device recognizer).
/// TODO(future swap task): wrap the SpeechAnalyzer API in a
/// TranscriptionProvider; no runtime to install, requires macOS 26.
class AppleSpeechAnalyzerProvider: TranscriptionProvider {
    func transcribe(audioFileURL: URL) async throws -> String {
        throw TranscriptionError.apiError(
            "Apple SpeechAnalyzer provider is a stub (plan §3 step 4). Implement via the macOS 26 SpeechAnalyzer API — see LocalEngineStubs docs in ParakeetStub.swift.")
    }
}
