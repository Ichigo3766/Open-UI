import Foundation
import AVFoundation
import os.log

/// Server-side speech recognition service.
///
/// Records microphone audio, then sends it to the OpenWebUI server's
/// `POST /api/v1/audio/transcriptions` endpoint for transcription.
///
/// This is the drop-in server alternative to `SpeechRecognitionService`
/// (which uses Apple's on-device `SFSpeechRecognizer`). Both expose the
/// same callback interface so `VoiceCallViewModel` and the chat input can
/// switch between them with a single preference check.
///
/// ## Flow
/// 1. `startListening()` → configures AVAudioSession, starts AVAudioRecorder
/// 2. Audio is recorded continuously; silence detection auto-stops after the
///    configured duration (default 2 s) when speech has been detected.
/// 3. `stopListening()` → stops recorder, uploads audio to the server, fires
///    `onFinalTranscript` with the resulting text.
///
/// ## Chunking (voice call mode)
/// When `continuousMode` is true the service restarts recording automatically
/// after each transcription, replicating the endless listen-loop of
/// `SpeechRecognitionService`.
@MainActor @Observable
final class ServerSpeechRecognitionService {

    // MARK: - State

    enum RecognitionState: Sendable, Equatable {
        case idle
        case requesting
        case listening
        case processing
        case error(String)
        case unavailable
    }

    private(set) var state: RecognitionState = .idle

    /// The latest interim/partial text shown during recording
    /// (not applicable for server STT — always empty until transcription finishes).
    private(set) var currentTranscript: String = ""

    /// Simulated intensity level (0–10) for waveform display, driven by AVAudioRecorder metering.
    private(set) var intensity: Int = 0

    /// Whether the service has microphone permission.
    private(set) var isAuthorized: Bool = false

    // MARK: - Callbacks (matches SpeechRecognitionService interface)

    /// Called when the final transcript is ready after speech ends.
    var onFinalTranscript: ((String) -> Void)?

    /// Called when the recognition state changes.
    var onStateChanged: ((RecognitionState) -> Void)?

    /// Called when an error occurs.
    var onError: ((String) -> Void)?

    // MARK: - Configuration

    /// Seconds of silence after which recording auto-stops (if speech was detected).
    var silenceDuration: TimeInterval = 2.0

    /// When true, the service signals the transcript but does NOT restart automatically.
    /// The caller (`VoiceCallViewModel`) is expected to call `startListening()` again when ready.
    var continuousMode: Bool = false

    // MARK: - Private

    private let logger = Logger(subsystem: "com.openui", category: "ServerSTT")

    /// The API client used for transcription uploads.
    var apiClient: APIClient?

    private var recorder: AVAudioRecorder?
    private var recordingURL: URL?
    private var meteringTimer: Timer?
    private var silenceTimer: Timer?
    private var hasSpeechStarted: Bool = false
    private var recordingStartTime: Date?

    // MARK: - Public API

    /// Returns true when an APIClient is configured.
    var isAvailable: Bool { apiClient != nil }

    /// Configures the underlying APIClient for server transcription.
    func configure(apiClient: APIClient?) {
        self.apiClient = apiClient
    }

    /// Requests microphone permission.
    func requestPermissions() async -> Bool {
        let granted: Bool
        if #available(iOS 17.0, *) {
            granted = await AVAudioApplication.requestRecordPermission()
        } else {
            granted = await withCheckedContinuation { continuation in
                AVAudioSession.sharedInstance().requestRecordPermission { result in
                    continuation.resume(returning: result)
                }
            }
        }
        isAuthorized = granted
        return granted
    }

    /// Checks current microphone authorization without prompting.
    func checkAuthorization() -> Bool {
        let result: Bool
        if #available(iOS 17.0, *) {
            result = AVAudioApplication.shared.recordPermission == .granted
        } else {
            result = AVAudioSession.sharedInstance().recordPermission == .granted
        }
        isAuthorized = result
        return result
    }

    /// Begins recording audio for server-side transcription.
    func startListening() async throws {
        guard isAvailable else {
            updateState(.unavailable)
            throw ServerSTTError.noAPIClient
        }

        if !isAuthorized {
            let granted = await requestPermissions()
            guard granted else {
                updateState(.error("Microphone permission denied"))
                throw ServerSTTError.notAuthorized
            }
        }

        // Stop any existing session first
        stopListening()
        updateState(.requesting)

        // Configure audio session
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .measurement,
                                options: [.defaultToSpeaker, .allowBluetoothA2DP])
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        // Create temp file
        let tempDir = FileManager.default.temporaryDirectory
        let fileName = "server_stt_\(Int(Date().timeIntervalSince1970)).m4a"
        let url = tempDir.appendingPathComponent(fileName)
        recordingURL = url

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 16000.0,   // 16 kHz — optimal for Whisper/Whisper-based models
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
            AVEncoderBitRateKey: 32000  // Sufficient quality at low bitrate for speech
        ]

        recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder?.isMeteringEnabled = true

        guard recorder?.record() == true else {
            updateState(.error("Failed to start recording"))
            throw ServerSTTError.recordingFailed
        }

        recordingStartTime = Date()
        hasSpeechStarted = false
        currentTranscript = ""
        intensity = 0

        updateState(.listening)
        startMetering()
        startSilenceDetection()
    }

    /// Stops recording immediately and uploads the audio to the server.
    @discardableResult
    func stopListening() -> String {
        stopTimers()

        // Stop the recorder
        recorder?.stop()
        recorder = nil

        let url = recordingURL
        recordingURL = nil
        recordingStartTime = nil
        hasSpeechStarted = false
        intensity = 0

        if state != .idle && state != .processing {
            // If we have audio data, upload it
            if let url, FileManager.default.fileExists(atPath: url.path) {
                uploadRecording(at: url)
            } else {
                updateState(.idle)
            }
        }

        return currentTranscript
    }

    // MARK: - Private Helpers

    /// Starts metering timer for waveform visualization.
    private func startMetering() {
        meteringTimer = Timer.scheduledTimer(withTimeInterval: 0.06, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let recorder = self.recorder, recorder.isRecording else { return }
                recorder.updateMeters()
                let power = recorder.averagePower(forChannel: 0)
                // Normalize from dB (-160..0) to 0..10 — matches SpeechRecognitionService
                let normalized = max(0, (power + 50) / 50)
                let scaled = Int((normalized * 10).rounded())
                self.intensity = min(10, max(0, scaled))

                // Mark speech started once we get a signal above threshold
                if !self.hasSpeechStarted && self.intensity >= 2 {
                    self.hasSpeechStarted = true
                }
            }
        }
    }

    /// Monitors silence. After `silenceDuration` seconds of quiet (and speech was detected),
    /// auto-stops the recording.
    private func startSilenceDetection() {
        silenceTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let recorder = self.recorder, recorder.isRecording else { return }

                // Need at least 0.5 s of audio before allowing silence cut
                guard let start = self.recordingStartTime,
                      Date().timeIntervalSince(start) > 0.5 else { return }

                // Require speech to have started before cutting on silence
                guard self.hasSpeechStarted else { return }

                recorder.updateMeters()
                let power = recorder.averagePower(forChannel: 0)
                let isSilent = power < -45 // dB — below ambient room noise

                if isSilent {
                    // Count consecutive silence ticks
                    let silenceTicks = Int(self.silenceDuration / 0.3)
                    self._silenceTickCount += 1
                    if self._silenceTickCount >= silenceTicks {
                        self.logger.info("Silence detected — stopping recording")
                        self.stopListening()
                    }
                } else {
                    self._silenceTickCount = 0
                }
            }
        }
    }

    /// Counter for consecutive silence checks — used to implement silence duration.
    private var _silenceTickCount: Int = 0

    private func stopTimers() {
        meteringTimer?.invalidate()
        meteringTimer = nil
        silenceTimer?.invalidate()
        silenceTimer = nil
        _silenceTickCount = 0
    }

    /// Uploads the recorded audio to the server transcription endpoint.
    private func uploadRecording(at url: URL) {
        updateState(.processing)
        Task {
            defer {
                try? FileManager.default.removeItem(at: url)
            }

            guard let client = apiClient else {
                updateState(.error("No server configured"))
                onError?("No server configured for STT")
                return
            }

            do {
                let audioData = try Data(contentsOf: url)
                guard audioData.count > 1024 else {
                    // Audio is too short / empty — ignore silently
                    logger.info("Audio too short, skipping transcription")
                    updateState(.idle)
                    return
                }

                logger.info("Uploading audio for transcription (\(audioData.count) bytes)")

                let result = try await client.transcribeSpeech(
                    audioData: audioData,
                    fileName: url.lastPathComponent
                )

                let text: String
                if let transcript = result["text"] as? String {
                    text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                } else {
                    text = ""
                }

                logger.info("Server STT transcript: \(text.count) chars")

                updateState(.idle)

                if !text.isEmpty {
                    currentTranscript = text
                    onFinalTranscript?(text)
                }

            } catch {
                logger.error("Server STT error: \(error.localizedDescription)")
                updateState(.error(error.localizedDescription))
                onError?(error.localizedDescription)
            }
        }
    }

    private func updateState(_ newState: RecognitionState) {
        state = newState
        onStateChanged?(newState)
    }
}

// MARK: - Errors

enum ServerSTTError: LocalizedError {
    case noAPIClient
    case notAuthorized
    case recordingFailed

    var errorDescription: String? {
        switch self {
        case .noAPIClient:
            return "Server STT is not configured. Please connect to a server."
        case .notAuthorized:
            return "Microphone permission is required for server STT."
        case .recordingFailed:
            return "Failed to start audio recording."
        }
    }
}
