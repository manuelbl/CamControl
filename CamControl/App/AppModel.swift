//
//  AppModel.swift
//  The app's single source of observable truth for the main window.
//
//  Holds the camera list, the current selection, and the selected camera's editable
//  control state. Edits update the UI optimistically and stream to `USBCameraService`
//  (coalesced, FIFO-ordered); 500ms after interaction stops, a settle read-back pulls the
//  camera's actual values back in. Switching or reconnecting a camera re-seeds from a
//  fresh discovery. A camera has a saved profile exactly while "reapply on connect" is on;
//  then every settle read-back (and every reset) autosaves the current values to the
//  app-scoped `ProfileStore`. Applying a snapshot to hardware is `ReapplyService`'s job;
//  this model only refreshes its values when told a reapply landed on the visible camera.
//

import SwiftUI
import AVFoundation
import os

private let log = Logger(subsystem: "net.codecrete.CamControl", category: "AppModel")

/// The "nothing to adjust here" empty state shown in place of the control sections.
/// Title and icon are fixed; only the one-line reason differs (not-USB vs. USB-but-empty).
struct EmptyState {
    var title: LocalizedStringResource { "No Adjustable Settings" }
    var systemImage: String { "slider.horizontal.3" }
    let description: LocalizedStringResource
}

/// One rendered row of a control section.
enum ControlRow: Identifiable {
    /// A control with its own widget (slider, toggle or segmented).
    case single(ControlID)
    /// An Auto checkbox plus the slider it governs.
    case autoPair(AutoPair)

    var id: ControlID {
        switch self {
        case .single(let id): id
        case .autoPair(let pair): pair.manualID
        }
    }
}

@MainActor
@Observable
final class AppModel {
    // MARK: - Observable state

    private(set) var cameras: [Camera] = []
    var selectedCameraID: String? {
        didSet { if oldValue != selectedCameraID { onSelectionChanged() } }
    }
    /// Selected camera's controls, keyed by id. Empty until the first discovery completes.
    private(set) var controls: [ControlID: ControlUIState] = [:]
    private(set) var isLoadingControls = false
    private(set) var cameraAccess: AVAuthorizationStatus =
        AVCaptureDevice.authorizationStatus(for: .video)
    /// The selected camera's "reapply on connect" flag; the footer toggle binds here via
    /// `setReapply`. True ⇔ the camera has a saved profile (false when nothing is selected).
    private(set) var reapplyOnConnect = false

    // MARK: - Collaborators

    let preview = PreviewSession()
    private let catalog = CameraCatalog()
    /// The app-scoped profile store, shared with `ReapplyService` (injected by the App —
    /// it caches in memory, so there must be exactly one). Nil in previews (no disk I/O).
    private let store: ProfileStore?

    /// True for models built by `AppModel.preview(...)` for the SwiftUI canvas: their
    /// state is seeded by hand and all service-starting side effects are suppressed so
    /// the preview never touches USB, AVFoundation discovery, or the TCC access prompt.
    let isPreview: Bool

    init(isPreview: Bool = false, store: ProfileStore? = nil) {
        self.isPreview = isPreview
        self.store = store
    }

    /// True while the window is visible and the app active — gates the capture session.
    private var previewActive = false
    /// Session IDs from the previous camera-list publish; nil until the first publish
    /// seeds the baseline, so cameras already attached at launch don't count as "new".
    private var knownCameraIDs: Set<String>?
    /// Serializes control discovery so a fast camera switch can't interleave two loads.
    private var loadTask: Task<Void, Never>?
    /// USB identity of the current selection; nil while nothing controllable is selected.
    /// All hardware traffic goes to `USBCameraService` under this key — the model holds no
    /// device handle, so nothing it does can close a device another user is on (ADR-0004).
    private var activeCamera: CameraKey?
    /// Debounced read-back armed on each edit; fires 500ms after interaction quiesces.
    /// Non-nil ⇔ an edit is waiting for its settle (and thus its autosave).
    private var settleTask: Task<Void, Never>?
    /// Persistence key of the current selection (`vendor-product-serial`), resolved after
    /// pairing. Nil until discovery pairs a controllable camera — gates autosave/Reset/Reapply.
    private var activeKey: String?
    /// Persistence key of a background reapply that landed while that camera's discovery
    /// was still in flight; `loadControls` settles the debt with a value refresh.
    private var pendingReapplyRefreshKey: String?

    // MARK: - Derived

    var selectedCamera: Camera? {
        guard let id = selectedCameraID else { return nil }
        return cameras.first { $0.id == id }
    }

    var isEmpty: Bool { selectedCamera == nil }

    func state(_ id: ControlID) -> ControlUIState? { controls[id] }

    // MARK: - Derived: which rows render

    /// The rows of a group, in catalog display order. Only supported controls render;
    /// unsupported ones are omitted entirely. An auto pair renders as one row at its
    /// manual entry's position, iff the *manual* control is supported (manual-only or
    /// both); an Auto-only pair collapses to nothing — a lone Auto checkbox controls
    /// nothing observable.
    func renderableRows(in group: ControlGroup) -> [ControlRow] {
        ControlCatalog.all
            .filter { $0.group == group && (controls[$0.id]?.supported ?? false) }
            .compactMap { descriptor -> ControlRow? in
                guard let pair = ControlCatalog.autoPair(containing: descriptor.id) else {
                    return .single(descriptor.id)
                }
                return descriptor.id == pair.manualID ? .autoPair(pair) : nil
            }
    }

    /// Total rendered rows across all sections — the trigger for the empty state.
    private var totalRenderableRows: Int {
        let groups: [ControlGroup] = [.exposureColor, .image, .framing]
        return groups.reduce(0) { $0 + renderableRows(in: $1).count }
    }

    /// True when at least one control row renders — drives showing the Form sections.
    var showsControls: Bool { totalRenderableRows > 0 }

    // MARK: - Derived: persistence

    /// The values a save persists: every currently-supported control's current value,
    /// keyed by id. An auto pair contributes both its Auto and manual value.
    private func currentSnapshot() -> [ControlID: Int64] {
        var snapshot: [ControlID: Int64] = [:]
        for (id, state) in controls where state.supported { snapshot[id] = state.value }
        return snapshot
    }

    /// The empty-state to render in place of the control sections, or `nil` when controls
    /// render *or* the region should stay blank (no selection / discovery in flight).
    /// `!isControllable` resolves instantly; "controllable but zero rows" only after
    /// discovery completes, so a controllable camera never flashes the callout mid-load.
    var emptyState: EmptyState? {
        guard let cam = selectedCamera else { return nil }          // no selection → blank
        if !cam.isControllable {
            return EmptyState(description:
                "This camera’s settings can’t be adjusted by CamControl. Only cameras connected via USB can be controlled.")
        }
        guard !isLoadingControls else { return nil }                // discovering → blank
        return totalRenderableRows == 0
            ? EmptyState(description:
                "This camera doesn’t expose any settings that CamControl can adjust.")
            : nil
    }

    // MARK: - Lifecycle

    /// Starts camera observation. Called once at app launch so plug-ins are tracked
    /// even while the main window is closed.
    func start() {
        guard !isPreview else { return }
        catalog.onChange = { [weak self] cameras in
            self?.applyCameraList(cameras)
        }
        catalog.start()
    }

    private func applyCameraList(_ newCameras: [Camera]) {
        let previous = knownCameraIDs
        let previousCameras = cameras
        knownCameraIDs = Set(newCameras.map(\.id))
        cameras = newCameras
        // A newly plugged controllable camera steals the selection, whether the window is
        // open or closed — the physical act signals intent.
        if let previous,
           let plugged = newCameras.first(where: { $0.isControllable && !previous.contains($0.id) }) {
            selectedCameraID = plugged.id
            return
        }
        let selectionBefore = selectedCameraID
        reconcileSelection()
        // The selection stayed put but its controllability flipped: the USB device was
        // enumerated after AVFoundation announced the camera (or went away under it).
        // `onSelectionChanged` never fires for that, so re-run discovery here.
        guard selectedCameraID == selectionBefore, let id = selectedCameraID else { return }
        let was = previousCameras.first { $0.id == id }?.isControllable
        let now = newCameras.first { $0.id == id }?.isControllable
        if was != now { loadControls() }
    }

    /// Chooses/keeps a selection: keep the current one if still present, else first
    /// controllable, else first available, else none.
    private func reconcileSelection() {
        if let id = selectedCameraID, cameras.contains(where: { $0.id == id }) {
            return // still valid
        }
        selectedCameraID = cameras.first(where: \.isControllable)?.id ?? cameras.first?.id
    }

    private func onSelectionChanged() {
        guard !isPreview else { return }
        // Drop the outgoing camera: save its pending edit and cancel the read-back so a stale
        // result can't land on the new selection. `selectedCameraID` has already changed, but
        // `controls`/`activeKey` still belong to the outgoing camera. Writes already submitted
        // for it drain harmlessly in the service — the device stays open until it is
        // unplugged, whoever else is using it.
        flushPendingSave()
        activeCamera = nil
        controls = [:]
        // Drop the outgoing camera's persistence identity/flag so a half-loaded new
        // selection never shows a stale flag or autosaves under the wrong key.
        activeKey = nil
        reapplyOnConnect = false
        preview.setDevice(id: selectedCameraID)
        syncPreviewRunning()
        loadControls()
    }

    // MARK: - Control discovery (read-only seed)

    private func loadControls() {
        loadTask?.cancel()
        guard let camera = selectedCamera else { isLoadingControls = false; return }

        // Resolve the selection to a USB camera synchronously: if the USB
        // device isn't attached yet, the camera renders unsupported and the service's
        // availability change republishes the list, which comes back here (ADR-0004).
        let service = USBCameraService.shared
        guard let key = CameraKey(sessionID: camera.id), let info = service.info(for: key) else {
            activeCamera = nil
            controls = Dictionary(uniqueKeysWithValues:
                Self.allUnsupportedControls().map { ($0.id, $0) })
            isLoadingControls = false
            return
        }

        activeCamera = key
        isLoadingControls = true
        loadTask = Task { [weak self] in
            let snapshots = await service.discoverAll(key)
            guard let self, !Task.isCancelled, self.selectedCameraID == camera.id else { return }
            guard let snapshots else {
                // Unplugged while discovering: render all-unsupported and wait for the list
                // to republish.
                self.activeCamera = nil
                self.controls = Dictionary(uniqueKeysWithValues:
                    Self.allUnsupportedControls().map { ($0.id, $0) })
                self.isLoadingControls = false
                return
            }
            let seeded = snapshots.map(ControlUIState.init(from:))
            self.controls = Dictionary(uniqueKeysWithValues: seeded.map { ($0.id, $0) })
            self.activeKey = info.persistenceKey
            self.loadProfile(key: info.persistenceKey)
            self.isLoadingControls = false
            // A background reapply raced this discovery (typical when the selected camera
            // is replugged): the seed reads may predate the reapply writes, so re-read.
            if self.pendingReapplyRefreshKey == info.persistenceKey {
                self.pendingReapplyRefreshKey = nil
                self.refreshValuesFromDevice()
            }
        }
    }

    /// Loads the persisted reapply flag for `key` (drives the footer toggle). Does NOT apply
    /// the snapshot to the hardware — foreground stays on live reads; all reapply is
    /// `ReapplyService`'s job.
    private func loadProfile(key: String) {
        reapplyOnConnect = store?.profile(for: key)?.reapplyOnConnect ?? false
    }

    /// The fixed catalog rendered as all-unsupported — for an uncontrollable camera or one
    /// whose USB pairing fails.
    private static func allUnsupportedControls() -> [ControlUIState] {
        ControlCatalog.all.map {
            ControlUIState(from: ControlSnapshot(
                id: $0.id, state: ControlState(supported: false, value: 0), range: nil))
        }
    }

    // MARK: - Control mutation (optimistic UI + coalesced hardware write)

    /// Applies an edit: updates the UI value immediately (instant preview/feedback), streams
    /// the change to the hardware in FIFO order, and (re)arms the settle read-back so the
    /// camera's actual, possibly-clamped values flow back once the user stops interacting.
    func setValue(_ value: Int64, for id: ControlID) {
        controls[id]?.value = value
        if let key = activeCamera {
            USBCameraService.shared.submit(id, value: value, to: key)
        }
        scheduleSettleReadback()
    }

    /// Debounces a full value read-back to 500ms after the last edit. Interacting controls
    /// and hardware clamping mean the resting values can differ from what we wrote; reading
    /// only after quiescence guarantees we never clobber an in-progress drag. The settled
    /// values are then autosaved if reapply is on.
    private func scheduleSettleReadback() {
        settleTask?.cancel(); settleTask = nil
        guard let key = activeCamera else { return }
        let cameraID = selectedCameraID
        settleTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            let values = await USBCameraService.shared.readValues(key)
            guard let self, !Task.isCancelled, self.selectedCameraID == cameraID else { return }
            for (id, value) in values { self.controls[id]?.value = value }
            self.settleTask = nil
            self.saveIfReapplying()
        }
    }

    /// Saves an edit whose settle read-back hasn't run yet, using the in-memory values (there
    /// is no time left to read back). Called before the selection changes and when the app quits.
    func flushPendingSave() {
        guard settleTask != nil else { return }
        settleTask?.cancel(); settleTask = nil
        saveIfReapplying()
    }

    // MARK: - Background reapply coordination

    /// Called (via the App) after `ReapplyService` lands a saved snapshot on camera `key`.
    /// If that camera is on screen, re-read its values — the read serializes after the
    /// reapply writes on the shared UVC queue, so the sliders land on the final values no
    /// matter how the two interleaved. If its discovery is still in flight (a replug of
    /// the selected camera races discovery against reapply), park the key for
    /// `loadControls` to settle.
    func reapplyDidApply(to key: String) {
        if key == activeKey {
            refreshValuesFromDevice()
        } else {
            pendingReapplyRefreshKey = key
        }
    }

    /// Re-reads every supported control's value from the active device into the UI.
    private func refreshValuesFromDevice() {
        guard let key = activeCamera else { return }
        let cameraID = selectedCameraID
        Task { [weak self] in
            let values = await USBCameraService.shared.readValues(key)
            guard let self, self.selectedCameraID == cameraID else { return }
            for (id, value) in values { self.controls[id]?.value = value }
        }
    }

    // MARK: - Persistence (autosave / Reapply / Reset)

    /// Writes the current values as the camera's saved profile — only while reapply is on,
    /// since a profile exists exactly then.
    private func saveIfReapplying() {
        guard reapplyOnConnect, let store, let key = activeKey else { return }
        store.upsert(Profile(snapshot: currentSnapshot(), reapplyOnConnect: true), for: key)
    }

    /// Toggles "reapply on connect", persisting immediately: ON saves the current values as
    /// the profile; OFF deletes the profile.
    func setReapply(_ on: Bool) {
        reapplyOnConnect = on
        guard let store, let key = activeKey else { return }
        if on {
            saveIfReapplying()
        } else {
            store.delete(for: key)
        }
    }

    /// Resets the live camera to its built-in defaults. Sliders snap to the *actual*
    /// post-reset readings (the camera may clamp), so the UI is re-seeded from a read-back;
    /// with reapply on, those defaults become the saved profile. Call behind a confirmation
    /// alert (it overwrites persisted data).
    func resetToDefaults() {
        guard let camera = activeCamera, activeKey != nil else { return }
        // A pending settle read-back would clobber the reset values — cancel it first.
        settleTask?.cancel(); settleTask = nil
        let cameraID = selectedCameraID
        // Supported controls in catalog order (each Auto before its manual value), so auto
        // pairs reset in dependency order.
        let ordered = ControlCatalog.all.map(\.id)
            .filter { controls[$0]?.supported ?? false }
        Task { [weak self] in
            let service = USBCameraService.shared
            for id in ordered { await service.reset(id, on: camera) }
            let values = await service.readValues(camera)
            guard let self, self.selectedCameraID == cameraID else { return }
            for (id, value) in values { self.controls[id]?.value = value }
            self.saveIfReapplying()
        }
    }

    // MARK: - Preview session gating

    /// Called from the view lifecycle: the preview runs only while active *and* a camera
    /// is selected with camera access granted.
    func setPreviewActive(_ active: Bool) {
        previewActive = active
        syncPreviewRunning()
    }

    private func syncPreviewRunning() {
        guard !isPreview else { return }
        if previewActive, selectedCamera != nil, cameraAccess == .authorized {
            preview.start()
        } else {
            preview.stop()
        }
    }

    /// Requests camera (TCC) access on first preview; updates `cameraAccess` and starts
    /// the session if it was granted.
    func requestCameraAccessIfNeeded() async {
        guard !isPreview else { return }
        guard cameraAccess == .notDetermined else { return }
        let granted = await AVCaptureDevice.requestAccess(for: .video)
        cameraAccess = granted ? .authorized : .denied
        log.notice("camera access: \(granted ? "granted" : "denied", privacy: .public)")
        syncPreviewRunning()
    }
}

#if DEBUG
extension AppModel {
    /// Builds a fully-seeded model for the SwiftUI canvas with no services running.
    /// Every facet the UI branches on — the camera list, the selection, TCC access, and
    /// the per-control fixtures — is injectable so a `#Preview` can pin any one state.
    /// Lives in this file so it can seed the model's `private(set)` state directly.
    static func preview(
        cameras: [Camera] = PreviewFixtures.cameras,
        selected: String? = PreviewFixtures.cameras.first?.id,
        access: AVAuthorizationStatus = .authorized,
        controls: [ControlUIState] = PreviewFixtures.supportedControls
    ) -> AppModel {
        let model = AppModel(isPreview: true)
        model.cameras = cameras
        model.cameraAccess = access
        model.selectedCameraID = selected
        model.controls = Dictionary(uniqueKeysWithValues: controls.map { ($0.id, $0) })
        return model
    }
}
#endif
