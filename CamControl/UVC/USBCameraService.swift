//
//  USBCameraService.swift
//  The single owner of the USB side of every camera: device handles, open/close and all
//  control traffic.
//
//  Cameras come and go through `USBRegistry`'s connect/disconnect callbacks — the USB
//  layer's own truth, not AVFoundation's. Callers address a camera by `CameraKey` and
//  never hold a device handle, so one caller finishing (a background reapply, a camera
//  deselected in the UI) can no longer close the device underneath another.
//
//  Two isolation domains, deliberately:
//
//  * The *availability snapshot* — which cameras are attached, with their names and
//    persistence keys — sits behind a lock and reads synchronously from any thread. The
//    UI needs it while building the camera list synchronously, and it is published
//    before observers are notified, so an observer that immediately asks for controls
//    always finds the camera.
//  * The *hardware traffic* — open/close and every control transfer — is isolated to
//    this actor, whose executor is one app-wide serial queue. The blocking IOKit calls
//    run on that queue's own thread, never on the cooperative pool and never two at a
//    time. A USB device is opened lazily on first control access and closed when the
//    camera detaches — at most one open per physical connection.
//

import Foundation
import os

private let log = Logger(subsystem: "net.codecrete.CamControl", category: "USBCameraService")

// MARK: - Identity

extension CameraKey {
    init(device: USBDevice) {
        self.init(locationID: device.locationID,
                  vendorID: device.vendorID,
                  productID: device.productID)
    }
}

/// What the rest of the app knows about an attached, controllable camera.
struct USBCameraInfo: Sendable, Equatable {
    let key: CameraKey
    /// USB product name — for logs; the UI shows AVFoundation's localized name.
    let name: String
    /// Port-independent persistence identity (`vendor-product-serial`, ADR-0002).
    let persistenceKey: String
}

// MARK: - Service

actor USBCameraService {
    /// The app-wide instance. Everything USB goes through it.
    static let shared = USBCameraService()

    /// The one serial queue all blocking UVC hardware access is marshalled onto. It is
    /// this actor's executor (`DispatchSerialQueue` conforms to `SerialExecutor`), so
    /// actor-isolated methods run on the queue's own thread and callers just `await`.
    private static let uvcQueue = DispatchSerialQueue(label: "net.codecrete.CamControl.uvcQueue")

    nonisolated var unownedExecutor: UnownedSerialExecutor {
        Self.uvcQueue.asUnownedSerialExecutor()
    }

    /// A camera whose USB device the registry has handed us, before it is opened.
    ///
    /// `@unchecked Sendable` because the wrapped `USBDevice`'s stored properties are
    /// immutable apart from its open state, which only this actor's executor ever
    /// touches; the lock merely hands the reference over.
    private struct AttachedCamera: @unchecked Sendable {
        let info: USBCameraInfo
        let device: USBDevice
        let descriptor: CameraDescriptor
    }

    /// An attached camera whose device this actor has opened. Actor-isolated; holds that
    /// camera's not-yet-written control values.
    private final class OpenCamera {
        /// Registry entry ID of the device this was opened on — a replug on the same port
        /// keeps the `CameraKey` but changes this, which is how a stale handle is spotted.
        let entryID: UInt64
        let uvc: UVCVideoDevice
        /// Latest not-yet-written value per control; the coalescing point for live writes.
        var pending: [ControlID: Int64] = [:]

        init(entryID: UInt64, uvc: UVCVideoDevice) {
            self.entryID = entryID
            self.uvc = uvc
        }
    }

    /// Opaque handle for un-registering an availability observer.
    struct ObserverToken: Hashable, Sendable {
        fileprivate let id = UUID()
    }

    /// Lock-protected state, readable from any thread.
    private struct Availability: Sendable {
        var cameras: [CameraKey: AttachedCamera] = [:]
        var observers: [ObserverToken: @MainActor @Sendable () -> Void] = [:]
    }

    private nonisolated let availability = OSAllocatedUnfairLock(initialState: Availability())

    /// Open devices, keyed by camera. Only ever mutated on the actor's executor.
    private var openCameras: [CameraKey: OpenCamera] = [:]

    /// FIFO channel of coalesce-able live writes from the UI.
    private typealias Submission = (key: CameraKey, id: ControlID, value: Int64)
    private let submissions: AsyncStream<Submission>
    private nonisolated let submissionContinuation: AsyncStream<Submission>.Continuation
    private var isDraining = false

    private init() {
        let (stream, continuation) = AsyncStream<Submission>.makeStream()
        self.submissions = stream
        self.submissionContinuation = continuation
        Task { await self.consumeSubmissions() }
    }

    // MARK: - Lifecycle

    /// Starts USB monitoring. Call once at launch: the registry reports the already
    /// attached devices during `start()`, so the callbacks are wired up first.
    nonisolated func start() {
        let registry = USBRegistry.shared
        registry.onConnected = { [weak self] device in self?.deviceAttached(device) }
        registry.onDisconnected = { [weak self] device in self?.deviceDetached(device) }
        do {
            try registry.start()
        } catch {
            log.error("Failed to start USB device monitoring – \(error, privacy: .public)")
        }
    }

    /// Registry callback (registry queue): admits the UVC cameras and publishes them.
    /// Parsing the configuration descriptor needs no open — controllability is known
    /// from the bytes the device already handed over at enumeration.
    private nonisolated func deviceAttached(_ device: USBDevice) {
        let descriptor = CameraDescriptor(configurationDescriptor: device.configurationDescriptor)
        guard descriptor.isControllableCamera else { return }

        let key = CameraKey(device: device)
        let attached = AttachedCamera(
            info: USBCameraInfo(key: key, name: device.product,
                                persistenceKey: device.persistenceKey),
            device: device,
            descriptor: descriptor)
        log.notice("camera attached: \(device.product, privacy: .public) (\(key, privacy: .public))")
        publish { $0.cameras[key] = attached }
    }

    /// Registry callback (registry queue): retracts the camera, then closes its device on
    /// the actor. Ordering against in-flight control requests does not matter — a request
    /// racing the close fails exactly as it would against an unplugged camera.
    private nonisolated func deviceDetached(_ device: USBDevice) {
        let key = CameraKey(device: device)
        let entryID = device.entryID
        // Most USB devices that come and go are not ours (hubs, keyboards); leave the
        // observers alone for those.
        guard info(for: key) != nil else { return }
        let wasAttached = publish { state -> Bool in
            guard state.cameras[key]?.device.entryID == entryID else { return false }
            state.cameras.removeValue(forKey: key)
            return true
        }
        guard wasAttached else { return }
        log.notice("camera detached: \(device.product, privacy: .public) (\(key, privacy: .public))")
        Task { await self.closeCamera(key, entryID: entryID) }
    }

    /// Mutates the availability snapshot and notifies the observers afterwards, so an
    /// observer always sees the state that triggered it.
    @discardableResult
    private nonisolated func publish<R: Sendable>(_ mutate: @Sendable (inout Availability) -> R) -> R {
        let (result, observers) = availability
            .withLock { state -> (R, [@MainActor @Sendable () -> Void]) in
                (mutate(&state), Array(state.observers.values))
            }
        for observer in observers {
            Task { @MainActor in observer() }
        }
        return result
    }

    // MARK: - Availability (any thread)

    /// The attached controllable cameras, keyed by camera.
    nonisolated func attachedCameras() -> [CameraKey: USBCameraInfo] {
        availability.withLock { $0.cameras.mapValues(\.info) }
    }

    /// What is known about an attached camera, or nil if it is not attached.
    nonisolated func info(for key: CameraKey) -> USBCameraInfo? {
        availability.withLock { $0.cameras[key]?.info }
    }

    /// Indicates if the camera with this AVFoundation session identity is controllable,
    /// i.e. a UVC device of ours sits behind it.
    nonisolated func isControllable(sessionID: String) -> Bool {
        guard let key = CameraKey(sessionID: sessionID) else { return false }
        return info(for: key) != nil
    }

    /// Registers a callback fired on the main actor whenever cameras attach or detach.
    /// The snapshot is already updated when it runs.
    nonisolated func addAvailabilityObserver(
        _ observer: @escaping @MainActor @Sendable () -> Void) -> ObserverToken {
        let token = ObserverToken()
        availability.withLock { $0.observers[token] = observer }
        return token
    }

    nonisolated func removeAvailabilityObserver(_ token: ObserverToken) {
        availability.withLock { _ = $0.observers.removeValue(forKey: token) }
    }

    // MARK: - Reading controls

    /// Reads every catalog control of a camera: supported flag, native range and current
    /// value. Nil if the camera is not attached (or its device cannot be opened);
    /// unsupported controls carry `supported == false` and no range.
    func discoverAll(_ key: CameraKey) -> [ControlSnapshot]? {
        guard let camera = openCamera(key) else { return nil }
        return ControlCatalog.all.map { snapshot(of: $0, on: camera.uvc) }
    }

    /// Reads the current native value of every supported control (values only — ranges are
    /// static). Drives the UI's settle read-back after interaction quiesces, catching any
    /// value the camera clamped/snapped or changed via an interacting control.
    func readValues(_ key: CameraKey) -> [ControlID: Int64] {
        guard let camera = openCamera(key) else { return [:] }
        var values: [ControlID: Int64] = [:]
        for descriptor in ControlCatalog.all where isSupported(descriptor.target, on: camera.uvc) {
            values[descriptor.id] = readAspect(descriptor.target, .value, on: camera.uvc)
        }
        return values
    }

    private func snapshot(of d: ControlDescriptor, on uvc: UVCVideoDevice) -> ControlSnapshot {
        let unsupported = ControlSnapshot(id: d.id, state: ControlState(supported: false, value: 0),
                                          range: nil)
        guard isSupported(d.target, on: uvc) else { return unsupported }
        let value = readAspect(d.target, .value, on: uvc)
        let range: ControlRange
        if d.target.dataType == .boolean {
            // Booleans have no meaningful min/max/resolution; synthesize 0/1.
            range = ControlRange(minimum: 0, maximum: 1, resolution: 1,
                                 default: readAspect(d.target, .`default`, on: uvc))
        } else if case .cameraTerminal(.autoExposureMode) = d.target.unit {
            // GET_RES is a bitmap of the supported modes, not a step size.
            guard let r = ControlRange.autoExposure(modes: readAspect(d.target, .resolution, on: uvc),
                                                    default: readAspect(d.target, .`default`, on: uvc))
            else { return unsupported }
            range = r
        } else {
            range = ControlRange(minimum: readAspect(d.target, .minimum, on: uvc),
                                 maximum: readAspect(d.target, .maximum, on: uvc),
                                 resolution: readAspect(d.target, .resolution, on: uvc),
                                 default: readAspect(d.target, .`default`, on: uvc))
        }
        return ControlSnapshot(id: d.id, state: ControlState(supported: true, value: value), range: range)
    }

    // MARK: - Writing controls

    /// Enqueues a live write from the UI. Non-blocking and FIFO-ordered by `yield`, so the
    /// last value the user sets is the last one written. Callable from any isolation.
    nonisolated func submit(_ id: ControlID, value: Int64, to key: CameraKey) {
        submissionContinuation.yield((key, id, value))
    }

    /// Writes a saved snapshot to a camera in the given order (the background reapply
    /// path — sequencing such as "Auto before its manual value" is the caller's job).
    /// Controls the camera no longer supports are skipped: profiles are keyed by
    /// vendor-product-serial, so an identical camera with a duplicate serial can share a
    /// profile with a slightly different control set.
    func apply(_ writes: [(ControlID, Int64)], to key: CameraKey) {
        guard let camera = openCamera(key) else { return }
        for (id, value) in writes {
            guard isSupported(ControlCatalog.descriptor(for: id).target, on: camera.uvc) else { continue }
            write(id, value: value, on: camera.uvc)
        }
    }

    /// Resets a control to its hardware default. Note: for Pan/Tilt this resets both axes
    /// (the control is one tuple on the wire).
    func reset(_ id: ControlID, on key: CameraKey) {
        guard let camera = openCamera(key) else { return }
        let target = ControlCatalog.descriptor(for: id).target
        switch target.unit {
        case .processingUnit(let c): camera.uvc.resetPUControl(c, dataType: target.dataType)
        case .cameraTerminal(let c): camera.uvc.resetCTControl(c, dataType: target.dataType)
        }
    }

    /// Single consumer of the ordered submission stream: records the latest value per
    /// control on its camera and kicks a drain if one isn't already running.
    private func consumeSubmissions() async {
        for await (key, id, value) in submissions {
            guard let camera = openCamera(key) else { continue }
            camera.pending[id] = value
            guard !isDraining else { continue }
            isDraining = true
            Task { await self.drain() }
        }
    }

    /// Writes the latest pending value for each control, yielding between writes so queued
    /// submissions can overwrite `pending` first — a fast drag collapses to ~2 writes and
    /// never backs up. Values pending for a camera that detaches mid-drain go with it.
    private func drain() async {
        while let (camera, id, value) = takeNextPending() {
            write(id, value: value, on: camera.uvc)
            await Task.yield()
        }
        isDraining = false
    }

    private func takeNextPending() -> (OpenCamera, ControlID, Int64)? {
        for camera in openCameras.values {
            if let id = camera.pending.keys.first {
                return (camera, id, camera.pending.removeValue(forKey: id)!)
            }
        }
        return nil
    }

    /// Writes a control's native value. For a Pan/Tilt axis this is a read-modify-write of
    /// the whole tuple so the other axis is preserved.
    private func write(_ id: ControlID, value: Int64, on uvc: UVCVideoDevice) {
        let target = ControlCatalog.descriptor(for: id).target
        if let axis = target.tupleAxis {
            let current = readRaw(target, .value, on: uvc)
            let composed = VideoControlDataType.compose(into: current, axis: axis, value: Int32(truncatingIfNeeded: value))
            setRaw(target, composed, on: uvc)
        } else {
            setRaw(target, value, on: uvc)
        }
    }

    // MARK: - Open / close

    /// The open control surface for a camera, opening its USB device on first use. Nil if
    /// the camera is no longer attached or the device cannot be opened.
    ///
    /// A camera replugged into the same port keeps its `CameraKey` but arrives as a new
    /// USB device; the entry ID check retires the stale handle rather than talking to a
    /// device that is gone.
    private func openCamera(_ key: CameraKey) -> OpenCamera? {
        guard let attached = availability.withLock({ $0.cameras[key] }) else {
            closeCamera(key, entryID: nil)
            return nil
        }

        if let open = openCameras[key] {
            if open.entryID == attached.device.entryID { return open }
            open.uvc.close()
            openCameras.removeValue(forKey: key)
        }

        guard let uvc = UVCVideoDevice(device: attached.device, descriptor: attached.descriptor)
        else { return nil }
        let camera = OpenCamera(entryID: attached.device.entryID, uvc: uvc)
        openCameras[key] = camera
        return camera
    }

    /// Closes a camera's device if it is open. `entryID` nil closes whatever is there;
    /// otherwise only the handle for that exact connection is closed.
    private func closeCamera(_ key: CameraKey, entryID: UInt64?) {
        guard let camera = openCameras[key],
              entryID == nil || camera.entryID == entryID else { return }
        openCameras.removeValue(forKey: key)
        camera.uvc.close()
    }

    // MARK: - Raw hardware access (on the serial executor)

    private func isSupported(_ target: HardwareTarget, on uvc: UVCVideoDevice) -> Bool {
        switch target.unit {
        case .processingUnit(let c): uvc.hasPUControl(c)
        case .cameraTerminal(let c): uvc.hasCTControl(c)
        }
    }

    /// Reads an aspect, decomposing the requested tuple axis when the target is a tuple.
    private func readAspect(_ target: HardwareTarget, _ aspect: VideoControlAspect,
                            on uvc: UVCVideoDevice) -> Int64 {
        let raw = readRaw(target, aspect, on: uvc)
        if let axis = target.tupleAxis {
            return Int64(VideoControlDataType.decompose(tuple: raw, axis: axis))
        }
        return raw
    }

    private func readRaw(_ target: HardwareTarget, _ aspect: VideoControlAspect,
                         on uvc: UVCVideoDevice) -> Int64 {
        switch target.unit {
        case .processingUnit(let c):
            uvc.intValue(ofPUControl: c, aspect: aspect, dataType: target.dataType)
        case .cameraTerminal(let c):
            uvc.intValue(ofCTControl: c, aspect: aspect, dataType: target.dataType)
        }
    }

    private func setRaw(_ target: HardwareTarget, _ value: Int64, on uvc: UVCVideoDevice) {
        switch target.unit {
        case .processingUnit(let c):
            uvc.setValue(value, ofPUControl: c, dataType: target.dataType)
        case .cameraTerminal(let c):
            uvc.setValue(value, ofCTControl: c, dataType: target.dataType)
        }
    }
}
