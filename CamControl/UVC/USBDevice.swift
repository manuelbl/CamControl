//
//  USBDevice.swift
//  A USB device: identity properties, raw configuration descriptor,
//  open/close, and control transfers on the default control endpoint.
//

import Foundation
import IOKit
import IOKit.usb

// MARK: - Control requests

/// Direction of a control request (bmRequestType bit 7).
enum USBRequestDirection: UInt8 {
    /// Host to device
    case out = 0x00
    /// Device to host
    case `in` = 0x80
}

/// Type of a control request (bmRequestType bits 6..5).
enum USBRequestKind: UInt8 {
    /// Standard request
    case standard = 0x00
    /// Class-specific request
    case `class` = 0x20
    /// Vendor-defined request
    case vendor = 0x40
}

/// Recipient of a control request (bmRequestType bits 4..0).
enum USBRequestRecipient: UInt8 {
    /// Device
    case device = 0x00
    /// Interface
    case interface = 0x01
    /// Endpoint
    case endpoint = 0x02
    /// Other recipient
    case other = 0x03
}

/// A USB control request (USB 3.2, 9.3), sent to endpoint 0.
struct USBControlRequest {
    /// Request type (combination of direction, type and recipient bits)
    var bmRequestType: UInt8
    /// Specific request number
    var bRequest: UInt8
    /// Value (request specific)
    var wValue: UInt16
    /// Index (request specific)
    var wIndex: UInt16
    /// Number of bytes to transfer if there is a data phase
    var wLength: UInt16

    /// Combines the direction, type and recipient bit groups into a
    /// `bmRequestType` value.
    static func requestType(direction: USBRequestDirection,
                            type: USBRequestKind,
                            recipient: USBRequestRecipient) -> UInt8 {
        direction.rawValue | type.rawValue | recipient.rawValue
    }
}

/// Error code for a timed-out USB transaction. IOUSBLib defines this as a
/// function-like macro — `iokit_usb_err(0x51)` — which is not visible to
/// Swift; this is the expanded value.
let kIOUSBTransactionTimeout = IOReturn(bitPattern: 0xe0004051)

// MARK: - Device

/// A USB device, created from its IOKit service.
///
/// The instance owns the single reference to the device's user-space COM
/// interface and releases it on deinitialization (closing the device first
/// if needed).
///
/// Not Sendable by design: instances are handed from the registry queue to
/// the UVC serial queue and must only be used from one queue at a time.
final class USBDevice: CustomStringConvertible {
    private let intf: USBDeviceInterfaceRef

    /// IOKit registry entry ID, unique per device connection.
    let entryID: UInt64
    /// USB vendor ID
    let vendorID: Int
    /// USB product ID
    let productID: Int
    /// USB location ID, encoding the physical port path.
    let locationID: Int
    /// Manufacturer name
    let manufacturer: String
    /// Product name
    let product: String
    /// Serial number
    let serialNumber: String
    /// Raw configuration descriptor bytes (empty if the descriptor could
    /// not be read).
    let configurationDescriptor: [UInt8]
    /// Indicates if the device is open
    private(set) var isOpen = false

    /// Creates a device for a USB device service.
    ///
    /// Fails for services that are not regular devices: USB controllers
    /// provide no user client interface and report no VID/PID.
    init?(service: io_service_t) {
        guard let intf = usbDeviceInterface(for: service) else { return nil }

        let vendorID: Int = ioRegistryProperty(of: service, key: kUSBVendorID) ?? 0
        let productID: Int = ioRegistryProperty(of: service, key: kUSBProductID) ?? 0
        var entryID: UInt64 = 0
        guard vendorID != 0, productID != 0,
              IORegistryEntryGetRegistryEntryID(service, &entryID) == KERN_SUCCESS
        else {
            _ = intf.pointee!.pointee.Release(intf)
            return nil
        }

        self.intf = intf
        self.entryID = entryID
        self.vendorID = vendorID
        self.productID = productID
        self.locationID = ioRegistryProperty(of: service, key: kUSBDevicePropertyLocationID) ?? 0
        self.manufacturer = ioRegistryProperty(of: service, key: kUSBVendorString) ?? ""
        self.product = ioRegistryProperty(of: service, key: kUSBProductString) ?? ""
        self.serialNumber = ioRegistryProperty(of: service, key: kUSBSerialNumberString) ?? ""

        var desc: IOUSBConfigurationDescriptorPtr?
        if intf.pointee!.pointee.GetConfigurationDescriptorPtr(intf, 0, &desc) == kIOReturnSuccess,
           let desc {
            let total = Int(UInt16(littleEndian: desc.pointee.wTotalLength))
            configurationDescriptor = [UInt8](UnsafeRawBufferPointer(start: desc, count: total))
        } else {
            configurationDescriptor = []
        }
    }

    deinit {
        try? close()
        _ = intf.pointee!.pointee.Release(intf)
    }

    /// Port-independent identity of the device (vendor ID, product ID and
    /// serial number) — the key camera profiles are stored under (ADR-0002).
    var persistenceKey: String {
        String(format: "%04x-%04x-%@", vendorID, productID, serialNumber)
    }

    /// Descriptive string including VID, PID, manufacturer, product name
    /// and serial number.
    var description: String {
        String(format: "VID: 0x%04x, PID: 0x%04x, manufacturer: %@, product: %@, serial: %@",
               vendorID, productID, manufacturer, product, serialNumber)
    }

    // MARK: Open / close

    /// Opens the device for communication and selects configuration 1.
    ///
    /// A freshly attached device may still be held exclusively while the
    /// system probes it, so opening is retried a few times.
    func open() throws {
        guard !isOpen else {
            throw USBError(message: "USB device is already open")
        }

        var ret = kIOReturnSuccess
        for _ in 0 ..< 3 {
            ret = intf.pointee!.pointee.USBDeviceOpen(intf)
            if ret != kIOReturnExclusiveAccess { break }
            usleep(5_000)
        }
        try USBError.check(ret, "unable to open USB device")

        try USBError.check(intf.pointee!.pointee.SetConfiguration(intf, 1),
                           "failed to set USB device configuration")

        isOpen = true
    }

    /// Closes the device. Does nothing if the device is not open.
    func close() throws {
        guard isOpen else { return }

        let ret = intf.pointee!.pointee.USBDeviceClose(intf)
        // kIOReturnNoDevice means the device is already gone (unplugged);
        // it counts as closed.
        if ret != kIOReturnSuccess && ret != kIOReturnNoDevice {
            throw USBError(message: "unable to close USB device", code: ret)
        }

        isOpen = false
    }

    // MARK: Control transfers

    /// Sends a control request with no data phase.
    ///
    /// - Parameters:
    ///   - request: request to send (`wLength` must be 0)
    ///   - timeout: timeout in ms, 0 for no timeout
    func controlTransfer(_ request: USBControlRequest, timeout: Int = 0) throws {
        guard request.wLength == 0 else {
            throw USBError(message: "'controlTransfer' only supports requests without data phase but 'wLength' != 0")
        }
        try controlTransferCore(request, data: nil, timeout: timeout)
    }

    /// Sends a control request with a DATA OUT phase.
    ///
    /// - Parameters:
    ///   - request: request to send (`request.wLength` and `data.count` must be equal)
    ///   - data: data to send in the DATA phase
    ///   - timeout: timeout in ms, 0 for no timeout
    func controlTransferOut(_ request: USBControlRequest, data: [UInt8], timeout: Int = 0) throws {
        guard request.bmRequestType & 0x80 == 0 else {
            throw USBError(message: "direction mismatch between 'controlTransferOut' and direction bit in 'bmRequestType'")
        }
        var data = data
        try data.withUnsafeMutableBytes {
            try controlTransferCore(request, data: $0.baseAddress, timeout: timeout)
        }
    }

    /// Sends a control request with a DATA IN phase.
    ///
    /// The result always contains `request.wLength` bytes; if the device
    /// sends fewer, the remaining bytes are zero.
    ///
    /// - Parameters:
    ///   - request: request to send
    ///   - timeout: timeout in ms, 0 for no timeout
    /// - Returns: received data
    func controlTransferIn(_ request: USBControlRequest, timeout: Int = 0) throws -> [UInt8] {
        guard request.bmRequestType & 0x80 != 0 else {
            throw USBError(message: "direction mismatch between 'controlTransferIn' and direction bit in 'bmRequestType'")
        }
        var data = [UInt8](repeating: 0, count: Int(request.wLength))
        try data.withUnsafeMutableBytes {
            try controlTransferCore(request, data: $0.baseAddress, timeout: timeout)
        }
        return data
    }

    private func controlTransferCore(_ request: USBControlRequest,
                                     data: UnsafeMutableRawPointer?,
                                     timeout: Int) throws {
        guard isOpen else {
            throw USBError(message: "USB device is not open")
        }

        var req = IOUSBDevRequestTO(
            bmRequestType: request.bmRequestType,
            bRequest: request.bRequest,
            wValue: request.wValue,
            wIndex: request.wIndex,
            wLength: request.wLength,
            pData: data,
            wLenDone: 0,
            noDataTimeout: UInt32(timeout),
            completionTimeout: UInt32(timeout))

        // Without a timeout, the request must go through DeviceRequest;
        // IOUSBDevRequest is the same struct minus the trailing timeout
        // fields, so the pointer can be rebound.
        let ret = timeout != 0
            ? intf.pointee!.pointee.DeviceRequestTO(intf, &req)
            : withUnsafeMutablePointer(to: &req) {
                  $0.withMemoryRebound(to: IOUSBDevRequest.self, capacity: 1) {
                      intf.pointee!.pointee.DeviceRequest(intf, $0)
                  }
              }

        if ret == kIOUSBTransactionTimeout {
            throw USBError(message: "time-out sending control request", code: ret)
        }
        try USBError.check(ret, "error sending control request")
    }
}
