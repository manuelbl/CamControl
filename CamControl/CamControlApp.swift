//
//  CamControlApp.swift
//
//  App entry point. Owns the app-scoped collaborators: the one shared ProfileStore and
//  the window-independent ReapplyService, wired to the AppModel so a background reapply
//  refreshes the camera on screen.
//

import AppKit
import SwiftUI

@main
struct CamControlApp: App {
    @State private var model: AppModel
    /// Kept alive for the app's lifetime — reapply-on-connect must run with no window
    /// open (menu-bar accessory mode). Nil only in the SwiftUI preview host.
    @State private var reapplyService: ReapplyService?

    init() {
        if ProcessInfo.isRunningForPreviews {
            _model = State(initialValue: AppModel(isPreview: true))
            _reapplyService = State(initialValue: nil)
            return
        }
        USBCameraService.shared.start()
        let store = ProfileStore()
        let model = AppModel(store: store)
        let service = ReapplyService(store: store)
        service.onReapplied = { key in model.reapplyDidApply(to: key) }
        service.start()
        model.start()
        // Save an edit still waiting for its settle read-back before the process exits.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { model.flushPendingSave() }
        }
        _model = State(initialValue: model)
        _reapplyService = State(initialValue: service)
    }

    var body: some Scene {
        Window("CamControl", id: "main") {
            ContentView()
                .environment(model)
        }
        // Let the user resize vertically; the real width lock + height floor live on the NSWindow
        // (WindowAccessor). `.contentMinSize` keeps SwiftUI from forcing a content-driven size.
        .windowResizability(.contentMinSize)

        // Always visible — the app's stable home, and the only handle on it while the main
        // window is closed and the app is a Dock-less accessory.
        MenuBarExtra("CamControl", image: "StatusIcon") {
            MenuBarMenu()
        }

        Settings {
            SettingsView()
        }
    }
}

/// The status-item dropdown. Open/About/Settings also activate the app: in accessory mode a
/// window opened from the menu bar would otherwise appear behind the frontmost app.
private struct MenuBarMenu: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button("Open CamControl") {
            openWindow(id: "main")
            NSApp.activate()
        }
        // The standard panel picks up the copyright from Info.plist and the link from Credits.rtf.
        Button("About CamControl") {
            NSApp.orderFrontStandardAboutPanel()
            NSApp.activate()
        }
        Button("Settings…") {
            openSettings()
            NSApp.activate()
        }
        Divider()
        Button("Quit CamControl") {
            NSApp.terminate(nil)
        }
    }
}

extension ProcessInfo {
    /// True only inside Xcode's SwiftUI preview host — not in a normal debug run.
    static var isRunningForPreviews: Bool {
        processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
    }
}
