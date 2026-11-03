//
//  CameraPreview.swift
//  Live camera preview: an `AVCaptureSession` feeding an `AVCaptureVideoPreviewLayer`,
//  bridged into SwiftUI via `NSViewRepresentable`.
//
//  All session mutation (configuration + start/stop) is confined to one private serial
//  queue so it never blocks the main thread; only the layer's `session` reference is set
//  on the main thread (the documented, thread-safe assignment). The session is driven by
//  camera *id* (resolved to an `AVCaptureDevice` on the queue) so no non-`Sendable`
//  AVFoundation object ever crosses a thread boundary. The device's active format is
//  observed so the preview's aspect ratio follows resolution changes, including ones
//  made by other apps.
//

import SwiftUI
import AVFoundation
import os

private let log = Logger(subsystem: "net.codecrete.CamControl", category: "Preview")

/// Owns the capture session for the preview. `@unchecked Sendable`: every access to
/// `session` happens on `queue` (or is the one-time main-thread layer hookup), upholding
/// AVFoundation's threading contract that the region checker can't prove on its own.
/// The one exception is `aspectRatio`, which is only written and read on the main thread.
@Observable
final class PreviewSession: @unchecked Sendable {
    /// Width / height of the current camera's video, or `nil` if there's no camera or its
    /// format is unknown. Main thread only.
    private(set) var aspectRatio: CGFloat?

    @ObservationIgnored let session = AVCaptureSession()
    @ObservationIgnored private let queue = DispatchQueue(label: "net.codecrete.CamControl.previewSession")
    @ObservationIgnored private var currentDeviceID: String?
    /// KVO on the current device's `activeFormat`. Queue only.
    @ObservationIgnored private var formatObservation: NSKeyValueObservation?

    /// Points the session at a camera (by session identity), swapping the input in place.
    /// Passing `nil` removes all inputs. No-op if already on that device.
    func setDevice(id deviceID: String?) {
        queue.async { [self] in
            guard deviceID != currentDeviceID else { return }
            currentDeviceID = deviceID

            formatObservation = nil
            session.beginConfiguration()
            for input in session.inputs { session.removeInput(input) }
            if let deviceID, let device = AVCaptureDevice(uniqueID: deviceID),
               let input = try? AVCaptureDeviceInput(device: device),
               session.canAddInput(input) {
                session.addInput(input)
                // Fires initially and whenever the format changes (e.g. the session preset
                // applied on commit, or another app switching resolution).
                formatObservation = device.observe(\.activeFormat, options: [.initial]) { [weak self] device, _ in
                    self?.publishAspectRatio(of: device.activeFormat)
                }
            } else {
                publishAspectRatio(of: nil)
            }
            session.commitConfiguration()
        }
    }

    /// Hands the format's display aspect ratio to the main thread. Callbacks arrive in
    /// order on the main queue, so the latest device's value always lands last.
    private func publishAspectRatio(of format: AVCaptureDevice.Format?) {
        var ratio: CGFloat?
        if let format {
            let size = CMVideoFormatDescriptionGetPresentationDimensions(
                format.formatDescription, usePixelAspectRatio: true, useCleanAperture: false)
            if size.width > 0, size.height > 0 { ratio = size.width / size.height }
        }
        DispatchQueue.main.async { [self] in
            if aspectRatio != ratio { aspectRatio = ratio }
        }
    }

    func start() {
        queue.async { [self] in
            guard !session.isRunning else { return }
            session.startRunning()
        }
    }

    func stop() {
        queue.async { [self] in
            guard session.isRunning else { return }
            session.stopRunning()
        }
    }
}

/// SwiftUI wrapper over an `AVCaptureVideoPreviewLayer`-backed `NSView`.
struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> PreviewLayerView {
        let view = PreviewLayerView()
        view.previewLayer.session = session
        // Fit, never crop: the box matches the camera's aspect ratio up to a height cap, and
        // anything beyond the cap is letterboxed.
        view.previewLayer.videoGravity = .resizeAspect
        return view
    }

    func updateNSView(_ nsView: PreviewLayerView, context: Context) {
        // Session object is stable for the app's lifetime; nothing to update here.
    }
}

/// An `NSView` whose backing layer is an `AVCaptureVideoPreviewLayer`.
final class PreviewLayerView: NSView {
    override func makeBackingLayer() -> CALayer { AVCaptureVideoPreviewLayer() }

    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .duringViewResize
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
