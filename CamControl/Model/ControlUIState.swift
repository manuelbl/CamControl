//
//  ControlUIState.swift
//  Editable per-control UI state, plus the interpretation of its native value that the
//  control rows display: slider read-outs and bounds, toggle state, anti-flicker segments
//  and snapping a slider position onto the control's resolution grid.
//

import Foundation

/// Editable per-control UI state for the selected camera. `range == nil` ⇔ unsupported.
struct ControlUIState: Identifiable {
    let id: ControlID
    let descriptor: ControlDescriptor
    let supported: Bool
    let range: ControlRange?
    /// Current native value: updated optimistically as the user drags/toggles, then
    /// reconciled to the camera's actual reading by the settle read-back.
    var value: Int64

    init(from snapshot: ControlSnapshot) {
        self.id = snapshot.id
        self.descriptor = ControlCatalog.descriptor(for: snapshot.id)
        self.supported = snapshot.state.supported
        self.range = snapshot.range
        self.value = snapshot.state.value
    }
}

// MARK: - Formatting / interpretation of a control's native value

extension ControlUIState {
    /// Friendly read-out for a slider, per the control's `DisplayUnit`. "—" when unsupported.
    var displayText: String {
        guard supported, let r = range else { return "—" }
        switch descriptor.unit {
        case .percent:
            guard r.maximum > r.minimum else { return "—" }
            let pct = Double(value - r.minimum) / Double(r.maximum - r.minimum) * 100
            return Int(pct.rounded()).formatted(.percent)
        case .kelvin:
            return String(localized: "\(value)K", comment: "Color temperature in kelvin")
        case .degrees:
            let degrees = Int((Double(value) / 3600).rounded())
            return String(localized: "\(degrees)°", comment: "Angle in degrees")
        case .none:
            return ""
        }
    }

    /// Double bounds for a slider, or `nil` if the range is unusable (unsupported or
    /// degenerate min == max). Snapping to `resolution` happens on write, in `snapped`.
    var sliderBounds: ClosedRange<Double>? {
        guard supported, let r = range, r.maximum > r.minimum else { return nil }
        return Double(r.minimum)...Double(r.maximum)
    }

    /// Boolean interpretation for a toggle: on ⇔ value is above the minimum
    /// (off = min, on = max — robust to ranges wider than 0/1).
    var isToggledOn: Bool {
        guard let r = range else { return false }
        return value != r.minimum
    }

    /// Segments for the Anti-flicker control; the Auto segment appears only if max ≥ 3.
    var flickerSegments: [(label: LocalizedStringResource, value: Int)] {
        var segments: [(label: LocalizedStringResource, value: Int)] =
            [("Off", 0), ("50 Hz", 1), ("60 Hz", 2)]
        if let r = range, r.maximum >= 3 { segments.append(("Auto", 3)) }
        return segments
    }
}

/// Snap a slider's continuous value onto the control's native resolution grid, anchored
/// at the range minimum. Replaces the `Slider(step:)` argument, whose only side effect we
/// want to avoid is the tick marks AppKit draws beneath a stepped `NSSlider`.
func snapped(_ value: Double, to range: ControlRange?) -> Int64 {
    guard let r = range else { return Int64(value.rounded()) }
    let res = r.resolution > 0 ? Double(r.resolution) : 1
    let steps = ((value - Double(r.minimum)) / res).rounded()
    return Int64(Double(r.minimum) + steps * res)
}
