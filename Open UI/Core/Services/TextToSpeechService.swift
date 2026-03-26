import Foundation
import AVFoundation
import os.log
import NaturalLanguage

/// Manages text-to-speech with support for both Apple's AVSpeechSynthesizer,
/// on-device MarvisTTS, and server-side TTS.
///
/// ## TTS Engine Default
/// **AVSpeechSynthesizer** (system) is the default — works instantly with no
/// downloads. Users can opt in to MarvisTTS or Server TTS in Settings.
///
/// ## Auto Mode Priority (when selected by user)
/// 1. **MarvisTTS** (on-device neural) — if model is downloaded and loaded
/// 2. **Server TTS** (OpenWebUI API) — if configured
/// 3. **AVSpeechSynthesizer** (system) — fallback
@MainActor @Observable
final class TextToSpeechService: NSObject {

    // MARK: - Engine Selection

    enum TTSEngine: String, Sendable {
        case marvis   // On-device MarvisTTS
        case server   // Server-side TTS via OpenWebUI API
        case system   // Apple AVSpeechSynthesizer
        case auto     // Prefer MarvisTTS if loaded → server → system
    }

    // MARK: - State

    enum TTSState: Sendable {
        case idle
        case speaking
        case paused
    }

    private(set) var state: TTSState = .idle
    private(set) var isAvailable: Bool = true
    private(set) var activeEngine: TTSEngine = .system

    var isMarvisAvailable: Bool { marvisService.isAvailable }
    var marvisState: MarvisTTSState { marvisService.state }
    var marvisDownloadProgress: Double { marvisService.downloadProgress }

    // MARK: - Callbacks

    var onStart: (() -> Void)?
    var onComplete: (() -> Void)?
    var onError: ((String) -> Void)?

    // MARK: - Configuration

    var preferredEngine: TTSEngine = .system
    var speechRate: Float = AVSpeechUtteranceDefaultSpeechRate
    var pitchMultiplier: Float = 1.0
    var volume: Float = 1.0
    var voiceIdentifier: String?

    // MARK: - Server TTS

    var serverVoiceId: String?
    var serverSpeechRate: Double = 1.0
    var isServerAvailable: Bool { apiClient != nil }
    private(set) var apiClient: APIClient?

    /// The voice configured on the server (from /api/v1/audio/config tts.VOICE).
    /// Used as the fallback when the user selects "Server Default" (serverVoiceId == nil).
    var serverDefaultVoice: String?

    /// When set to true, output is forced to the loudspeaker after each audio session setup.
    /// Set by VoiceCallViewModel to persist speaker routing through the TTS pipeline.
    var speakerOverrideEnabled: Bool = false

    func configureServerTTS(apiClient: APIClient?) {
        self.apiClient = apiClient
    }

    // MARK: - Private

    private let synthesizer = AVSpeechSynthesizer()
    let marvisService = MarvisTTSService()
    private let logger = Logger(subsystem: "com.openui", category: "TTS")

    // System TTS queue
    private var systemQueue: [String] = []
    private var isSpeakingSystemChunk = false

    // Server TTS state
    private var serverQueue: [String] = []
    private var isRunningServerQueue = false
    private var serverAudioPlayer: AVAudioPlayer?

    // Server TTS prefetch pipeline
    /// Max number of audio chunks to fetch ahead of the currently playing chunk.
    private let serverPrefetchCount = 2
    /// Buffer of pre-fetched audio players ready to play (FIFO).
    private var prefetchedPlayers: [AVAudioPlayer] = []
    /// Background task that keeps the prefetch buffer filled.
    private var prefetchTask: Task<Void, Never>?

    // Active engine flags
    private var isUsingMarvis = false
    private var isUsingServer = false

    // MARK: - Streaming TTS State

    /// Character offset of cleaned text already enqueued for TTS.
    private(set) var streamingSpokenLength: Int = 0

    /// Whether streaming TTS mode is active (text is still arriving).
    private(set) var isStreamingTTS: Bool = false

    // MARK: - Init

    override init() {
        super.init()
        synthesizer.delegate = self

        // Restore saved engine preference
        if let saved = UserDefaults.standard.string(forKey: "ttsEngine") {
            switch saved {
            case "marvis", "mlx": preferredEngine = .marvis
            case "server":        preferredEngine = .server
            case "system":        preferredEngine = .system
            default:              preferredEngine = .auto
            }
        }

        // Restore saved server voice selection
        let savedServerVoice = UserDefaults.standard.string(forKey: "ttsServerVoiceId") ?? ""
        serverVoiceId = savedServerVoice.isEmpty ? nil : savedServerVoice

        // Restore Marvis voice & quality from UserDefaults so the user's
        // selection survives cold starts / model unload-reload cycles.
        let savedMarvisVoice = UserDefaults.standard.string(forKey: "ttsMarvisVoice") ?? "conversationalA"
        let savedMarvisQuality = UserDefaults.standard.integer(forKey: "ttsMarvisQuality")
        marvisService.config.voice = savedMarvisVoice
        marvisService.config.qualityLevel = savedMarvisQuality > 0 ? savedMarvisQuality : 32

        // Wire MarvisTTS callbacks
        marvisService.onSpeakingStarted = { [weak self] in
            Task { @MainActor [weak self] in
                self?.state = .speaking
                self?.onStart?()
            }
        }

        marvisService.onSpeakingComplete = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // If streaming mode is still active, more text may arrive — don't complete yet.
                if self.isStreamingTTS {
                    self.logger.info("MarvisTTS done but streaming still active — waiting")
                    return
                }
                self.state = .idle
                self.isUsingMarvis = false
                // Model stays loaded for fast re-use; unloaded only on background/explicit stop
                self.onComplete?()
            }
        }

        marvisService.onError = { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.logger.error("MarvisTTS error: \(error)")
                self.isUsingMarvis = false
                self.onError?(error)
            }
        }
    }

    // MARK: - MarvisTTS Configuration

    var marvisConfig: MarvisTTSConfig {
        get { marvisService.config }
        set { marvisService.config = newValue }
    }

    func preloadMarvisModel() async {
        guard marvisService.isAvailable else { return }
        do {
            try await marvisService.loadModel()
            logger.info("MarvisTTS model preloaded")
        } catch {
            logger.warning("MarvisTTS preload failed: \(error.localizedDescription)")
        }
    }

    func unloadMarvisModel() {
        marvisService.unloadModel()
    }

    // MARK: - Public API

    /// Speaks text immediately, interrupting any current speech.
    func speak(_ text: String) {
        let cleaned = TTSTextPreprocessor.prepareForSpeech(text)
        guard !cleaned.isEmpty else { return }

        stop()

        let engine = resolveEngine()
        activeEngine = engine

        switch engine {
        case .marvis:
            speakWithMarvis(cleaned)
        case .server:
            speakWithServer(cleaned)
        case .system, .auto:
            speakWithSystem(cleaned)
        }
    }

    /// Stops all speech and clears all queues.
    func stop() {
        // Stop MarvisTTS
        marvisService.stop()
        isUsingMarvis = false

        // Stop server TTS — cancel prefetch and clear all buffers
        prefetchTask?.cancel()
        prefetchTask = nil
        for player in prefetchedPlayers {
            player.stop()
        }
        prefetchedPlayers.removeAll()
        serverAudioPlayer?.stop()
        serverAudioPlayer = nil
        serverQueue.removeAll()
        isRunningServerQueue = false
        isUsingServer = false

        // Stop system TTS
        systemQueue.removeAll()
        isSpeakingSystemChunk = false
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }

        // Stop streaming state
        isStreamingTTS = false
        streamingSpokenLength = 0

        state = .idle

        // Deactivate audio session to release hardware resources
        deactivateAudioSession()
    }

    func pause() {
        if isUsingMarvis {
            marvisService.stop()
            state = .paused
        } else if synthesizer.isSpeaking {
            synthesizer.pauseSpeaking(at: .word)
            state = .paused
        }
    }

    func resume() {
        if synthesizer.isPaused {
            synthesizer.continueSpeaking()
            state = .speaking
        }
    }

    func availableVoices() -> [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .sorted { lhs, rhs in
                if lhs.language != rhs.language {
                    return lhs.language < rhs.language
                }
                return lhs.quality.rawValue > rhs.quality.rawValue
            }
    }

    /// Detects the dominant language of `text` using NLLanguageRecognizer and
    /// returns the highest-quality installed `AVSpeechSynthesisVoice` for that
    /// language. Falls back to the device locale voice if detection fails or no
    /// matching voice is installed.
    private func bestVoice(for text: String) -> AVSpeechSynthesisVoice? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        let detected = recognizer.dominantLanguage?.rawValue  // e.g. "fr", "de", "ja"

        let allVoices = AVSpeechSynthesisVoice.speechVoices()

        // Try to find a voice whose BCP-47 tag starts with the detected language code
        if let lang = detected, !lang.isEmpty {
            let match = allVoices
                .filter { $0.language.hasPrefix(lang) }
                .sorted { $0.quality.rawValue > $1.quality.rawValue }
                .first
            if let match { return match }
        }

        // Fallback: device locale
        let deviceLang = Locale.current.language.languageCode?.identifier ?? "en"
        return allVoices
            .filter { $0.language.hasPrefix(deviceLang) }
            .sorted { $0.quality.rawValue > $1.quality.rawValue }
            .first
        ?? AVSpeechSynthesisVoice(language: "en-US")
    }

    // MARK: - Streaming TTS

    /// Call before streaming begins. Resets spoken-length tracking.
    /// Does NOT unload the model — only stops playback and clears queues.
    func startStreamingTTS() {
        // Stop any active speech without unloading the model
        marvisService.stop()
        isUsingMarvis = false

        prefetchTask?.cancel()
        prefetchTask = nil
        prefetchedPlayers.forEach { $0.stop() }
        prefetchedPlayers.removeAll()
        serverAudioPlayer?.stop()
        serverAudioPlayer = nil
        serverQueue.removeAll()
        isRunningServerQueue = false
        isUsingServer = false

        systemQueue.removeAll()
        isSpeakingSystemChunk = false
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }

        state = .idle
        isStreamingTTS = true
        streamingSpokenLength = 0
    }

    /// Feed accumulated streaming text. Extracts new complete sentences and enqueues them.
    func feedStreamingText(_ accumulatedText: String) {
        guard isStreamingTTS else { return }

        let (newChunks, newLength) = TTSTextPreprocessor.extractNewSpeakableChunks(
            from: accumulatedText,
            alreadySpokenLength: streamingSpokenLength
        )
        guard !newChunks.isEmpty else { return }
        streamingSpokenLength = newLength

        let engine = resolveEngine()
        activeEngine = engine

        // For MarvisTTS, join all chunks into one — the library handles streaming internally
        if engine == .marvis {
            let joined = newChunks.joined(separator: " ")
            enqueueChunk(joined, engine: engine)
        } else {
            for chunk in newChunks {
                enqueueChunk(chunk, engine: engine)
            }
        }
    }

    /// Call when streaming is complete. Speaks any remaining text then fires onComplete.
    func finishStreamingTTS(finalText: String) {
        guard isStreamingTTS else { return }

        let (remaining, newLength) = TTSTextPreprocessor.extractFinalChunks(
            from: finalText,
            alreadySpokenLength: streamingSpokenLength
        )
        streamingSpokenLength = newLength
        isStreamingTTS = false  // Mark streaming done BEFORE enqueuing final chunks

        let engine = resolveEngine()
        activeEngine = engine

        if remaining.isEmpty {
            // Nothing left to speak — check if TTS is already idle
            let marvisBusy = isUsingMarvis && marvisService.isPlaying
            let serverBusy = isUsingServer
            let systemBusy = isSpeakingSystemChunk
            if !marvisBusy && !serverBusy && !systemBusy {
                state = .idle
                onComplete?()
            }
            return
        }

        if engine == .marvis {
            let joined = remaining.joined(separator: " ")
            enqueueChunk(joined, engine: engine)
        } else {
            for chunk in remaining {
                enqueueChunk(chunk, engine: engine)
            }
        }
    }

    // MARK: - Engine Resolution

    private func resolveEngine() -> TTSEngine {
        switch preferredEngine {
        case .marvis:
            return marvisService.isAvailable ? .marvis : .system
        case .server:
            return isServerAvailable ? .server : .system
        case .system:
            return .system
        case .auto:
            if marvisService.isAvailable && marvisService.isReady { return .marvis }
            if isServerAvailable { return .server }
            return .system
        }
    }

    // MARK: - MarvisTTS

    private func speakWithMarvis(_ text: String) {
        isUsingMarvis = true
        state = .speaking
        Task {
            await marvisService.speak(text)
        }
    }

    // MARK: - Server TTS

    private func speakWithServer(_ text: String) {
        isUsingServer = true
        state = .speaking
        onStart?()
        let sentences = TTSTextPreprocessor.splitIntoSentences(text)
        serverQueue.append(contentsOf: sentences)
        if !isRunningServerQueue {
            isRunningServerQueue = true
            startServerPipeline()
        }
    }

    /// Starts the two-stage server TTS pipeline:
    /// - **Producer** (prefetchTask): fetches audio from the server up to `serverPrefetchCount`
    ///   chunks ahead and stores ready-to-play `AVAudioPlayer` instances in `prefetchedPlayers`.
    /// - **Consumer** (this task): plays from `prefetchedPlayers`, popping the front player
    ///   as soon as the previous one finishes, giving seamless gapless playback.
    private func startServerPipeline() {
        guard let apiClient else {
            logger.error("Server TTS: no API client, falling back to system")
            isRunningServerQueue = false
            isUsingServer = false
            let remaining = serverQueue.joined(separator: " ")
            serverQueue.removeAll()
            speakWithSystem(remaining)
            return
        }

        // Resolve the effective voice: user override → server config default → nil
        // When nil, the API falls back to whatever its own built-in default is,
        // which may NOT match the admin-configured voice. By explicitly sending
        // the server-configured voice we honour the admin's choice.
        let voiceId = serverVoiceId ?? serverDefaultVoice
        let speakerOverride = speakerOverrideEnabled

        // --- Producer: fill prefetch buffer up to serverPrefetchCount ahead ---
        prefetchTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                // Pull next text chunk from the queue (must happen on MainActor)
                let chunk: String? = await MainActor.run {
                    guard !self.serverQueue.isEmpty else { return nil }
                    return self.serverQueue.removeFirst()
                }

                guard let text = chunk else {
                    // Queue empty — wait briefly for more chunks (streaming may add them)
                    try? await Task.sleep(for: .milliseconds(80))
                    let stillEmpty = await MainActor.run { self.serverQueue.isEmpty }
                    if stillEmpty { break }
                    continue
                }

                // Throttle: don't get too far ahead of the consumer
                while !Task.isCancelled {
                    let bufferSize = await MainActor.run { self.prefetchedPlayers.count }
                    if bufferSize < self.serverPrefetchCount { break }
                    try? await Task.sleep(for: .milliseconds(50))
                }
                guard !Task.isCancelled else { break }

                do {
                    let (audioData, _) = try await apiClient.generateSpeech(
                        text: text,
                        voice: voiceId
                    )
                    let player = try AVAudioPlayer(data: audioData)
                    player.prepareToPlay()
                    // Deposit into buffer on MainActor
                    await MainActor.run {
                        if !Task.isCancelled {
                            self.prefetchedPlayers.append(player)
                        }
                    }
                } catch {
                    await MainActor.run {
                        self.logger.error("Server TTS prefetch failed: \(error.localizedDescription)")
                    }
                    // On error skip this chunk and continue
                }
            }
        }

        // --- Consumer: play from prefetch buffer continuously ---
        Task { [weak self] in
            guard let self else { return }

            // Configure audio session once before starting playback
            let session = AVAudioSession.sharedInstance()
            if speakerOverride {
                try? session.setCategory(.playAndRecord, mode: .voiceChat,
                                         options: [.defaultToSpeaker, .allowBluetoothA2DP])
                try? session.setActive(true)
                try? session.overrideOutputAudioPort(.speaker)
            } else {
                try? session.setCategory(.playback, mode: .default)
                try? session.setActive(true)
            }

            var playedAtLeastOne = false

            // Keep playing until the buffer is empty AND the producer is done
            while true {
                // Pop next player from front of buffer
                let player: AVAudioPlayer? = await MainActor.run {
                    guard !self.prefetchedPlayers.isEmpty else { return nil }
                    return self.prefetchedPlayers.removeFirst()
                }

                if let player {
                    playedAtLeastOne = true
                    self.serverAudioPlayer = player
                    player.play()
                    while player.isPlaying {
                        try? await Task.sleep(for: .milliseconds(30))
                    }
                    // Release finished player immediately to free memory
                    player.stop()
                    await MainActor.run { self.serverAudioPlayer = nil }
                } else {
                    // Buffer empty — check if producer is still running
                    let producerDone = await MainActor.run {
                        self.prefetchTask?.isCancelled ?? true
                    }
                    let queueEmpty = await MainActor.run { self.serverQueue.isEmpty }

                    if producerDone || queueEmpty {
                        // Give producer a brief moment to deposit last chunk
                        try? await Task.sleep(for: .milliseconds(120))
                        let stillEmpty = await MainActor.run { self.prefetchedPlayers.isEmpty }
                        if stillEmpty { break }
                    } else {
                        // Producer still working — wait for next chunk
                        try? await Task.sleep(for: .milliseconds(30))
                    }
                }
            }

            // All chunks played (or stop() was called)
            await MainActor.run {
                self.prefetchTask?.cancel()
                self.prefetchTask = nil
                self.serverAudioPlayer = nil
                self.isRunningServerQueue = false
                self.isUsingServer = false

                if !self.isStreamingTTS {
                    self.state = .idle
                    self.deactivateAudioSession()
                    if playedAtLeastOne {
                        self.onComplete?()
                    }
                }
            }
        }
    }

    // MARK: - System TTS

    private func speakWithSystem(_ text: String) {
        systemQueue.append(contentsOf: TTSTextPreprocessor.splitIntoSentences(text))
        if !isSpeakingSystemChunk {
            speakNextSystemChunk()
        }
    }

    private func speakNextSystemChunk() {
        guard !systemQueue.isEmpty else {
            isSpeakingSystemChunk = false
            if !isStreamingTTS && !isUsingMarvis && !isUsingServer {
                state = .idle
                deactivateAudioSession()
                onComplete?()
            }
            return
        }

        let chunk = systemQueue.removeFirst()
        let utterance = AVSpeechUtterance(string: chunk)

        if let voiceId = voiceIdentifier,
           let voice = AVSpeechSynthesisVoice(identifier: voiceId) {
            utterance.voice = voice
        } else {
            // Auto-detect the language of the text and pick a matching voice.
            // This ensures non-English responses are spoken with correct pronunciation.
            utterance.voice = bestVoice(for: chunk)
        }

        utterance.rate = speechRate
        utterance.pitchMultiplier = pitchMultiplier
        utterance.volume = volume
        utterance.preUtteranceDelay = 0
        utterance.postUtteranceDelay = 0.05

        do {
            let session = AVAudioSession.sharedInstance()
            if speakerOverrideEnabled {
                // Voice call — keep mic+speaker active and force loudspeaker
                try session.setCategory(.playAndRecord, mode: .voiceChat,
                                        options: [.defaultToSpeaker, .allowBluetoothA2DP])
                try session.setActive(true)
                try session.overrideOutputAudioPort(.speaker)
            } else {
                // Regular read-aloud — use playback mode which routes to loudspeaker by default
                try session.setCategory(.playback, mode: .default)
                try session.setActive(true)
            }
        } catch {
            logger.warning("Audio session config skipped: \(error.localizedDescription)")
        }

        isSpeakingSystemChunk = true
        state = .speaking
        if systemQueue.isEmpty { onStart?() }

        synthesizer.speak(utterance)
    }

    // MARK: - Audio Session Management

    /// Deactivates the shared audio session to release hardware resources.
    /// Called after all TTS playback finishes (both natural completion and stop()).
    private func deactivateAudioSession() {
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: .notifyOthersOnDeactivation
        )
    }

    // MARK: - Chunk Enqueuing (used by streaming TTS)

    private func enqueueChunk(_ chunk: String, engine: TTSEngine) {
        switch engine {
        case .marvis:
            isUsingMarvis = true
            Task { await marvisService.enqueue(chunk) }
        case .server:
            isUsingServer = true
            serverQueue.append(chunk)
            if !isRunningServerQueue {
                isRunningServerQueue = true
                startServerPipeline()
            }
        case .system, .auto:
            systemQueue.append(chunk)
            if !isSpeakingSystemChunk {
                speakNextSystemChunk()
            }
        }
    }
}

// MARK: - AVSpeechSynthesizerDelegate

extension TextToSpeechService: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            self?.speakNextSystemChunk()
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.isSpeakingSystemChunk = false
            self.state = .idle
        }
    }
}
