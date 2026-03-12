import SwiftUI
import UIKit

// MARK: - Keyboard Tracker

@Observable
final class KeyboardTracker {

    // MARK: - Public State

    private(set) var height: CGFloat = 0
    private(set) var isVisible: Bool = false
    private(set) var animationDuration: Double = 0.25
    private(set) var animationCurve: UIView.AnimationCurve = .easeInOut

    // MARK: - Private

    private var showObserver: NSObjectProtocol?
    private var hideObserver: NSObjectProtocol?
    private var changeObserver: NSObjectProtocol?

    // MARK: - Lifecycle

    func start() {
        guard showObserver == nil else { return }

        showObserver = NotificationCenter.default.addObserver(
            forName: UIResponder.keyboardWillShowNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleKeyboardNotification(notification, visible: true)
        }

        hideObserver = NotificationCenter.default.addObserver(
            forName: UIResponder.keyboardWillHideNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleKeyboardNotification(notification, visible: false)
        }

        changeObserver = NotificationCenter.default.addObserver(
            forName: UIResponder.keyboardWillChangeFrameNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleKeyboardNotification(notification, visible: nil)
        }
    }

    func stop() {
        if let obs = showObserver { NotificationCenter.default.removeObserver(obs) }
        if let obs = hideObserver { NotificationCenter.default.removeObserver(obs) }
        if let obs = changeObserver { NotificationCenter.default.removeObserver(obs) }
        showObserver = nil
        hideObserver = nil
        changeObserver = nil
    }

    deinit { stop() }

    // MARK: - Notification Handling

    private func handleKeyboardNotification(_ notification: Notification, visible: Bool?) {
        guard let userInfo = notification.userInfo else { return }

        let duration = (userInfo[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? 0.25
        let curveRaw = (userInfo[UIResponder.keyboardAnimationCurveUserInfoKey] as? Int) ?? UIView.AnimationCurve.easeInOut.rawValue
        let curve = UIView.AnimationCurve(rawValue: curveRaw) ?? .easeInOut

        guard let endFrame = (userInfo[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect) else { return }

        let screenHeight = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.screen.bounds.height ?? UIScreen.main.bounds.height
        let keyboardTop = endFrame.minY
        let newHeight = max(0, screenHeight - keyboardTop)

        let newVisible: Bool
        if let visible {
            newVisible = visible
        } else {
            newVisible = newHeight > 0
        }

        let safeBottom = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.windows.first?.safeAreaInsets.bottom ?? 0

        // Floating/undocked keyboard: endFrame.maxY < screenHeight means
        // the keyboard isn't docked at the bottom — don't push content up.
        let isDocked = endFrame.maxY >= screenHeight
        let adjustedHeight = (newVisible && isDocked) ? max(0, newHeight - safeBottom) : 0

        animationDuration = duration
        animationCurve = curve

        withAnimation(swiftUIAnimation(duration: duration, curve: curve)) {
            height = adjustedHeight
            isVisible = newVisible
        }
    }

    // MARK: - Helpers

    private func swiftUIAnimation(duration: Double, curve: UIView.AnimationCurve) -> Animation {
        switch curve {
        case .easeIn:
            return .easeIn(duration: duration)
        case .easeOut:
            return .easeOut(duration: duration)
        case .easeInOut:
            return .easeInOut(duration: duration)
        case .linear:
            return .linear(duration: duration)
        @unknown default:
            return .interactiveSpring(response: duration, dampingFraction: 1.0, blendDuration: 0)
        }
    }

    var matchedAnimation: Animation {
        swiftUIAnimation(duration: animationDuration, curve: animationCurve)
    }
}
