//
//  WindowChrome.swift
//  Window sizing chrome for the main window. SwiftUI has no modifier that locks a window's
//  width while leaving the height user-resizable, so we reach the backing `NSWindow` once and
//  configure it at the AppKit level: width pinned to 560, height resizable within a floor, and
//  a frame-autosave name so macOS remembers the size + position across launches. On first run
//  (no autosaved frame yet) we open at a screen-clamped default height.
//

import SwiftUI
import AppKit

enum WindowMetrics {
    /// The one fixed dimension: the System Settings-style content width.
    static let width: CGFloat = 560
    /// Floor the user can shrink the window to (keeps preview + picker + footer usable).
    static let minHeight: CGFloat = 540
    /// Preferred opening height, before the screen clamp.
    static let preferredHeight: CGFloat = 760

    /// Default height used on first launch only: the preferred height, clamped so the whole
    /// window fits within the main screen's usable area (menu bar + Dock already excluded from
    /// `visibleFrame`), leaving a small margin. Computed once at first access.
    static let defaultHeight: CGFloat = {
        let usable = NSScreen.main?.visibleFrame.height ?? preferredHeight
        return min(preferredHeight, usable - 24)
    }()

    /// UserDefaults key AppKit writes the autosaved frame under (`"NSWindow Frame " + name`).
    static let autosaveName = "CamControlMain"
}

/// Dock presence follows the main window (spec: regular app while it's open, menu-bar
/// accessory once it's closed). Driven from the main content view's appear/disappear —
/// not `scenePhase`, which also fires on mere app deactivation — so only an actual window
/// close drops the Dock icon. The Settings window deliberately never changes the policy.
@MainActor
enum DockPresence {
    static func mainWindowVisible(_ visible: Bool) {
        guard !ProcessInfo.isRunningForPreviews else { return }
        NSApp.setActivationPolicy(visible ? .regular : .accessory)
        // Coming out of accessory mode (menu bar → Open) the fresh window isn't made key
        // on its own; activate to bring it to the front.
        if visible { NSApp.activate() }
    }
}

/// Configures the host `NSWindow` for the main window: locks the width, bounds the resizable
/// height, and enables frame autosave. Rendered as a zero-size `.background` view so it can
/// grab `view.window` after the view joins the window.
struct WindowAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        // The window isn't attached synchronously during make; defer to the next runloop turn.
        DispatchQueue.main.async { [weak view] in
            guard let window = view?.window else { return }
            Self.configure(window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private static func configure(_ window: NSWindow) {
        // Lock the width (min == max) while leaving height free between the floor and infinity.
        let w = WindowMetrics.width
        window.minSize = NSSize(width: w, height: WindowMetrics.minHeight)
        window.maxSize = NSSize(width: w, height: .greatestFiniteMagnitude)

        // Whether AppKit has a remembered frame decides if we apply the first-launch default.
        let hasSavedFrame =
            UserDefaults.standard.object(forKey: "NSWindow Frame \(WindowMetrics.autosaveName)") != nil
        window.setFrameAutosaveName(WindowMetrics.autosaveName)

        if !hasSavedFrame {
            var frame = window.frame
            frame.size.width = w
            // Preserve the top edge while changing height, so the window grows/shrinks downward.
            let top = frame.maxY
            frame.size.height = WindowMetrics.defaultHeight
            frame.origin.y = top - frame.size.height
            window.setFrame(frame, display: true)
            window.center()
        } else {
            // Restored frame may predate the width lock; snap the width back to 560.
            if window.frame.width != w {
                var frame = window.frame
                frame.size.width = w
                window.setFrame(frame, display: true)
            }
        }
    }
}
