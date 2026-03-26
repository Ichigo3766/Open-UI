//
//  OpenUIWidgetsBundle.swift
//  OpenUIWidgets
//

import WidgetKit
import SwiftUI

@main
struct OpenUIWidgetsBundle: WidgetBundle {
    var body: some Widget {
        // Home screen widget — single resizable widget (drag to switch small ↔ medium)
        QuickActionsWidget()

        // Lock screen accessories
        LockScreenWidget()          // accessoryCircular / accessoryRectangular / accessoryInline

        // Control Center (iOS 18+)
        OpenUIWidgetsControl()
    }
}
