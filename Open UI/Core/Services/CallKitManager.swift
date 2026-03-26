import Foundation
import CallKit
import os.log

/// Manages CallKit integration for native iOS call UI during voice calls.
///
/// Provides the system call screen experience, including the lock-screen
/// call UI, mute/hold controls, and proper audio session management.
@MainActor @Observable
final class CallKitManager: NSObject {

    // MARK: - State

    /// Whether a CallKit call is currently active.
    private(set) var isCallActive: Bool = false

    /// The current call's UUID.
    private(set) var activeCallUUID: UUID?

    // MARK: - Callbacks

    /// Called when the user ends the call from the CallKit UI.
    var onCallEnded: (() -> Void)?

    /// Called when the user toggles mute from the CallKit UI.
    var onMuteToggled: ((Bool) -> Void)?

    /// Called when the user toggles hold from the CallKit UI.
    var onHoldToggled: ((Bool) -> Void)?

    /// Called when CallKit activates the audio session so the speaker override can be re-applied.
    var onAudioSessionActivated: (() -> Void)?

    // MARK: - Private

    private let logger = Logger(subsystem: "com.openui", category: "CallKit")
    private let provider: CXProvider
    private let callController = CXCallController()
    private var isMuted = false

    // MARK: - Init

    override init() {
        let config = CXProviderConfiguration()
        config.maximumCallGroups = 1
        config.maximumCallsPerCallGroup = 1
        config.supportsVideo = false
        config.supportedHandleTypes = [.generic]
        config.iconTemplateImageData = nil // Could set app icon data here

        self.provider = CXProvider(configuration: config)
        super.init()
        provider.setDelegate(self, queue: nil)
    }

    // MARK: - Public API

    /// Starts an outgoing call with the given display name.
    func startCall(displayName: String) async throws {
        let uuid = UUID()
        activeCallUUID = uuid

        let handle = CXHandle(type: .generic, value: displayName)
        let startCallAction = CXStartCallAction(call: uuid, handle: handle)
        startCallAction.isVideo = false
        startCallAction.contactIdentifier = displayName

        let transaction = CXTransaction(action: startCallAction)

        do {
            try await callController.request(transaction)
            isCallActive = true

            // Report the call as connected after a brief delay
            try? await Task.sleep(for: .milliseconds(500))
            reportCallConnected()
        } catch {
            logger.error("Failed to start CallKit call: \(error.localizedDescription)")
            activeCallUUID = nil
            throw error
        }
    }

    /// Reports the call as connected (shows connected state in UI).
    func reportCallConnected() {
        guard let uuid = activeCallUUID else { return }
        provider.reportCall(with: uuid, updated: CXCallUpdate())
        provider.reportOutgoingCall(with: uuid, connectedAt: .now)
    }

    /// Ends the active CallKit call.
    func endCall() async {
        guard let uuid = activeCallUUID else { return }

        let endCallAction = CXEndCallAction(call: uuid)
        let transaction = CXTransaction(action: endCallAction)

        do {
            try await callController.request(transaction)
        } catch {
            logger.error("Failed to end CallKit call: \(error.localizedDescription)")
            // Force end if the transaction fails
            provider.reportCall(with: uuid, endedAt: .now, reason: .remoteEnded)
        }

        isCallActive = false
        activeCallUUID = nil
    }

    /// Updates the caller display name during an active call.
    func updateCallerInfo(displayName: String) {
        guard let uuid = activeCallUUID else { return }

        let update = CXCallUpdate()
        update.localizedCallerName = displayName
        update.hasVideo = false
        provider.reportCall(with: uuid, updated: update)
    }

    /// Cleans up any lingering calls from previous sessions.
    func cleanupStaleCalls() {
        if let uuid = activeCallUUID {
            provider.reportCall(with: uuid, endedAt: .now, reason: .remoteEnded)
            activeCallUUID = nil
            isCallActive = false
        }
    }
}

// MARK: - CXProviderDelegate

extension CallKitManager: CXProviderDelegate {
    nonisolated func providerDidReset(_ provider: CXProvider) {
        Task { @MainActor [weak self] in
            self?.isCallActive = false
            self?.activeCallUUID = nil
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        // Configure audio session for voice call
        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetoothA2DP])
            try audioSession.setActive(true)
        } catch {
            // Log but don't fail the call
        }
        action.fulfill()
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        Task { @MainActor [weak self] in
            self?.isCallActive = false
            self?.activeCallUUID = nil
            self?.onCallEnded?()
        }
        action.fulfill()
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        Task { @MainActor [weak self] in
            self?.isMuted = action.isMuted
            self?.onMuteToggled?(action.isMuted)
        }
        action.fulfill()
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXSetHeldCallAction) {
        Task { @MainActor [weak self] in
            self?.onHoldToggled?(action.isOnHold)
        }
        action.fulfill()
    }

    nonisolated func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        // Re-apply speaker override after CallKit takes control of the audio session
        Task { @MainActor [weak self] in
            self?.onAudioSessionActivated?()
        }
    }

    nonisolated func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        // Audio session deactivated
    }
}

// MARK: - AVFoundation import for audio session

import AVFoundation
