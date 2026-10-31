//
//  CameraKey.swift
//  Port-dependent camera identity: the join between AVFoundation's session identity and
//  a USB device.
//

import Foundation

/// Port-dependent identity of a camera: the triple that AVFoundation's session identity
/// (`AVCaptureDevice.uniqueID`) and a USB device agree on. The shared vocabulary between
/// the UI, which knows cameras by session identity, and ``USBCameraService``, which knows
/// them by USB device.
struct CameraKey: Hashable, Sendable, CustomStringConvertible {
    let locationID: Int
    let vendorID: Int
    let productID: Int

    init(locationID: Int, vendorID: Int, productID: Int) {
        self.locationID = locationID
        self.vendorID = vendorID
        self.productID = productID
    }

    /// Parses AVFoundation's session identity, which for USB cameras has the format
    /// "0x1100002b4c01a2": location ID followed by the vendor and product IDs, four hex
    /// digits each. Nil for cameras that are not USB devices (built-in, Continuity).
    init?(sessionID: String) {
        guard sessionID.count >= 12, sessionID.count <= 18, sessionID.hasPrefix("0x"),
              let productID = Int(sessionID.suffix(4), radix: 16),
              let vendorID = Int(sessionID.dropLast(4).suffix(4), radix: 16),
              let locationID = Int(sessionID.dropLast(8).dropFirst(2), radix: 16)
        else { return nil }
        self.init(locationID: locationID, vendorID: vendorID, productID: productID)
    }

    var description: String { String(format: "0x%x%04x%04x", locationID, vendorID, productID) }
}
