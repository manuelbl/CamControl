//
//  ControlCatalog.swift
//  The fixed, ordered list of controls the app exposes, with their metadata and
//  hardware targets. Data types per control follow "USB Device Class Definition
//  for Video Devices" (recovered from the v1 implementation).
//

import Foundation

/// One entry in the control catalog: a UI-facing control plus how to reach the hardware.
struct ControlDescriptor: Sendable {
    let id: ControlID
    let displayName: LocalizedStringResource
    let group: ControlGroup
    let kind: ControlKind
    let unit: DisplayUnit
    let target: HardwareTarget
}

enum ControlCatalog {
    /// All controls in display order (EXPOSURE & COLOR · IMAGE · FRAMING).
    /// Pan/Tilt share CTControlPanTiltAbsolute (axes 0/1); WB is Auto + Temperature.
    static let all: [ControlDescriptor] = [
        // EXPOSURE & COLOR
        ControlDescriptor(id: .backlight, displayName: "Backlight Compensation", group: .exposureColor,
                          kind: .toggle, unit: .none,
                          target: HardwareTarget(.processingUnit(.backlightCompensation), .uInt16)),
        ControlDescriptor(id: .antiFlicker, displayName: "Anti-flicker", group: .exposureColor,
                          kind: .segmented, unit: .none,
                          target: HardwareTarget(.processingUnit(.powerLineFrequency), .uInt8)),
        ControlDescriptor(id: .whiteBalanceAuto, displayName: "White Balance (Auto)", group: .exposureColor,
                          kind: .toggle, unit: .none,
                          target: HardwareTarget(.processingUnit(.whiteBalanceTemperatureAuto), .boolean)),
        ControlDescriptor(id: .whiteBalanceTemp, displayName: "White Balance Temperature", group: .exposureColor,
                          kind: .slider, unit: .kelvin,
                          target: HardwareTarget(.processingUnit(.whiteBalanceTemperature), .uInt16)),

        // IMAGE
        ControlDescriptor(id: .brightness, displayName: "Brightness", group: .image,
                          kind: .slider, unit: .percent,
                          target: HardwareTarget(.processingUnit(.brightness), .sInt16)),
        ControlDescriptor(id: .contrast, displayName: "Contrast", group: .image,
                          kind: .slider, unit: .percent,
                          target: HardwareTarget(.processingUnit(.contrast), .uInt16)),
        ControlDescriptor(id: .saturation, displayName: "Saturation", group: .image,
                          kind: .slider, unit: .percent,
                          target: HardwareTarget(.processingUnit(.saturation), .uInt16)),
        ControlDescriptor(id: .sharpness, displayName: "Sharpness", group: .image,
                          kind: .slider, unit: .percent,
                          target: HardwareTarget(.processingUnit(.sharpness), .uInt16)),

        // FRAMING
        ControlDescriptor(id: .zoom, displayName: "Zoom", group: .framing,
                          kind: .slider, unit: .percent,
                          target: HardwareTarget(.cameraTerminal(.zoomAbsolute), .uInt16)),
        ControlDescriptor(id: .pan, displayName: "Pan", group: .framing,
                          kind: .slider, unit: .degrees,
                          target: HardwareTarget(.cameraTerminal(.panTiltAbsolute), .sInt32Tuple, tupleAxis: 0)),
        ControlDescriptor(id: .tilt, displayName: "Tilt", group: .framing,
                          kind: .slider, unit: .degrees,
                          target: HardwareTarget(.cameraTerminal(.panTiltAbsolute), .sInt32Tuple, tupleAxis: 1)),
    ]

    private static let byID: [ControlID: ControlDescriptor] =
        Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })

    static func descriptor(for id: ControlID) -> ControlDescriptor {
        // Every ControlID has a catalog entry by construction.
        byID[id]!
    }

    /// Snapshot → ordered writes: catalog display order, which already places WB Auto
    /// before WB temperature (the dependency order). The temperature is skipped when the
    /// snapshot says Auto is on — the camera owns it then, and some firmware rejects the
    /// write outright.
    static func orderedWrites(from snapshot: [ControlID: Int64]) -> [(ControlID, Int64)] {
        let wbAutoOn = (snapshot[.whiteBalanceAuto] ?? 0) != 0
        return all.compactMap { descriptor -> (ControlID, Int64)? in
            guard let value = snapshot[descriptor.id] else { return nil }
            if descriptor.id == .whiteBalanceTemp && wbAutoOn { return nil }
            return (descriptor.id, value)
        }
    }
}
