//
//  USBRegistry.swift
//  Registry of connected USB devices: enumerates the devices attached at
//  startup and monitors connect/disconnect events.
//

import Foundation
import IOKit
import IOKit.usb
import os

private let log = Logger(subsystem: "net.codecrete.CamControl", category: "USBRegistry")

/// Registry of connected USB devices.
///
/// After `start()`, the registry maintains a list of the connected devices
/// and invokes the optional callbacks as devices come and go.
///
/// Thread safety: all mutable state is confined to the private serial
/// queue `queue`; IOKit delivers notifications on that queue, and public
/// accessors hop onto it. This confinement is the justification for the
/// `@unchecked Sendable` conformance.
final class USBRegistry: @unchecked Sendable {
    /// The app-wide registry instance.
    static let shared = USBRegistry()

    private let queue = DispatchQueue(label: "net.codecrete.CamControl.usb-registry")
    private var notifyPort: IONotificationPortRef?
    private var connectedIter: io_iterator_t = 0
    private var disconnectedIter: io_iterator_t = 0
    private var devices: [USBDevice] = []

    /// Called when a device is connected.
    ///
    /// Invoked on the registry's internal queue — hop to another queue before
    /// touching app state, and never call back into the registry from here.
    /// The device passed in is the registry's own instance; the callback takes
    /// over its use (the registry only reads its immutable properties
    /// afterwards).
    ///
    /// Assign before `start()`: already-connected devices are reported during
    /// the call.
    var onConnected: (@Sendable (USBDevice) -> Void)?

    /// Called when a device is disconnected. Same queue and rules as
    /// ``onConnected``.
    var onDisconnected: (@Sendable (USBDevice) -> Void)?

    /// Indicates if the registry has been started.
    var isStarted: Bool { queue.sync { notifyPort != nil } }

    /// Starts monitoring USB devices.
    ///
    /// The `onConnected` callback is invoked — synchronously, before this
    /// method returns — for every device that is already connected when it
    /// is called, and again whenever a device is connected later.
    ///
    /// Does nothing if the registry has already been started.
    func start() throws {
        try queue.sync {
            guard notifyPort == nil else { return }

            guard let port = IONotificationPortCreate(kIOMainPortDefault) else {
                throw USBError(message: "IONotificationPortCreate failed")
            }
            IONotificationPortSetDispatchQueue(port, queue)
            notifyPort = port

            let refcon = Unmanaged.passUnretained(self).toOpaque()

            // IOServiceAddMatchingNotification consumes the matching
            // dictionary — no release needed.
            try USBError.check(IOServiceAddMatchingNotification(
                port, kIOFirstMatchNotification,
                IOServiceMatching(kIOUSBDeviceClassName),
                { refcon, iterator in
                    Unmanaged<USBRegistry>.fromOpaque(refcon!)
                        .takeUnretainedValue().deviceConnected(iterator)
                },
                refcon, &connectedIter),
                "IOServiceAddMatchingNotification failed")

            // Drain the iterator: this picks up the already attached
            // devices, and IOKit only starts delivering notifications
            // once the iterator has been emptied.
            deviceConnected(connectedIter)

            try USBError.check(IOServiceAddMatchingNotification(
                port, kIOTerminatedNotification,
                IOServiceMatching(kIOUSBDeviceClassName),
                { refcon, iterator in
                    Unmanaged<USBRegistry>.fromOpaque(refcon!)
                        .takeUnretainedValue().deviceDisconnected(iterator)
                },
                refcon, &disconnectedIter),
                "IOServiceAddMatchingNotification failed")

            // Drain to arm the notification.
            deviceDisconnected(disconnectedIter)
        }
    }

    private func deviceConnected(_ iterator: io_iterator_t) {
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let device = USBDevice(service: service) else { continue }
            log.debug("USB device connected: \(device.description, privacy: .public)")
            devices.append(device)
            onConnected?(device)
        }
    }

    private func deviceDisconnected(_ iterator: io_iterator_t) {
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            var entryID: UInt64 = 0
            guard IORegistryEntryGetRegistryEntryID(service, &entryID) == KERN_SUCCESS,
                  let index = devices.firstIndex(where: { $0.entryID == entryID })
            else { continue }
            let device = devices.remove(at: index)
            log.debug("USB device disconnected: \(device.description, privacy: .public)")
            onDisconnected?(device)
        }
    }
}
