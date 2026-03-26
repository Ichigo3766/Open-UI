import SwiftUI
import Speech

/// Modern compact voice call interface presented as a sheet.
/// Minimal, sleek design inspired by iOS Live Activities and Dynamic Island.
struct VoiceCallView: View {
    @State var viewModel: VoiceCallViewModel
    @Environment(AppDependencyContainer.self) private var dependencies
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    /// Whether to start a new conversation for this call.
    var startNewConversation: Bool = false

    @AppStorage("sttLocale") private var sttLocale: String = ""
    @AppStorage("ttsVoiceIdentifier") private var ttsVoiceIdentifier: String = ""
    @State private var showVoiceSettings = false

    var body: some View {
        VStack(spacing: 0) {
            // Drag indicator
            Capsule()
                .fill(Color.white.opacity(0.3))
                .frame(width: 36, height: 5)
                .padding(.top, 8)
                .padding(.bottom, 20)

            // Header: model name + timer
            headerSection
                .padding(.bottom, 24)

            // Animated visualization
            orbSection
                .padding(.bottom, 16)

            // State label
            stateChip
                .padding(.bottom, 8)

            // Transcript
            transcriptSection
                .padding(.bottom, 24)

            Spacer(minLength: 0)

            // Controls
            controlsSection
                .padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity)
        .background(
            ZStack {
                // Base dark
                Color(red: 0.06, green: 0.06, blue: 0.09)

                // Subtle gradient tint based on state
                stateGradient
                    .opacity(0.4)
                    .animation(.easeInOut(duration: 0.8), value: viewModel.callState)
            }
            .ignoresSafeArea()
        )
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: viewModel.callState)
        .task {
            await initializeCall()
        }
    }

    // MARK: - State Gradient

    private var stateGradient: some View {
        Group {
            switch viewModel.callState {
            case .listening:
                LinearGradient(
                    colors: [Color.blue.opacity(0.15), .clear],
                    startPoint: .top,
                    endPoint: .center
                )
            case .speaking:
                LinearGradient(
                    colors: [Color.green.opacity(0.12), .clear],
                    startPoint: .top,
                    endPoint: .center
                )
            case .processing:
                LinearGradient(
                    colors: [Color.purple.opacity(0.1), .clear],
                    startPoint: .top,
                    endPoint: .center
                )
            default:
                LinearGradient(
                    colors: [.clear, .clear],
                    startPoint: .top,
                    endPoint: .center
                )
            }
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack(spacing: 12) {
            // Avatar
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Color.blue.opacity(0.5), Color.purple.opacity(0.3)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 44, height: 44)

                Image(systemName: "waveform")
                    .scaledFont(size: 18, weight: .medium)
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(viewModel.modelName.isEmpty ? "AI Assistant" : viewModel.modelName)
                    .scaledFont(size: 17, weight: .semibold)
                    .foregroundStyle(.white)
                    .lineLimit(1)

                Text(viewModel.formattedDuration)
                    .scaledFont(size: 13, weight: .medium, design: .monospaced)
                    .foregroundStyle(.white.opacity(0.5))
                    .contentTransition(.numericText())
            }

            Spacer()

            // Minimal end call
            Button {
                Task {
                    await viewModel.endCall()
                    dismiss()
                }
            } label: {
                Image(systemName: "xmark")
                    .scaledFont(size: 14, weight: .bold)
                    .foregroundStyle(.white.opacity(0.6))
                    .frame(width: 32, height: 32)
                    .background(.white.opacity(0.1))
                    .clipShape(Circle())
            }
        }
        .padding(.horizontal, 24)
    }

    // MARK: - Orb

    private var orbSection: some View {
        CompactOrbView(
            state: viewModel.callState,
            intensity: viewModel.voiceIntensity
        )
        .frame(height: 160)
    }

    // MARK: - State Chip

    private var stateChip: some View {
        HStack(spacing: 6) {
            switch viewModel.callState {
            case .connecting:
                ProgressView()
                    .tint(.white.opacity(0.6))
                    .controlSize(.mini)
                Text("Connecting")
            case .listening:
                Circle()
                    .fill(Color.blue)
                    .frame(width: 6, height: 6)
                Text("Listening")
            case .processing:
                ProgressView()
                    .tint(.white.opacity(0.6))
                    .controlSize(.mini)
                Text("Thinking")
            case .speaking:
                Circle()
                    .fill(Color.green)
                    .frame(width: 6, height: 6)
                Text("Speaking")
            case .paused:
                Circle()
                    .fill(Color.orange)
                    .frame(width: 6, height: 6)
                Text("Paused")
            case .error:
                Circle()
                    .fill(Color.red)
                    .frame(width: 6, height: 6)
                Text("Error")
            case .disconnected:
                Text("Ended")
            case .idle:
                Text("Ready")
            }
        }
        .scaledFont(size: 12, weight: .medium)
        .foregroundStyle(.white.opacity(0.5))
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(.white.opacity(0.06))
        .clipShape(Capsule())
    }

    // MARK: - Transcript

    private var transcriptSection: some View {
        Group {
            if !viewModel.currentTranscript.isEmpty && viewModel.callState == .listening {
                Text(viewModel.currentTranscript)
                    .scaledFont(size: 15)
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(3)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            } else if case .error(let msg) = viewModel.callState {
                Text(msg)
                    .scaledFont(size: 13)
                    .foregroundStyle(.red.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
        }
        .frame(minHeight: 40)
    }

    // MARK: - Controls

    private var controlsSection: some View {
        HStack(spacing: 0) {
            Spacer()

            // Mute
            compactControl(
                icon: viewModel.isMuted ? "mic.slash.fill" : "mic.fill",
                isActive: viewModel.isMuted,
                activeColor: .red
            ) {
                viewModel.toggleMute()
            }

            Spacer()

            // Context action (skip/pause/resume/retry)
            contextAction

            Spacer()

            // Speaker toggle
            compactControl(
                icon: viewModel.isSpeakerOn ? "speaker.wave.3.fill" : "speaker.slash.fill",
                isActive: viewModel.isSpeakerOn,
                activeColor: .white.opacity(0.85)
            ) {
                viewModel.toggleSpeaker()
            }

            Spacer()

            // Voice / language settings
            compactControl(icon: "globe", isActive: false) {
                showVoiceSettings = true
            }

            Spacer()

            // End call
            compactControl(
                icon: "phone.down.fill",
                isActive: true,
                activeColor: .red,
                size: 56
            ) {
                Task {
                    await viewModel.endCall()
                    dismiss()
                }
            }

            Spacer()
        }
        .sheet(isPresented: $showVoiceSettings) {
            VoiceCallSettingsSheet(
                sttLocale: $sttLocale,
                ttsVoiceIdentifier: $ttsVoiceIdentifier,
                speechService: dependencies.speechRecognitionService,
                ttsService: dependencies.textToSpeechService
            )
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
        }
    }

    @ViewBuilder
    private var contextAction: some View {
        switch viewModel.callState {
        case .speaking:
            compactControl(icon: "forward.fill", isActive: false) {
                Task { await viewModel.cancelSpeaking() }
            }
        case .paused:
            compactControl(icon: "play.fill", isActive: false) {
                Task { await viewModel.resumeListening() }
            }
        case .listening:
            compactControl(icon: "pause.fill", isActive: false) {
                viewModel.pauseListening()
            }
        case .error:
            compactControl(icon: "arrow.clockwise", isActive: false) {
                Task { await initializeCall() }
            }
        default:
            compactControl(icon: "pause.fill", isActive: false) {}
                .opacity(0.2)
                .disabled(true)
        }
    }

    // MARK: - Compact Control Button

    private func compactControl(
        icon: String,
        isActive: Bool,
        activeColor: Color = .white,
        size: CGFloat = 48,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Circle()
                .fill(isActive ? activeColor : .white.opacity(0.1))
                .frame(width: size, height: size)
                .overlay(
                    Image(systemName: icon)
                        .scaledFont(size: size * 0.38, weight: .semibold)
                        .foregroundStyle(isActive ? .white : .white.opacity(0.8))
                )
        }
    }

    // MARK: - Initialize

    private func initializeCall() async {
        if startNewConversation, let manager = dependencies.conversationManager {
            let chatVM = ChatViewModel()
            chatVM.configure(with: manager)
            await chatVM.loadModels()
            viewModel.configure(
                conversationManager: manager,
                chatViewModel: chatVM,
                modelName: chatVM.selectedModel?.name ?? "AI Assistant"
            )
        }
        await viewModel.startCall()
    }
}

// MARK: - Compact Orb View

/// A refined, minimal orb visualization.
struct CompactOrbView: View {
    let state: VoiceCallViewModel.CallState
    let intensity: Int

    @State private var phase: CGFloat = 0
    @State private var pulse: CGFloat = 1.0

    private var normalizedIntensity: CGFloat {
        CGFloat(min(intensity, 10)) / 10.0
    }

    private var orbColor: Color {
        switch state {
        case .listening: return .blue
        case .speaking: return .green
        case .processing: return .purple
        case .connecting: return .white.opacity(0.4)
        default: return .white.opacity(0.15)
        }
    }

    private var isAnimating: Bool {
        switch state {
        case .listening, .speaking, .processing, .connecting: return true
        default: return false
        }
    }

    var body: some View {
        ZStack {
            // Outer ambient glow
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            orbColor.opacity(0.12 + normalizedIntensity * 0.15),
                            .clear
                        ],
                        center: .center,
                        startRadius: 30,
                        endRadius: 100
                    )
                )
                .frame(width: 200, height: 200)
                .scaleEffect(pulse + normalizedIntensity * 0.1)

            // Ring
            Circle()
                .stroke(
                    orbColor.opacity(0.2 + normalizedIntensity * 0.3),
                    lineWidth: 1.5
                )
                .frame(width: 100 + normalizedIntensity * 20, height: 100 + normalizedIntensity * 20)
                .scaleEffect(pulse)

            // Core
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            orbColor.opacity(0.8),
                            orbColor.opacity(0.4),
                            orbColor.opacity(0.1)
                        ],
                        center: .center,
                        startRadius: 5,
                        endRadius: 35
                    )
                )
                .frame(width: 70, height: 70)
                .scaleEffect(pulse + normalizedIntensity * 0.25)
                .shadow(color: orbColor.opacity(0.4), radius: 15 + normalizedIntensity * 10)

            // Inner highlight
            Circle()
                .fill(
                    RadialGradient(
                        colors: [.white.opacity(0.35), .clear],
                        center: UnitPoint(x: 0.38, y: 0.38),
                        startRadius: 0,
                        endRadius: 20
                    )
                )
                .frame(width: 50, height: 50)
                .scaleEffect(pulse + normalizedIntensity * 0.25)
        }
        .animation(.easeOut(duration: 0.12), value: intensity)
        .onAppear { startPulse() }
        .onChange(of: isAnimating) { _, active in
            if active { startPulse() } else { stopPulse() }
        }
    }

    private func startPulse() {
        withAnimation(
            .easeInOut(duration: 2.0)
            .repeatForever(autoreverses: true)
        ) {
            pulse = 1.08
        }
    }

    private func stopPulse() {
        withAnimation(.easeOut(duration: 0.3)) {
            pulse = 1.0
        }
    }
}

// MARK: - Voice Call Settings Sheet

/// Compact in-call sheet for quickly switching STT language and TTS voice.
struct VoiceCallSettingsSheet: View {
    @Binding var sttLocale: String
    @Binding var ttsVoiceIdentifier: String
    let speechService: SpeechRecognitionService
    let ttsService: TextToSpeechService
    @Environment(\.dismiss) private var dismiss

    private var supportedSTTLocales: [Locale] {
        SFSpeechRecognizer.supportedLocales()
            .sorted {
                (Locale.current.localizedString(forIdentifier: $0.identifier) ?? $0.identifier)
                    < (Locale.current.localizedString(forIdentifier: $1.identifier) ?? $1.identifier)
            }
    }

    private var availableTTSVoices: [AVSpeechSynthesisVoice] {
        ttsService.availableVoices()
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Speech Recognition Language") {
                    NavigationLink {
                        STTLanguagePickerView(sttLocale: $sttLocale, locales: supportedSTTLocales)
                            .onChange(of: sttLocale) { _, newValue in
                                speechService.updateLocale(newValue)
                            }
                    } label: {
                        HStack {
                            Text("Language")
                            Spacer()
                            Text(
                                sttLocale.isEmpty
                                    ? "Auto"
                                    : (Locale.current.localizedString(forIdentifier: sttLocale) ?? sttLocale)
                            )
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        }
                    }
                }

                Section("Text-to-Speech Voice") {
                    NavigationLink {
                        TTSVoicePickerView(voiceIdentifier: $ttsVoiceIdentifier, voices: availableTTSVoices)
                            .onChange(of: ttsVoiceIdentifier) { _, newValue in
                                ttsService.voiceIdentifier = newValue.isEmpty ? nil : newValue
                            }
                    } label: {
                        HStack {
                            Text("Voice")
                            Spacer()
                            Text(
                                ttsVoiceIdentifier.isEmpty
                                    ? "Auto (detect language)"
                                    : (AVSpeechSynthesisVoice(identifier: ttsVoiceIdentifier)?.name ?? ttsVoiceIdentifier)
                            )
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        }
                    }
                }
            }
            .navigationTitle("Voice Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
