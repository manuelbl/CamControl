//
//  ReapplyService.swift
//  Background reapply-on-connect: whenever a controllable camera appears, load its
//  profile and — if `reapplyOnConnect` is set — write the saved snapshot back to the
//  hardware. App-scoped and window-independent: it runs while the app is a menu-bar
//  accessory with no window, needing no `AVCaptureSession` (control writes are pure
//  USB traffic).
//
//  Connect detection comes from `USBCameraService`, i.e. from the USB registry itself
//  (ADR-0004): the camera is there to be written to at the instant we are told about
//  it, so there is no enumeration race to retry around. "Newly connected" is the diff
//  against the previously seen set. `known` starts empty, so the `start()` sweep treats
//  every already-attached camera as new — covering launch-at-login, where the camera
//  connected before the app was up and no notification will ever fire.
//

import os

private let log = Logger(subsystem: "net.codecrete.CamControl", category: "ReapplyService")

@MainActor
final class ReapplyService {
    /// Fired on the main actor after a snapshot lands, with the camera's persistence key
    /// (`vendor-product-serial`) — lets `AppModel` refresh a camera that is on screen.
    var onReapplied: ((String) -> Void)?

    private let store: ProfileStore
    /// USB identities seen attached; the diff basis for "new".
    private var known: Set<CameraKey> = []
    private var availabilityToken: USBCameraService.ObserverToken?

    init(store: ProfileStore) {
        self.store = store
    }

    /// Sweeps the already-attached cameras, then begins observing attach/detach.
    func start() {
        availabilityToken = USBCameraService.shared.addAvailabilityObserver { [weak self] in
            self?.handleAvailabilityChange()
        }
        handleAvailabilityChange()
    }

    func stop() {
        if let token = availabilityToken {
            USBCameraService.shared.removeAvailabilityObserver(token)
            availabilityToken = nil
        }
    }

    /// Diffs the attached cameras against `known`: each newly-attached one gets a reapply
    /// attempt. Detaches only shrink `known`, so a replug counts as new again.
    private func handleAvailabilityChange() {
        let attached = USBCameraService.shared.attachedCameras()
        let added = Set(attached.keys).subtracting(known)
        known = Set(attached.keys)
        for key in added {
            if let info = attached[key] { reapply(to: info) }
        }
    }

    /// Writes the camera's saved snapshot, if its profile asks for it, on the shared UVC
    /// queue. The service opens the USB device on this first access.
    private func reapply(to info: USBCameraInfo) {
        guard let profile = store.profile(for: info.persistenceKey), profile.reapplyOnConnect else {
            log.notice("no reapply for \(info.name, privacy: .public) (no profile or flag off)")
            return
        }
        let writes = ControlCatalog.orderedWrites(from: profile.decodedSnapshot)
        Task { [weak self] in
            await USBCameraService.shared.apply(writes, to: info.key)
            log.notice("reapplied \(writes.count, privacy: .public) controls to \(info.name, privacy: .public)")
            self?.onReapplied?(info.persistenceKey)
        }
    }
}
