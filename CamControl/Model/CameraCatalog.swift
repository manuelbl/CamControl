//
//  CameraCatalog.swift
//  Enumerates the AVFoundation cameras and tracks connect/disconnect, exposing a
//  plain `[Camera]` snapshot. Kept deliberately non-`@Observable`: it publishes
//  changes through an `onChange` closure so the single source of observable truth
//  stays in `AppModel`, which the UI watches.
//
//  Connect detection uses AVFoundation notifications (ADR-0001) so it works while
//  backgrounded and independent of any capture session. The USB side has its own,
//  independent view of the same event, so the list republishes on `USBCameraService`
//  availability changes too — that is what settles the enumeration race the ADR
//  describes: a camera AVFoundation announces first appears uncontrollable, and flips
//  the moment its USB device is enumerated (ADR-0004).
//

import AVFoundation
import os

private let log = Logger(subsystem: "net.codecrete.CamControl", category: "CameraCatalog")

/// One AVFoundation camera, identified by its port-dependent session identity
/// (`AVCaptureDevice.uniqueID`). A pure value type — the backing `AVCaptureDevice`
/// is re-resolved by id when needed (`AVCaptureDevice(uniqueID:)`), keeping `Camera`
/// `Sendable`/`Hashable` and free of AVFoundation object identity.
struct Camera: Identifiable, Hashable, Sendable {
    /// Session identity (`location-vendor-product`), used for the preview and to address
    /// the camera's USB device (`CameraKey(sessionID:)`).
    let id: String
    let name: String
    /// True iff `USBCameraService` has a backing USB Video Class device attached.
    let isControllable: Bool
}

/// Enumerates cameras and fires `onChange` whenever the set changes.
@MainActor
final class CameraCatalog {
    /// Called on the main actor with the fresh camera list on every change (and once at `start`).
    var onChange: (([Camera]) -> Void)?

    private var observationTask: Task<Void, Never>?
    private var availabilityToken: USBCameraService.ObserverToken?

    /// The device classes we surface. Non-USB ones (built-in, Continuity) appear too —
    /// previewable but not controllable, per the spec.
    private static let deviceTypes: [AVCaptureDevice.DeviceType] =
        [.builtInWideAngleCamera, .external, .continuityCamera]

    /// Begins observing connect/disconnect and immediately publishes the current list.
    func start() {
        availabilityToken = USBCameraService.shared.addAvailabilityObserver { [weak self] in
            self?.publish()
        }
        publish()
        observationTask = Task { @MainActor [weak self] in
            let center = NotificationCenter.default
            // Merge the two device notifications; either one just triggers a re-enumeration.
            async let connects: Void =
                self?.watch(center, AVCaptureDevice.wasConnectedNotification) ?? ()
            async let disconnects: Void =
                self?.watch(center, AVCaptureDevice.wasDisconnectedNotification) ?? ()
            _ = await (connects, disconnects)
        }
    }

    func stop() {
        observationTask?.cancel()
        observationTask = nil
        if let token = availabilityToken {
            USBCameraService.shared.removeAvailabilityObserver(token)
            availabilityToken = nil
        }
    }

    private func watch(_ center: NotificationCenter, _ name: Notification.Name) async {
        for await _ in center.notifications(named: name) {
            publish()
        }
    }

    /// The current cameras, in AVFoundation's enumeration order.
    func current() -> [Camera] {
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: Self.deviceTypes, mediaType: .video, position: .unspecified)
        return session.devices.map {
            Camera(id: $0.uniqueID,
                   name: $0.localizedName,
                   isControllable: USBCameraService.shared.isControllable(sessionID: $0.uniqueID))
        }
    }

    private func publish() {
        let cameras = current()
        log.notice("cameras: \(cameras.count, privacy: .public) (\(cameras.filter(\.isControllable).count, privacy: .public) controllable)")
        onChange?(cameras)
    }
}
