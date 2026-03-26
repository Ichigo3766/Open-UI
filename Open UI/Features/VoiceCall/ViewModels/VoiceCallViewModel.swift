import Foundation
import AVFoundation
import os.log

/// Orchestrates voice call functionality by coordinating speech recognition,
/// text-to-speech, and CallKit services.
///
/// Manages the listen → process → speak → listen cycle for hands-free
/// conversational AI interaction.
///
/// Supports two STT backends:
/// - **Apple on-device** (`SpeechRecognitionService`) — default, works offline
/// - **Server-side** (`ServerSpeechRecognitionService`) — records mic → uploads to
///   `POST /api/v1/audio/transcriptions` when `sttEngine == "server"`
@MainActor @Observable
final class VoiceCallViewModel {

    // MARK: - State

    enum CallState: Sendable, Equatable {
        case idle
        case connecting
        case listening
        case paused
        case processing
        case speaking
        case error(String)
        case disconnected
    }

    /// Current call state.
    private(set) var callState: CallState = .idle

    /// The current user's speech transcript (shown briefly while listening).
    private(set) var currentTranscript: String = ""

    /// Voice intensity for waveform (0–10).
    private(set) var voiceIntensity: Int = 0

    /// Whether the microphone is muted.
    private(set) var isMuted: Bool = false

    /// Whether the call is paused.
    private(set) var isPaused: Bool = false

    /// Whether audio is routed to the loudspeaker.
    private(set) var isSpeakerOn: Bool = true

    /// The model name being used.
    private(set) var modelName: String = ""

    /// Call duration in seconds.
    private(set) var callDuration: TimeInterval = 0

    /// Error message if in error state.
    var errorMessage: String?

    // MARK: - Dependencies

    /// Apple on-device STT — set when not using server STT.
    private let speechService: SpeechRecognitionService?
    /// Server-side STT — set when `sttEngine == "server"`.
    private let serverSpeechService: ServerSpeechRecognitionService?
    private let ttsService: TextToSpeechService
    private let callKitManager: CallKitManager
    private var conversationManager: ConversationManager?
    private var chatViewModel: ChatViewModel?

    /// True when using the server-based STT (records → uploads) instead of Apple Speech.
    var isUsingServerSTT: Bool { serverSpeechService != nil }

    private let logger = Logger(subsystem: "com.openui", category: "VoiceCall")
    private var durationTimer: Task<Void, Never>?
    private var callStartTime: Date?

    // MARK: - Init (Apple on-device STT)

    init(
        speechService: SpeechRecognitionService,
        ttsService: TextToSpeechService,
        callKitManager: CallKitManager
    ) {
        self.speechService = speechService
        self.serverSpeechService = nil
        self.ttsService = ttsService
        self.callKitManager = callKitManager

        setupCallbacks()
    }

    // MARK: - Init (Server-side STT)

    init(
        serverSpeechService: ServerSpeechRecognitionService,
        ttsService: TextToSpeechService,
        callKitManager: CallKitManager
    ) {
        self.speechService = nil
        self.serverSpeechService = serverSpeechService
        self.ttsService = ttsService
        self.callKitManager = callKitManager

        setupCallbacks()
    }

    // MARK: - Configuration

    /// Configures the voice call with a conversation manager and chat view model.
    func configure(
        conversationManager: ConversationManager,
        chatViewModel: ChatViewModel,
        modelName: String
    ) {
        self.conversationManager = conversationManager
        self.chatViewModel = chatViewModel
        self.modelName = modelName
    }

    // MARK: - Call Lifecycle

    /// Starts a new voice call session.
    func startCall() async {
        guard callState == .idle || callState == .disconnected else { return }

        callState = .connecting

        // Request permissions (both STT backends need mic access)
        let authorized: Bool
        if let serverSTT = serverSpeechService {
            authorized = await serverSTT.requestPermissions()
        } else {
            authorized = await speechService?.requestPermissions() ?? false
        }

        guard authorized else {
            callState = .error("Microphone and speech recognition permissions are required.")
            errorMessage = "Please grant microphone and speech recognition permissions in Settings."
            return
        }

        // Start CallKit session
        do {
            try await callKitManager.startCall(displayName: modelName.isEmpty ? "AI Assistant" : modelName)
        } catch {
            logger.warning("CallKit start failed (non-fatal): \(error.localizedDescription)")
        }

        // Apply the user's TTS configuration so voice calls use identical
        // settings to the chat read-aloud button (speech rate, voice, engine).
        let rate = UserDefaults.standard.double(forKey: "ttsSpeechRate")
        if rate > 0 {
            ttsService.speechRate = Float(rate) * AVSpeechUtteranceDefaultSpeechRate
        }
        let voiceId = UserDefaults.standard.string(forKey: "ttsVoiceIdentifier") ?? ""
        ttsService.voiceIdentifier = voiceId.isEmpty ? nil : voiceId

        // Preload MarvisTTS model only if the user explicitly chose Marvis
        if ttsService.preferredEngine == .marvis {
            logger.info("Voice call: preloading MarvisTTS model...")
            await ttsService.preloadMarvisModel()
        }

        // Enable speaker override in TTS service for the duration of this call
        ttsService.speakerOverrideEnabled = isSpeakerOn

        // Start call timer
        callStartTime = Date()
        startDurationTimer()

        // Start listening
        await startListening()
    }

    /// Ends the current voice call.
    func endCall() async {
        stopActiveSTT()
        ttsService.stop()
        await callKitManager.endCall()

        durationTimer?.cancel()
        durationTimer = nil
        callState = .disconnected
        currentTranscript = ""
        voiceIntensity = 0

        // Disable speaker override so TTS outside a call behaves normally
        ttsService.speakerOverrideEnabled = false

        // CRITICAL: Clear all shared service callbacks so a stale VM reference
        // cannot restart the microphone after the call ends. Without this, the
        // ttsService.onComplete closure (which calls startListening) remains set
        // on the shared singleton and fires the next time any TTS plays — causing
        // the mic to turn on permanently in the background.
        clearCallbacks()
    }

    /// Pauses listening.
    func pauseListening() {
        isPaused = true
        stopActiveSTT()
        callState = .paused
    }

    /// Resumes listening after pause.
    func resumeListening() async {
        isPaused = false
        await startListening()
    }

    /// Toggles mute state.
    func toggleMute() {
        isMuted.toggle()
        if isMuted {
            ttsService.stop()
            stopActiveSTT()
            callState = .paused
        } else {
            Task { await startListening() }
        }
    }

    /// Cancels the current TTS playback and resumes listening.
    func cancelSpeaking() async {
        ttsService.stop()
        await startListening()
    }

    /// Toggles audio output between loudspeaker and earpiece.
    func toggleSpeaker() {
        isSpeakerOn.toggle()
        ttsService.speakerOverrideEnabled = isSpeakerOn
        applySpeakerOverride()
    }

    /// Applies the current speaker routing preference to the active audio session.
    func applySpeakerOverride() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.overrideOutputAudioPort(isSpeakerOn ? .speaker : .none)
        } catch {
            logger.warning("Speaker override failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Formatted Duration

    var formattedDuration: String {
        let mins = Int(callDuration) / 60
        let secs = Int(callDuration) % 60
        return String(format: "%02d:%02d", mins, secs)
    }

    // MARK: - State Label

    var stateLabel: String {
        switch callState {
        case .idle: return "Ready"
        case .connecting: return "Connecting…"
        case .listening:
            return isUsingServerSTT ? "Recording…" : "Listening…"
        case .paused: return "Paused"
        case .processing:
            return isUsingServerSTT ? "Transcribing…" : "Thinking…"
        case .speaking: return "Speaking"
        case .error: return "Error"
        case .disconnected: return "Call Ended"
        }
    }

    // MARK: - Private Helpers

    /// Stops whichever STT service is active.
    private func stopActiveSTT() {
        if let serverSTT = serverSpeechService {
            serverSTT.stopListening()
        } else {
            speechService?.stopListening()
        }
    }

    /// Current intensity from whichever STT service is active.
    private var activeIntensity: Int {
        if let serverSTT = serverSpeechService { return serverSTT.intensity }
        return speechService?.intensity ?? 0
    }

    /// Current transcript from whichever STT service is active.
    private var activeCurrentTranscript: String {
        if let serverSTT = serverSpeechService { return serverSTT.currentTranscript }
        return speechService?.currentTranscript ?? ""
    }

    /// Clears all callbacks installed on shared services.
    /// Must be called when the call ends to prevent a stale VM from
    /// restarting the microphone the next time any TTS plays elsewhere in the app.
    private func clearCallbacks() {
        speechService?.onFinalTranscript = nil
        speechService?.onStateChanged = nil
        speechService?.onError = nil
        serverSpeechService?.onFinalTranscript = nil
        serverSpeechService?.onStateChanged = nil
        serverSpeechService?.onError = nil
        ttsService.onStart = nil
        ttsService.onComplete = nil
        ttsService.onError = nil
        callKitManager.onCallEnded = nil
        callKitManager.onMuteToggled = nil
        callKitManager.onAudioSessionActivated = nil
    }

    /// Sets up callbacks between services.
    private func setupCallbacks() {
        // --- Apple on-device STT callbacks ---
        speechService?.onFinalTranscript = { [weak self] transcript in
            Task { @MainActor [weak self] in
                await self?.handleFinalTranscript(transcript)
            }
        }

        speechService?.onStateChanged = { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch state {
                case .listening:
                    self.voiceIntensity = self.speechService?.intensity ?? 0
                case .error(let msg):
                    self.logger.error("Speech error: \(msg)")
                default:
                    break
                }
            }
        }

        speechService?.onError = { [weak self] error in
            Task { @MainActor [weak self] in
                self?.logger.error("Speech recognition error: \(error)")
            }
        }

        // --- Server STT callbacks ---
        serverSpeechService?.onFinalTranscript = { [weak self] transcript in
            Task { @MainActor [weak self] in
                await self?.handleFinalTranscript(transcript)
            }
        }

        serverSpeechService?.onStateChanged = { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch state {
                case .listening:
                    self.voiceIntensity = self.serverSpeechService?.intensity ?? 0
                case .processing:
                    // Server is uploading/transcribing — show a processing state
                    if self.callState == .listening {
                        self.callState = .processing
                    }
                case .error(let msg):
                    self.logger.error("Server STT error: \(msg)")
                    // On error, restart listening so the call continues
                    if !self.isPaused && !self.isMuted {
                        Task { await self.startListening() }
                    }
                default:
                    break
                }
            }
        }

        serverSpeechService?.onError = { [weak self] error in
            Task { @MainActor [weak self] in
                self?.logger.error("Server STT error: \(error)")
                // On network error during voice call, fall back gracefully
                if let self, !self.isPaused && !self.isMuted {
                    await self.startListening()
                }
            }
        }

        // --- TTS callbacks ---
        ttsService.onStart = { [weak self] in
            Task { @MainActor [weak self] in
                self?.callState = .speaking
            }
        }

        ttsService.onComplete = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if !self.isPaused && !self.isMuted {
                    await self.startListening()
                }
            }
        }

        ttsService.onError = { [weak self] error in
            Task { @MainActor [weak self] in
                self?.logger.error("TTS error: \(error)")
                if let self, !self.isPaused && !self.isMuted {
                    await self.startListening()
                }
            }
        }

        // --- CallKit callbacks ---
        callKitManager.onCallEnded = { [weak self] in
            Task { @MainActor [weak self] in
                await self?.endCall()
            }
        }

        callKitManager.onMuteToggled = { [weak self] muted in
            Task { @MainActor [weak self] in
                self?.isMuted = muted
                if muted {
                    self?.stopActiveSTT()
                    self?.ttsService.stop()
                } else {
                    await self?.startListening()
                }
            }
        }

        callKitManager.onAudioSessionActivated = { [weak self] in
            Task { @MainActor [weak self] in
                // CallKit reset the audio session — re-apply our speaker preference
                self?.applySpeakerOverride()
            }
        }
    }

    /// Starts speech recognition using whichever STT backend is active.
    private func startListening() async {
        guard !isMuted, !isPaused else {
            callState = .paused
            return
        }

        // Reconfigure audio session for recording (TTS may have left it in .playback)
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .voiceChat,
                                    options: [.defaultToSpeaker, .allowBluetoothA2DP])
            try session.setActive(true)
            try session.overrideOutputAudioPort(isSpeakerOn ? .speaker : .none)
        } catch {
            logger.warning("Audio session reconfig for listening: \(error.localizedDescription)")
        }

        currentTranscript = ""
        callState = .listening

        if let serverSTT = serverSpeechService {
            // Server STT: record audio → upload → onFinalTranscript fires when done
            do {
                try await serverSTT.startListening()
            } catch {
                logger.error("Server STT failed to start: \(error.localizedDescription)")
                callState = .error(error.localizedDescription)
                errorMessage = error.localizedDescription
                return
            }
            // Monitor intensity from server STT recorder
            monitorServerSTTIntensity()
        } else {
            // Apple on-device STT
            do {
                try await speechService?.startListening()
            } catch {
                logger.error("Failed to start listening: \(error.localizedDescription)")
                callState = .error(error.localizedDescription)
                errorMessage = error.localizedDescription
                return
            }
            monitorAppleSTTIntensity()
        }
    }

    /// Monitors voice intensity from the Apple STT service for waveform display.
    private func monitorAppleSTTIntensity() {
        Task {
            while callState == .listening {
                voiceIntensity = speechService?.intensity ?? 0
                currentTranscript = speechService?.currentTranscript ?? ""
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    /// Monitors voice intensity from the server STT recorder for waveform display.
    private func monitorServerSTTIntensity() {
        Task {
            while callState == .listening {
                voiceIntensity = serverSpeechService?.intensity ?? 0
                // Server STT has no real-time partial transcripts — show empty
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    /// Starts the call duration timer.
    private func startDurationTimer() {
        durationTimer = Task {
            while !Task.isCancelled {
                if let start = callStartTime {
                    callDuration = Date().timeIntervalSince(start)
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// Handles the final transcript from whichever STT service is active.
    private func handleFinalTranscript(_ transcript: String) async {
        guard !transcript.isEmpty else {
            if !isPaused && !isMuted {
                await startListening()
            }
            return
        }

        // Stop STT first to release the audio session
        stopActiveSTT()

        callState = .processing
        currentTranscript = transcript

        guard let chatViewModel else {
            callState = .error("Chat not configured")
            return
        }

        // Wait for speech recognizer / recorder to fully release audio routes.
        // SFSpeechRecognizer holds the audio session for ~200-300ms after stopListening().
        // AVAudioRecorder also needs a moment.
        try? await Task.sleep(for: .milliseconds(400))

        // Pre-configure the audio session to .playback before TTS starts.
        for attempt in 1...3 {
            do {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playAndRecord, mode: .voiceChat,
                                        options: [.defaultToSpeaker, .allowBluetoothA2DP])
                try session.setActive(true)
                try session.overrideOutputAudioPort(isSpeakerOn ? .speaker : .none)
                break
            } catch {
                logger.warning("Audio session attempt \(attempt)/3: \(error.localizedDescription)")
                try? await Task.sleep(for: .milliseconds(200))
            }
        }

        chatViewModel.inputText = transcript
        await chatViewModel.sendMessage()

        await waitForResponseAndSpeak()
    }

    /// Waits for the streaming response and speaks it incrementally.
    /// Sentences are fed to TTS as soon as they're complete (not waiting for full response).
    /// When TTS finishes, the `onComplete` callback (set up in `setupCallbacks()`)
    /// automatically restarts listening — no need to poll state here.
    private func waitForResponseAndSpeak() async {
        guard let chatViewModel else { return }

        if !isMuted {
            ttsService.startStreamingTTS()
        }

        // Poll for streaming content — feed sentences to TTS pipeline as they arrive
        var lastContent = ""
        while chatViewModel.isStreaming {
            if let lastMessage = chatViewModel.messages.last(where: { $0.role == .assistant }) {
                let newContent = lastMessage.content
                if newContent != lastContent {
                    lastContent = newContent
                    if !isMuted {
                        ttsService.feedStreamingText(newContent)
                    }
                }
            }
            try? await Task.sleep(for: .milliseconds(60))
        }

        // Send any remaining text to TTS
        if let finalMessage = chatViewModel.messages.last(where: { $0.role == .assistant }) {
            let finalContent = finalMessage.content

            if !isMuted && !finalContent.isEmpty {
                ttsService.finishStreamingTTS(finalText: finalContent)
                // onComplete callback will call startListening() when TTS finishes
            } else {
                ttsService.stop()
                if !isPaused && !isMuted {
                    await startListening()
                }
            }
        } else {
            ttsService.stop()
            if !isPaused && !isMuted {
                await startListening()
            }
        }
    }
}
