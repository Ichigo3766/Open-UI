//
//  OpenUIWidgetsControl.swift
//  OpenUIWidgets
//
//  Control Center widget (iOS 18+) — one-tap "New Chat" button.
//

import AppIntents
import SwiftUI
import WidgetKit

// MARK: - New Chat Control Button

struct OpenUIWidgetsControl: ControlWidget {
    static let kind: String = "com.openui.openui.OpenUINewChatControl"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: OpenNewChatControlIntent()) {
                Label("New Chat", systemImage: "bubble.left.and.text.bubble.right.fill")
            }
        }
        .displayName("New Chat")
        .description("Start a new AI chat instantly from Control Center.")
    }
}

// MARK: - Control Intent

struct OpenNewChatControlIntent: AppIntent {
    static var title: LocalizedStringResource = "New Chat"
    static var description = IntentDescription("Open a new chat in Open Relay.")
    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult & OpensIntent {
        // Open the app via the deep link URL, which triggers the .onOpenURL
        // handler in Open_UIApp.swift — the same path used by the home screen widget.
        // This is far more reliable than the cross-process UserDefaults relay, which
        // had a race condition where the main app might read before the value was set.
        return .result(opensIntent: OpenURLIntent(URL(string: "openui://new-chat")!))
    }
}
