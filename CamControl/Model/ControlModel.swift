//
//  ControlModel.swift
//  Value types describing the fixed set of camera controls the app manipulates.
//
//  These are UI-facing "catalog entries", not raw UVC controls: Pan and Tilt are
//  two entries backed by one CT control (PanTiltAbsolute, axes 0/1), and White
//  Balance is two entries (Auto + Temperature) over two PU controls. Each entry
//  carries a `HardwareTarget` describing how to reach the hardware.
//

import Foundation

/// A UI-facing control the app can read/write. One `ControlID` per catalog entry.
enum ControlID: String, CaseIterable, Sendable {
    case backlight, antiFlicker, whiteBalanceAuto, whiteBalanceTemp
    case brightness, contrast, saturation, sharpness
    case zoom, pan, tilt
}

/// Which on-screen widget renders a control. Drives rendering independently of the
/// underlying data type (e.g. Backlight is a `.toggle` but numeric on the wire).
enum ControlKind: Sendable {
    case slider, toggle, segmented
}

/// Section a control belongs to, in display order.
enum ControlGroup: Sendable {
    case exposureColor, image, framing

    /// Section header shown in the UI.
    var title: LocalizedStringResource {
        switch self {
        case .exposureColor: "Exposure & Color"
        case .image:         "Image"
        case .framing:       "Framing"
        }
    }
}

/// Human-friendly rendering of a native value, for read-out only. Never round-trips
/// back to hardware. `.none` for self-describing widgets (toggles/segmented).
enum DisplayUnit: Sendable {
    case percent    // (value − min) / (max − min) × 100
    case kelvin     // native value directly
    case degrees    // native / 3600 (arc-seconds → degrees)
    case none
}

/// How to reach a control on the hardware: which UVC unit + control, its data type,
/// and — for the Pan/Tilt tuple — which 32-bit axis (0 = pan, 1 = tilt).
struct HardwareTarget: Sendable {
    enum Unit: Sendable {
        case processingUnit(PUControl)
        case cameraTerminal(CTControl)
    }
    let unit: Unit
    let dataType: VideoControlDataType
    /// nil for scalar controls; 0 or 1 for a half of the Pan/Tilt SInt32 tuple.
    let tupleAxis: Int?

    init(_ unit: Unit, _ dataType: VideoControlDataType, tupleAxis: Int? = nil) {
        self.unit = unit
        self.dataType = dataType
        self.tupleAxis = tupleAxis
    }
}

/// Native integer range of a control, in the camera's own units. For a supported
/// boolean control this is the synthetic `{0, 1, 1, default}`.
struct ControlRange: Sendable, Equatable {
    let minimum: Int64
    let maximum: Int64
    let resolution: Int64
    let `default`: Int64
}

/// Dynamic per-control state: whether the camera supports it and its current native value.
struct ControlState: Sendable, Equatable {
    let supported: Bool
    let value: Int64
}

/// Result of discovering one control on a camera. `range` is present iff `state.supported`.
struct ControlSnapshot: Sendable {
    let id: ControlID
    let state: ControlState
    let range: ControlRange?
}
