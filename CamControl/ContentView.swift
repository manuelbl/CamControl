//
//  ContentView.swift
//
//  The main window shell: 16:9 live preview, camera picker row, the
//  grouped control sections, and the footer.
//

import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @State private var showingResetAlert = false
    /// Bottom edge of the camera picker row in window coordinates; the empty state starts below it.
    @State private var pickerRowBottom: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            previewArea
            Form {
                Section {
                    LabeledContent("Camera") { cameraPicker }
                        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxY } action: {
                            pickerRowBottom = $0
                        }
                }
                if model.showsControls {
                    ControlSectionsView(model: model)
                }
            }
            .formStyle(.grouped)
            // The camera picker stays in its native Form card; the empty state floats centered in
            // the region below it (non-interactive, so the picker stays live).
            .overlay { emptyStateView }
            Divider()
            footer
        }
        // Width is locked and the height bounded/persisted at the AppKit level; the accessor
        // owns those constraints so nothing here fights the user's resize or the saved frame.
        .frame(minWidth: WindowMetrics.width, minHeight: WindowMetrics.minHeight)
        .background(WindowAccessor())
        .task {
            await model.requestCameraAccessIfNeeded()
        }
        .onAppear {
            model.setPreviewActive(scenePhase == .active)
            DockPresence.mainWindowVisible(true)
        }
        .onDisappear {
            model.setPreviewActive(false)
            DockPresence.mainWindowVisible(false)
        }
        .onChange(of: scenePhase) { _, phase in
            model.setPreviewActive(phase == .active)
        }
        // A newly plugged camera can steal the selection while the Reset confirmation is
        // up; dismiss it so a confirmed reset can't land on a different camera than named.
        .onChange(of: model.selectedCameraID) {
            showingResetAlert = false
        }
    }

    // MARK: - Preview

    private var previewArea: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9).fill(Color(white: 0.05))
            previewContent
        }
        // Explicit 16:9 height (532pt content width × 9/16) — the surrounding Form is now
        // the fixed-size element, so the preview can no longer be the flexible one.
        .frame(maxWidth: .infinity)
        .frame(height: 299)
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .padding([.top, .horizontal], 14)
    }

    @ViewBuilder
    private var previewContent: some View {
        if model.selectedCamera == nil {
            placeholder(icon: "video.slash",
                        title: "No Camera Connected",
                        subtitle: "Connect a USB camera to begin")
        } else if model.cameraAccess == .denied {
            placeholder(icon: "lock.fill",
                        title: "Camera Access Needed",
                        subtitle: "Allow camera access in System Settings to see the preview") {
                Button("Open Privacy & Security") { openURL(Self.cameraPrivacySettingsURL) }
                    .padding(.top, 4)
            }
        } else if model.cameraAccess == .restricted {
            // Blocked by MDM or parental controls: nothing the user can change, so no link.
            placeholder(icon: "lock.fill",
                        title: "Camera Access Restricted",
                        subtitle: "Camera access is restricted on this Mac")
        } else if model.cameraAccess == .authorized {
            CameraPreview(session: model.preview.session)
        }
        // .notDetermined → black while the access prompt is in flight
    }

    /// System Settings › Privacy & Security › Camera, where the user can grant access.
    private static let cameraPrivacySettingsURL =
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!

    private func placeholder(
        icon: String, title: LocalizedStringKey, subtitle: LocalizedStringKey,
        @ViewBuilder action: () -> some View = { EmptyView() }
    ) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.white.opacity(0.35))
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
            Text(subtitle)
                .font(.system(size: 11.5))
                .foregroundStyle(.white.opacity(0.45))
            action()
        }
        // The preview area is always dark, so render its controls in dark appearance.
        .environment(\.colorScheme, .dark)
        .padding()
        .multilineTextAlignment(.center)
    }

    // MARK: - Camera row

    private var cameraPicker: some View {
        Picker("", selection: selectionBinding) {
            if model.cameras.isEmpty {
                Text("No camera").tag(String?.none)
            }
            ForEach(model.cameras) { camera in
                Text(camera.name).tag(String?.some(camera.id))
            }
        }
        .labelsHidden()
        .fixedSize()
        .disabled(model.cameras.isEmpty)
    }

    private var selectionBinding: Binding<String?> {
        Binding(
            get: { model.selectedCameraID },
            set: { model.selectedCameraID = $0 })
    }

    // MARK: - Empty state (no adjustable settings)

    @ViewBuilder
    private var emptyStateView: some View {
        if let empty = model.emptyState {
            // A grouped Form has no reliable intrinsic height, so the picker row's measured
            // bottom edge marks where the free region below the card begins.
            GeometryReader { geo in
                VStack(spacing: 0) {
                    Color.clear
                        .frame(height: max(0, pickerRowBottom - geo.frame(in: .global).minY))
                    ContentUnavailableView {
                        Label { Text(empty.title) } icon: { Image(systemName: empty.systemImage) }
                    } description: {
                        Text(empty.description)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .scrollIndicators(.never)
                    .scrollDisabled(true)
                }
            }
            .allowsHitTesting(false)
        }
    }

    // MARK: - Footer (persistence: reapply toggle + reset)

    private var footer: some View {
        HStack(spacing: 10) {
            Toggle("Reapply on connect", isOn: reapplyBinding).toggleStyle(.checkbox)
                .disabled(!model.showsControls)
            Spacer()
            Button("Reset to Defaults") { showingResetAlert = true }
                .disabled(!model.showsControls)
        }
        .padding(14)
        .alert("Reset \(model.selectedCamera?.name ?? "camera") to defaults?",
               isPresented: $showingResetAlert) {
            Button("Reset", role: .destructive) { model.resetToDefaults() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This resets all settings to the camera’s built-in defaults. This can’t be undone.")
        }
    }

    private var reapplyBinding: Binding<Bool> {
        Binding(
            get: { model.reapplyOnConnect },
            set: { model.setReapply($0) })
    }
}

#if DEBUG
#Preview("Controllable camera") {
    ContentView()
        .environment(AppModel.preview())
}

#Preview("Uncontrollable (built-in)") {
    ContentView()
        .environment(AppModel.preview(
            selected: PreviewFixtures.builtInCamera.id,
            controls: PreviewFixtures.unsupportedControls))
}

#Preview("Controllable, no controls") {
    ContentView()
        .environment(AppModel.preview(controls: PreviewFixtures.unsupportedControls))
}

#Preview("Partial support") {
    ContentView()
        .environment(AppModel.preview(controls: PreviewFixtures.partialControls))
}

#Preview("No camera") {
    ContentView()
        .environment(AppModel.preview(cameras: [], selected: nil, controls: []))
}

#Preview("Access denied") {
    ContentView()
        .environment(AppModel.preview(access: .denied))
}

#Preview("Access restricted") {
    ContentView()
        .environment(AppModel.preview(access: .restricted))
}
#endif
