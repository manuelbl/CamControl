//
//  CameraPreview.swift
//  Live camera preview: an `AVCaptureSession` feeding an `AVCaptureVideoPreviewLayer`,
//  bridged into SwiftUI via `NSViewRepresentable`.
//
//  All session mutation (configuration + start/stop) is confined to one private serial
//  queue so it never blocks the main thread; only the layer's `session` reference is set
//  on the main thread (the documented, thread-safe assignment). The session is driven by
//  camera *id* (resolved to an `AVCaptureDevice` on the queue) so no non-`Sendable`
//  AVFoundation object ever crosses a thread boundary.
//

import SwiftUI
import AVFoundation
import os

private let log = Logger(subsystem: "net.codecrete.CamControl", category: "Preview")

/// Owns the capture session for the preview. `@unchecked Sendable`: every access to
/// `session` happens on `queue` (or is the one-time main-thread layer hookup), upholding
/// AVFoundation's threading contract that the region checker can't prove on its own.
final class PreviewSession: @unchecked Sendable {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "net.codecrete.CamControl.previewSession")
    private var currentDeviceID: String?

    /// Points the session at a camera (by session identity), swapping the input in place.
    /// Passing `nil` removes all inputs. No-op if already on that device.
    func setDevice(id deviceID: String?) {
        queue.async { [self] in
            guard deviceID != currentDeviceID else { return }
            currentDeviceID = deviceID

            session.beginConfiguration()
            for input in session.inputs { session.removeInput(input) }
            if let deviceID, let device = AVCaptureDevice(uniqueID: deviceID),
               let input = try? AVCaptureDeviceInput(device: device),
               session.canAddInput(input) {
                session.addInput(input)
            }
            session.commitConfiguration()
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
        view.previewLayer.videoGravity = .resizeAspectFill
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
