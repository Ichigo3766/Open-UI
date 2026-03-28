//
//  OpenUIWidgets.swift
//  OpenUIWidgets
//
//  Open UI widget suite — action-focused, instant-launch widgets.
//  Modern adaptive design: supports Default, Dark, Clear, and Tinted modes.
//  Uses SwiftUI system materials and widgetRenderingMode for full theme support.
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

// MARK: - Static Timeline Provider

struct ActionEntry: TimelineEntry {
    let date: Date
}

struct StaticActionProvider: TimelineProvider {
    func placeholder(in context: Context) -> ActionEntry { ActionEntry(date: .now) }

    func getSnapshot(in context: Context, completion: @escaping @Sendable (ActionEntry) -> Void) {
        completion(ActionEntry(date: .now))
    }

    func getTimeline(in context: Context, completion: @escaping @Sendable (Timeline<ActionEntry>) -> Void) {
        let next = Calendar.current.date(byAdding: .day, value: 1, to: .now) ?? .now
        completion(Timeline(entries: [ActionEntry(date: .now)], policy: .after(next)))
    }
}

// MARK: - ═══════════════════════════════════════════
// MARK:   WIDGET 1: Quick Actions (Small + Medium)
// MARK: ═══════════════════════════════════════════

struct QuickActionsWidget: Widget {
    let kind = "OpenUIQuickActions"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: StaticActionProvider()) { _ in
            QuickActionsWidgetView()
                .containerBackground(.fill.tertiary, for: .widget)
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
        default:
            QuickActionsSmallView()
        }
    }
}

// MARK: - ═══════════════════════════════════════════
// MARK:   Small layout: 2×2 full-bleed grid
// MARK: ═══════════════════════════════════════════

struct QuickActionsSmallView: View {
    @Environment(\.widgetRenderingMode) private var renderingMode
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
                        SmallCircleButton(size: size) {
                            Image("AppIconImage")
                                .resizable()
                                .widgetAccentedRenderingMode(.fullColor)
                                .scaledToFill()
                                .frame(width: size * 0.55, height: size * 0.55)
                                .clipShape(RoundedRectangle(cornerRadius: size * 0.12, style: .continuous))
                        }
                    }
                    // Mic (voice call)
                    Link(destination: OpenUIURL.voiceCall) {
                        SmallCircleButton(size: size) {
                            Image(systemName: "mic.fill")
                                .font(.system(size: size * 0.34, weight: .bold))
                                .foregroundStyle(.primary)
                                .widgetAccentable()
                        }
                    }
                }
                HStack(spacing: gap) {
                    // Camera
                    Link(destination: OpenUIURL.cameraChat) {
                        SmallCircleButton(size: size) {
                            Image(systemName: "camera.fill")
                                .font(.system(size: size * 0.34, weight: .bold))
                                .foregroundStyle(.primary)
                                .widgetAccentable()
                        }
                    }
                    // Files
                    Link(destination: OpenUIURL.fileChat) {
                        SmallCircleButton(size: size) {
                            Image(systemName: "paperclip")
                                .font(.system(size: size * 0.34, weight: .bold))
                                .foregroundStyle(.primary)
                                .widgetAccentable()
                        }
                    }
                }
            }
            .frame(width: w, height: h)
        }
    }
}

/// A circle button that adapts its fill based on widget rendering mode.
private struct SmallCircleButton<Content: View>: View {
    let size: CGFloat
    @ViewBuilder let content: Content
    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        ZStack {
            adaptiveCircle
            content
        }
        .frame(width: size, height: size)
    }

    @ViewBuilder
    private var adaptiveCircle: some View {
        if renderingMode == .vibrant {
            Circle().fill(.fill.tertiary)
        } else if renderingMode == .accented {
            Circle().fill(.fill.tertiary).widgetAccentable()
        } else {
            Circle().fill(.fill.quaternary)
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
                // ── "Ask Open Relay" pill ──
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
    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        ZStack(alignment: .trailing) {
            // Primary: entire bar → new chat
            Link(destination: OpenUIURL.newChat) {
                HStack(spacing: 10) {
                    Image("AppIconImage")
                        .resizable()
                        .widgetAccentedRenderingMode(.fullColor)
                        .scaledToFill()
                        .frame(width: 28, height: 28)
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

                    Text("Ask Open Relay")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.secondary)

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
                    .foregroundStyle(.secondary)
                    .widgetAccentable()
                    .frame(width: 48, height: 48)
                    .contentShape(Rectangle())
            }
            .padding(.trailing, 4)
        }
        .frame(width: width)
        .background(
            Capsule().fill(searchBarFill)
        )
        .overlay(
            Capsule()
                .strokeBorder(searchBarStroke, lineWidth: 0.75)
        )
    }

    private var searchBarFill: some ShapeStyle {
        .fill.tertiary
    }

    private var searchBarStroke: some ShapeStyle {
        .fill.secondary
    }
}

private struct MediumActionButton: View {
    let systemName: String
    let label: String
    let url: URL
    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        Link(destination: url) {
            VStack(spacing: 6) {
                ZStack {
                    circleFill
                        .frame(width: 48, height: 48)
                    Image(systemName: systemName)
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(.primary)
                        .widgetAccentable()
                }
                Text(label)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private var circleFill: some View {
        if renderingMode == .vibrant {
            Circle().fill(.fill.tertiary)
        } else if renderingMode == .accented {
            Circle().fill(.fill.tertiary).widgetAccentable()
        } else {
            Circle().fill(.fill.quaternary)
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
                        .widgetAccentable()
                }
            }
        case .accessoryRectangular:
            Link(destination: OpenUIURL.newChat) {
                HStack(spacing: 8) {
                    Image(systemName: "bubble.left.and.text.bubble.right.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .widgetAccentable()
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
                    .widgetAccentable()
            }
        }
    }
}
