//
//  ControlUIState.swift
//  Editable per-control UI state, plus the interpretation of its native value that the
//  control rows display: slider read-outs, the slider's (linear or logarithmic) position,
//  toggle state, anti-flicker segments and snapping onto the control's resolution grid.
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
        case .shutter:
            return shutterText(value)
        case .none:
            return ""
        }
    }

    /// Slider position bounds, or `nil` if the range is unusable (unsupported or
    /// degenerate min == max). Positions are native values, except for `.shutter`
    /// controls, whose slider is logarithmic (see `sliderPosition(of:)`).
    var sliderBounds: ClosedRange<Double>? {
        guard supported, let r = range, r.maximum > r.minimum else { return nil }
        return sliderPosition(of: r.minimum)...sliderPosition(of: r.maximum)
    }

    /// Slider position of the current value.
    var sliderPosition: Double { sliderPosition(of: value) }

    /// Native value for a slider position, snapped to the resolution grid and clamped
    /// to the range.
    func value(atSliderPosition position: Double) -> Int64 {
        let native = isLogarithmic ? exp(position) - logOffset : position
        let v = snapped(native, to: range)
        guard let r = range else { return v }
        return min(max(v, r.minimum), r.maximum)
    }

    /// Exposure times span several orders of magnitude (e.g. 0.3–200 ms), so their slider
    /// is logarithmic: on a linear one, the useful short times would be squeezed together
    /// at the left end.
    private var isLogarithmic: Bool { descriptor.unit == .shutter }

    /// Keeps the logarithm defined for ranges starting at 0 or below.
    private var logOffset: Double {
        guard let r = range, r.minimum <= 0 else { return 0 }
        return Double(1 - r.minimum)
    }

    private func sliderPosition(of native: Int64) -> Double {
        var v = native
        if let r = range { v = min(max(v, r.minimum), r.maximum) }
        return isLogarithmic ? log(Double(v) + logOffset) : Double(v)
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

/// Shutter-speed read-out for an exposure time in units of 100 µs: "1/N s" below one
/// second, whole seconds from one second up.
private func shutterText(_ value: Int64) -> String {
    if value > 0 && value < 10_000 {
        // Passed as a string: a shutter speed reads "1/1000 s", without a grouping separator.
        let denominator = String(Int((10_000 / Double(value)).rounded()))
        return String(localized: "1/\(denominator) s", comment: "Exposure time as a fraction of a second")
    }
    let seconds = Int((Double(value) / 10_000).rounded())
    return String(localized: "\(seconds) s", comment: "Exposure time in seconds")
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
