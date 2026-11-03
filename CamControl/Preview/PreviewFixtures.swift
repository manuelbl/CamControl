//
//  PreviewFixtures.swift
//  Hand-built sample data for the SwiftUI canvas. DEBUG-only: nothing here ships in a
//  release build, and none of it touches USB or AVFoundation. Feeds `AppModel.preview(...)`.
//

#if DEBUG
import Foundation

enum PreviewFixtures {
    // MARK: - Cameras

    /// A controllable USB camera (drives the fully-populated control panel).
    static let usbCamera = Camera(id: "0x1400000-046d-0825",
                                  name: "Logitech HD Webcam C270",
                                  isControllable: true)

    /// A built-in camera: previewable but not controllable (drives the unsupported banner).
    static let builtInCamera = Camera(id: "builtin-0-0",
                                      name: "FaceTime HD Camera",
                                      isControllable: false)

    static let cameras: [Camera] = [usbCamera, builtInCamera]

    // MARK: - Controls

    /// One supported control per catalog entry, with plausible native ranges/values so
    /// every widget (sliders, toggle, segmented, auto pairs) renders live.
    static let supportedControls: [ControlUIState] = [
        // EXPOSURE & COLOR
        control(.exposureAuto, min: 1, max: 8, value: 1),          // manual → exposure slider live
        control(.exposureTime, min: 3, max: 2047, value: 167),     // 1/60 s
        control(.gain, min: 0, max: 255, value: 64),
        control(.antiFlicker, min: 0, max: 3, value: 2),           // "60 Hz"
        control(.backlight, min: 0, max: 1, value: 0),             // off
        control(.whiteBalanceAuto, min: 0, max: 1, value: 0),      // manual → temp slider live
        control(.whiteBalanceTemp, min: 2800, max: 6500, resolution: 100, value: 4600),

        // IMAGE
        control(.brightness, min: -64, max: 64, value: 8),
        control(.contrast, min: 0, max: 95, value: 40),
        control(.saturation, min: 0, max: 100, value: 64),
        control(.sharpness, min: 0, max: 7, value: 3),

        // FRAMING
        control(.zoom, min: 100, max: 500, value: 100),
        control(.pan, min: -648_000, max: 648_000, resolution: 3600, value: 0),   // arc-seconds
        control(.tilt, min: -648_000, max: 648_000, resolution: 3600, value: 36_000), // 10°
    ]

    /// A camera that reports zero controls: no rows render, so the empty state shows.
    static let unsupportedControls: [ControlUIState] =
        ControlID.allCases.map(unsupported)

    /// A partially-capable camera: a couple of Image sliders plus a *manual-only* White
    /// Balance (temperature supported, Auto not) — exercises row hiding, an empty Framing
    /// section being dropped, and the bare WB slider (no Auto checkbox).
    static let partialControls: [ControlUIState] = {
        var byID = Dictionary(uniqueKeysWithValues:
            ControlID.allCases.map { ($0, unsupported($0)) })
        byID[.brightness] = control(.brightness, min: -64, max: 64, value: 8)
        byID[.contrast] = control(.contrast, min: 0, max: 95, value: 40)
        byID[.whiteBalanceTemp] =
            control(.whiteBalanceTemp, min: 2800, max: 6500, resolution: 100, value: 4600)
        return ControlID.allCases.map { byID[$0]! }
    }()

    // MARK: - Builders

    private static func control(_ id: ControlID,
                                min: Int64, max: Int64,
                                resolution: Int64 = 1,
                                value: Int64) -> ControlUIState {
        ControlUIState(from: ControlSnapshot(
            id: id,
            state: ControlState(supported: true, value: value),
            range: ControlRange(minimum: min, maximum: max,
                                resolution: resolution, default: min)))
    }

    private static func unsupported(_ id: ControlID) -> ControlUIState {
        ControlUIState(from: ControlSnapshot(
            id: id, state: ControlState(supported: false, value: 0), range: nil))
    }
}
#endif
