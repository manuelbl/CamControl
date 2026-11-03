//
//  ControlModel.swift
//  Value types describing the fixed set of camera controls the app manipulates.
//
//  These are UI-facing "catalog entries", not raw UVC controls: Pan and Tilt are
//  two entries backed by one CT control (PanTiltAbsolute, axes 0/1), and Exposure
//  and White Balance are each an *auto pair* (Auto + manual value) rendered as one
//  row. Each entry carries a `HardwareTarget` describing how to reach the hardware.
//

import Foundation

/// A UI-facing control the app can read/write. One `ControlID` per catalog entry.
enum ControlID: String, CaseIterable, Sendable {
    case exposureAuto, exposureTime, gain
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
    case shutter    // native × 100 µs, as "1/N s"; the slider is logarithmic
    case none
}

/// An Auto toggle plus the manual value it governs, rendered as one row: Auto checkbox
/// and slider. While Auto is on, the camera owns the manual value: the slider is disabled
/// and frozen, and a reapply skips it. Auto is on ⇔ its value ≠ `manualValue`, which is
/// also the minimum of the Auto control's range.
struct AutoPair: Sendable {
    let autoID: ControlID
    let manualID: ControlID
    /// Row label.
    let label: LocalizedStringResource
    /// The Auto control's native value meaning "manual".
    let manualValue: Int64
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
/// boolean control this is the synthetic `{0, 1, 1, default}`; for Auto-Exposure Mode
/// see `autoExposure(modes:default:)`.
struct ControlRange: Sendable, Equatable {
    let minimum: Int64
    let maximum: Int64
    let resolution: Int64
    let `default`: Int64
}

extension ControlRange {
    /// Synthetic range for Auto-Exposure Mode, whose GET_RES is a bitmap of supported
    /// modes (UVC 4.2.2.1.2: 1 = manual, 2 = auto, 4 = shutter priority, 8 = aperture
    /// priority). Minimum is manual; maximum is the most automatic mode a webcam offers:
    /// aperture priority if supported (webcams have a fixed iris, so it is full auto
    /// exposure), else auto. Nil if manual or both of those modes are missing — the
    /// Auto toggle would then have nothing to switch between.
    static func autoExposure(modes: Int64, default: Int64) -> ControlRange? {
        guard modes & 1 != 0 else { return nil }
        let auto: Int64
        if modes & 8 != 0 { auto = 8 } else if modes & 2 != 0 { auto = 2 } else { return nil }
        return ControlRange(minimum: 1, maximum: auto, resolution: 1, default: `default`)
    }
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
