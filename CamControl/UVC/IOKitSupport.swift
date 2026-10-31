//
//  IOKitSupport.swift
//  Helpers for working with IOKit: registry property access and creation
//  of the user-space COM interface for a USB device.
//

import Foundation
import IOKit
import IOKit.usb

// MARK: - Plug-in interface UUIDs
//
// IOUSBLib.h defines these UUIDs as function-like macros, which are not
// visible to Swift; the byte sequences below are copied from that header.
// Like the macros, each access resolves the constant UUID anew — CFUUID is
// not Sendable, so the values cannot be stored in globals under strict
// concurrency checking.

/// Type of the user client plug-in for a USB device (kIOUSBDeviceUserClientTypeID).
var kIOUSBDeviceUserClientTypeID: CFUUID {
    CFUUIDGetConstantUUIDWithBytes(nil,
        0x9d, 0xc7, 0xb7, 0x80, 0x9e, 0xc0, 0x11, 0xD4,
        0xa5, 0x4f, 0x00, 0x0a, 0x27, 0x05, 0x28, 0x61)
}

/// USB device interface v9.4.2 (kIOUSBDeviceInterfaceID942), matching the
/// `IOUSBDeviceInterface942` vtable struct.
var kIOUSBDeviceInterfaceID942: CFUUID {
    CFUUIDGetConstantUUIDWithBytes(kCFAllocatorSystemDefault,
        0x56, 0xAD, 0x08, 0x9D, 0x87, 0x8D, 0x4B, 0xEA,
        0xA1, 0xF5, 0x2C, 0x8D, 0xC4, 0x3E, 0x8A, 0x98)
}

/// Generic IOCFPlugIn interface (kIOCFPlugInInterfaceID).
var kIOCFPlugInInterfaceID: CFUUID {
    CFUUIDGetConstantUUIDWithBytes(nil,
        0xC2, 0x44, 0xE8, 0x58, 0x10, 0x9C, 0x11, 0xD4,
        0x91, 0xD4, 0x00, 0x50, 0xE4, 0xC6, 0x42, 0x6F)
}

// MARK: - USB device interface

/// A USB device's user-space COM interface: a pointer to a pointer to the
/// function table. COM methods are called as
/// `intf.pointee!.pointee.Method(intf, …)`.
typealias USBDeviceInterfaceRef = UnsafeMutablePointer<UnsafeMutablePointer<IOUSBDeviceInterface942>?>

/// Obtains the user-space device interface for a USB device service, or
/// `nil` if the service does not provide one (e.g. USB controllers).
///
/// The caller owns one reference to the returned interface and must
/// balance it with `Release`.
func usbDeviceInterface(for service: io_service_t) -> USBDeviceInterfaceRef? {
    var pluginRef: UnsafeMutablePointer<UnsafeMutablePointer<IOCFPlugInInterface>?>?
    var score: Int32 = 0
    guard IOCreatePlugInInterfaceForService(service,
              kIOUSBDeviceUserClientTypeID, kIOCFPlugInInterfaceID,
              &pluginRef, &score) == kIOReturnSuccess,
          let plugin = pluginRef
    else { return nil }
    defer { _ = plugin.pointee!.pointee.Release(plugin) }

    var raw: UnsafeMutableRawPointer?
    guard plugin.pointee!.pointee.QueryInterface(plugin,
              CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID942), &raw) == S_OK,
          let raw
    else { return nil }
    return raw.assumingMemoryBound(to: UnsafeMutablePointer<IOUSBDeviceInterface942>?.self)
}

// MARK: - Registry properties

/// Reads a property of a registry entry, converting it to the inferred
/// Swift type (e.g. `String` for CFString, `Int` for CFNumber properties).
/// Returns `nil` if the property is missing or has a different type.
func ioRegistryProperty<T>(of service: io_service_t, key: String) -> T? {
    guard let value = IORegistryEntryCreateCFProperty(
            service, key as CFString, kCFAllocatorDefault, 0)?
        .takeRetainedValue()
    else { return nil }
    return value as? T
}
