//
//  OpenUIWidgets.swift
//  OpenUIWidgets
//
//  Open UI widget suite — action-focused, instant-launch widgets.
//  Gemini-style: full-bleed circles, real app icon, minimal padding.
//  Uses UIKit semantic colors so dark/light mode follow the system automatically.
//

import WidgetKit
import SwiftUI

// MARK: - Deep Link URLs

private enum OpenUIURL {
    static let newChat    = URL(string: "openui://new-chat")!
    static let voiceCall  = URL(string: "openui://voice-call")!
    static let cameraChat = URL(string: "openui://camera-chat")!
    static let photosChat = URL(string: "openui://photos-chat")!
    static let fileChat   = URL(string: "openui://file-chat")!
    static let newChannel = URL(string: "openui://new-channel")!
}

// MARK: - Semantic Adaptive Colors
//
// These UIKit system colors automatically switch between light and dark mode
// without reading @Environment(\.colorScheme), which is unreliable in widget
// extensions. No custom color math needed.

private extension Color {
    /// Widget canvas background — white in light mode, near-black in dark mode.
    static let widgetBg          = Color(uiColor: .systemBackground)

    /// Circle / pill fills — light gray in light, dark gray in dark.
    static let widgetCircleFill  = Color(uiColor: .secondarySystemBackground)

    /// Slightly lighter secondary fill (used for medium action circles).
    static let widgetPillFill    = Color(uiColor: .secondarySystemBackground)

    /// Search bar border stroke.
    static let widgetStroke      = Color(uiColor: .separator)

    /// Primary icon tint — black in light, white in dark.
    static let widgetIconFg      = Color(uiColor: .label)

    /// Secondary text / icon tint — gray in both modes.
    static let widgetSecondaryFg = Color(uiColor: .secondaryLabel)
}

// MARK: - Static Timeline Provider

struct ActionEntry: TimelineEntry {
    let date: Date
}

struct StaticActionProvider: TimelineProvider {
    func placeholder(in context: Context) -> ActionEntry { ActionEntry(date: .now) }
    func getSnapshot(in context: Context, completion: @escaping (ActionEntry) -> Void) {
        completion(ActionEntry(date: .now))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<ActionEntry>) -> Void) {
        let next = Calendar.current.date(byAdding: .day, value: 1, to: .now) ?? .now
        completion(Timeline(entries: [ActionEntry(date: .now)], policy: .after(next)))
    }
}

// MARK: - ═══════════════════════════════════════════
// MARK:   WIDGET 1: Quick Actions (Small + Medium)
//         Single resizable widget — drag to resize
// MARK: ═══════════════════════════════════════════

struct QuickActionsWidget: Widget {
    let kind = "OpenUIQuickActions"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: StaticActionProvider()) { _ in
            QuickActionsWidgetView()
                .containerBackground(Color.widgetBg, for: .widget)
        }
        .configurationDisplayName("Open Relay")
        .description("Instantly start a chat, voice call, camera chat, or file chat.")
        .supportedFamilies([.systemSmall, .systemMedium])
        .contentMarginsDisabled()
    }
}

/// Entry view that switches layout based on the current widget family.
struct QuickActionsWidgetView: View {
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .systemMedium:
            QuickActionsMediumView()
                .background(Color.widgetBg)
        default:
            QuickActionsSmallView()
                .background(Color.widgetBg)
        }
    }
}

// MARK: - ═══════════════════════════════════════════
// MARK:   Small layout: 2×2 full-bleed grid
// MARK: ═══════════════════════════════════════════

struct QuickActionsSmallView: View {
    private let gap: CGFloat = 5
    private let inset: CGFloat = 8

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let circleW = (w - inset * 2 - gap) / 2
            let circleH = (h - inset * 2 - gap) / 2
            let size = min(circleW, circleH)

            VStack(spacing: gap) {
                HStack(spacing: gap) {
                    // App icon (new chat)
                    Link(destination: OpenUIURL.newChat) {
                        ZStack {
                            Circle().fill(Color.widgetCircleFill)
                            Image("AppIconImage")
                                .resizable()
                                .scaledToFill()
                                .frame(width: size * 0.55, height: size * 0.55)
                                .clipShape(RoundedRectangle(cornerRadius: size * 0.12, style: .continuous))
                        }
                        .frame(width: size, height: size)
                    }
                    // Mic (voice call)
                    Link(destination: OpenUIURL.voiceCall) {
                        ZStack {
                            Circle().fill(Color.widgetCircleFill)
                            Image(systemName: "mic.fill")
                                .font(.system(size: size * 0.34, weight: .bold))
                                .foregroundStyle(Color.widgetIconFg)
                        }
                        .frame(width: size, height: size)
                    }
                }
                HStack(spacing: gap) {
                    // Camera
                    Link(destination: OpenUIURL.cameraChat) {
                        ZStack {
                            Circle().fill(Color.widgetCircleFill)
                            Image(systemName: "camera.fill")
                                .font(.system(size: size * 0.34, weight: .bold))
                                .foregroundStyle(Color.widgetIconFg)
                        }
                        .frame(width: size, height: size)
                    }
                    // Files
                    Link(destination: OpenUIURL.fileChat) {
                        ZStack {
                            Circle().fill(Color.widgetCircleFill)
                            Image(systemName: "paperclip")
                                .font(.system(size: size * 0.34, weight: .bold))
                                .foregroundStyle(Color.widgetIconFg)
                        }
                        .frame(width: size, height: size)
                    }
                }
            }
            .frame(width: w, height: h)
        }
    }
}

// MARK: - ═══════════════════════════════════════════
// MARK:   Medium layout: Search bar + action row
// MARK: ═══════════════════════════════════════════

struct QuickActionsMediumView: View {
    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 10) {
                // ── "Ask Open UI" pill ──
                MediumSearchBar(width: geo.size.width - 20)

                // ── Action buttons: Camera · Photos · Channel · Files ──
                HStack(spacing: 0) {
                    MediumActionButton(systemName: "camera.fill",  label: "Camera",  url: OpenUIURL.cameraChat)
                    MediumActionButton(systemName: "photo.fill",   label: "Photos",  url: OpenUIURL.photosChat)
                    MediumActionButton(systemName: "number",       label: "Channel", url: OpenUIURL.newChannel)
                    MediumActionButton(systemName: "paperclip",    label: "Files",   url: OpenUIURL.fileChat)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }
}

/// Search bar pill with two independent Link zones.
private struct MediumSearchBar: View {
    let width: CGFloat

    var body: some View {
        ZStack(alignment: .trailing) {
            // Primary: entire bar → new chat
            Link(destination: OpenUIURL.newChat) {
                HStack(spacing: 10) {
                    Image("AppIconImage")
                        .resizable()
                        .scaledToFill()
                        .frame(width: 28, height: 28)
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

                    Text("Ask Open Relay")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.widgetSecondaryFg)

                    Spacer()
                }
                .padding(.leading, 14)
                .padding(.trailing, 50)
                .padding(.vertical, 11)
            }

            // Mic overlay → voice call
            Link(destination: OpenUIURL.voiceCall) {
                Image(systemName: "mic.fill")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Color.widgetSecondaryFg)
                    .frame(width: 48, height: 48)
                    .contentShape(Rectangle())
            }
            .padding(.trailing, 4)
        }
        .frame(width: width)
        .background(
            Capsule().fill(Color.widgetPillFill)
        )
        .overlay(
            Capsule()
                .strokeBorder(Color.widgetStroke, lineWidth: 0.75)
        )
    }
}

private struct MediumActionButton: View {
    let systemName: String
    let label: String
    let url: URL

    var body: some View {
        Link(destination: url) {
            VStack(spacing: 6) {
                ZStack {
                    Circle()
                        .fill(Color.widgetPillFill)
                        .frame(width: 48, height: 48)
                    Image(systemName: systemName)
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(Color.widgetIconFg)
                }
                Text(label)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.widgetSecondaryFg)
            }
            .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - ═══════════════════════════════════════════
// MARK:   WIDGET 2: Lock Screen Accessories
// MARK: ═══════════════════════════════════════════

struct LockScreenWidget: Widget {
    let kind = "OpenUILockScreen"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: StaticActionProvider()) { _ in
            LockScreenWidgetView()
                .containerBackground(.clear, for: .widget)
        }
        .configurationDisplayName("Open Relay")
        .description("Quick access to Open Relay from your lock screen.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

struct LockScreenWidgetView: View {
    @Environment(\.widgetFamily) var family

    var body: some View {
        switch family {
        case .accessoryCircular:
            Link(destination: OpenUIURL.newChat) {
                ZStack {
                    AccessoryWidgetBackground()
                    Image(systemName: "bubble.left.and.text.bubble.right.fill")
                        .font(.system(size: 18, weight: .medium))
                }
            }
        case .accessoryRectangular:
            Link(destination: OpenUIURL.newChat) {
                HStack(spacing: 8) {
                    Image(systemName: "bubble.left.and.text.bubble.right.fill")
                        .font(.system(size: 14, weight: .semibold))
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Open Relay")
                            .font(.system(size: 13, weight: .semibold))
                        Text("Ask anything")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            }
        case .accessoryInline:
            Link(destination: OpenUIURL.newChat) {
                Label("Ask Open Relay", systemImage: "bubble.left.and.text.bubble.right.fill")
            }
        default:
            Link(destination: OpenUIURL.newChat) {
                Image(systemName: "bubble.left.and.text.bubble.right.fill")
            }
        }
    }
}
