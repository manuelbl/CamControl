//
//  SettingsView.swift
//  The Settings scene (Cmd+, / menu bar → Settings…): a Launch-at-Login toggle over
//  `SMAppService`. Off by default — the user opts in, per HIG guidance against silently
//  adding login items.
//

import AppKit
import ServiceManagement
import SwiftUI
import os

private let log = Logger(subsystem: "net.codecrete.CamControl", category: "Settings")

struct SettingsView: View {
    /// The login item's status as last read from `SMAppService`. The system doesn't push
    /// changes, so it is re-read on appear and whenever the app becomes active (e.g. on
    /// returning from System Settings › Login Items).
    @State private var status: SMAppService.Status

    init(status: SMAppService.Status = SMAppService.mainApp.status) {
        _status = State(initialValue: status)
    }

    var body: some View {
        Form {
            Section {
                Toggle(isOn: launchAtLoginBinding) {
                    Text("Launch at login")
                    Text("To automatically re-apply saved settings to connected cameras, this application must be running. Launch it when you log in so that it runs in the background.")
                }
                if status == .requiresApproval {
                    HStack {
                        Label {
                            Text("Needs your approval in System Settings › Login Items.")
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                        }
                        Spacer()
                        Button("Open Login Items") {
                            SMAppService.openSystemSettingsLoginItems()
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 380)
        .fixedSize()
        .onAppear(perform: refreshStatus)
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshStatus()
        }
    }

    /// On while registered — approved (`.enabled`) or awaiting the user's approval
    /// (`.requiresApproval`, explained by the row below the toggle). Flipping registers or
    /// unregisters immediately, then reads back the actual status; a thrown error is logged
    /// and leaves the toggle on whatever the system reports.
    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { status == .enabled || status == .requiresApproval },
            set: { on in
                do {
                    if on {
                        try SMAppService.mainApp.register()
                    } else {
                        try SMAppService.mainApp.unregister()
                    }
                } catch {
                    log.error("launch-at-login \(on ? "register" : "unregister", privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                }
                refreshStatus()
            })
    }

    private func refreshStatus() {
        guard !ProcessInfo.isRunningForPreviews else { return }
        status = SMAppService.mainApp.status
        if status == .notFound {
            log.notice("launch-at-login status: login item not found")
        }
    }
}

#if DEBUG
#Preview("Off") {
    SettingsView(status: .notRegistered)
}

#Preview("Requires approval") {
    SettingsView(status: .requiresApproval)
}
#endif
