//
//  UVCVideoDevice.swift
//  Controller for a USB device supporting the USB Video Class (UVC).
//

import Foundation
import os

private let log = Logger(subsystem: "net.codecrete.CamControl", category: "UVCVideoDevice")

/// Controller for a USB device supporting the USB Video Class (UVC).
///
/// Instances of this class are not thread-safe, and the methods for querying
/// and setting camera settings (processing unit and camera terminal controls)
/// are blocking. ``USBCameraService`` is the sole owner: it creates at most
/// one instance per physical connection and confines it to its serial
/// executor.
///
/// Errors communicating with the device are logged, not thrown: getters
/// return 0 and setters do nothing when a request fails.
final class UVCVideoDevice {
    private let device: USBDevice
    private let interfaceNumber: Int
    private let processingUnitID: UInt8
    private let processingUnitControls: UInt32
    private let cameraTerminalID: UInt8
    private let cameraTerminalControls: UInt32

    /// Opens a USB device for UVC communication.
    ///
    /// The descriptor is passed in because its parse — which decides whether
    /// the device is a controllable camera at all
    /// (``CameraDescriptor/isControllableCamera``) — needs no open device and
    /// has already happened by the time a camera is admitted.
    ///
    /// Fails if the device cannot be opened.
    init?(device: USBDevice, descriptor: CameraDescriptor) {
        log.info("Supported PU controls: 0x\(String(format: "%06x", descriptor.processingUnitControls), privacy: .public)")
        log.info("Supported camera controls: 0x\(String(format: "%06x", descriptor.cameraTerminalControls), privacy: .public)")

        do {
            try device.open()
            log.debug("USB device opened")
        } catch {
            log.error("Failed to open USB device: \(error, privacy: .public)")
            return nil
        }

        self.device = device
        self.interfaceNumber = descriptor.interfaceNumber
        self.processingUnitID = descriptor.processingUnitID
        self.processingUnitControls = descriptor.processingUnitControls
        self.cameraTerminalID = descriptor.cameraTerminalID
        self.cameraTerminalControls = descriptor.cameraTerminalControls
    }

    /// Closes the USB device. Called when the camera detaches — never from
    /// `deinit`: the registry keeps the `USBDevice` alive across wrappers, so
    /// closing on release would close a device another user may still hold.
    func close() {
        do {
            try device.close()
            log.debug("USB device closed")
        } catch {
            log.error("Failed to close USB device: \(error, privacy: .public)")
        }
    }

    // MARK: - Control availability

    /// Indicates if the specified processing unit control is available.
    func hasPUControl(_ control: PUControl) -> Bool {
        processingUnitControls & control.supportBit != 0
    }

    /// Indicates if the specified camera terminal control is available.
    func hasCTControl(_ control: CTControl) -> Bool {
        cameraTerminalControls & control.supportBit != 0
    }

    // MARK: - Getting, setting and resetting controls

    /// Gets the value of a processing unit control.
    ///
    /// - Parameters:
    ///   - control: the processing unit control
    ///   - aspect: the control aspect (current, minimum, maximum, …)
    ///   - dataType: the control's data type
    /// - Returns: the value as an integer number, or 0 if the request failed
    func intValue(ofPUControl control: PUControl, aspect: VideoControlAspect,
                  dataType: VideoControlDataType) -> Int64 {
        intValue(of: .processingUnit, selector: control.rawValue, aspect: aspect, dataType: dataType)
    }

    /// Gets the value of a camera terminal control.
    ///
    /// - Parameters:
    ///   - control: the camera terminal control
    ///   - aspect: the control aspect (current, minimum, maximum, …)
    ///   - dataType: the control's data type
    /// - Returns: the value as an integer number, or 0 if the request failed
    func intValue(ofCTControl control: CTControl, aspect: VideoControlAspect,
                  dataType: VideoControlDataType) -> Int64 {
        intValue(of: .cameraTerminal, selector: control.rawValue, aspect: aspect, dataType: dataType)
    }

    /// Sets the current value of a processing unit control.
    func setValue(_ value: Int64, ofPUControl control: PUControl, dataType: VideoControlDataType) {
        setValue(value, of: .processingUnit, selector: control.rawValue, dataType: dataType)
    }

    /// Sets the current value of a camera terminal control.
    func setValue(_ value: Int64, ofCTControl control: CTControl, dataType: VideoControlDataType) {
        setValue(value, of: .cameraTerminal, selector: control.rawValue, dataType: dataType)
    }

    /// Resets the current value of a processing unit control to its default
    /// value.
    func resetPUControl(_ control: PUControl, dataType: VideoControlDataType) {
        resetControl(of: .processingUnit, selector: control.rawValue, dataType: dataType)
    }

    /// Resets the current value of a camera terminal control to its default
    /// value.
    func resetCTControl(_ control: CTControl, dataType: VideoControlDataType) {
        resetControl(of: .cameraTerminal, selector: control.rawValue, dataType: dataType)
    }

    // MARK: - Control transfers

    /// The two UVC entities whose controls the app addresses.
    private enum ControlUnit: String {
        case processingUnit = "PU"
        case cameraTerminal = "CT"
    }

    private func unitID(_ unit: ControlUnit) -> UInt8 {
        switch unit {
        case .processingUnit: processingUnitID
        case .cameraTerminal: cameraTerminalID
        }
    }

    /// Builds the class-specific control request addressing a control of a
    /// VideoControl entity (UVC 1.5, 4.2.1: the selector goes into the high
    /// byte of `wValue`, entity ID and interface number into `wIndex`).
    private func controlRequest(direction: USBRequestDirection, bRequest: UInt8,
                                unit: ControlUnit, selector: UInt8, length: Int) -> USBControlRequest {
        USBControlRequest(
            bmRequestType: USBControlRequest.requestType(
                direction: direction, type: .class, recipient: .interface),
            bRequest: bRequest,
            wValue: UInt16(selector) << 8,
            wIndex: UInt16(unitID(unit)) << 8 | UInt16(interfaceNumber),
            wLength: UInt16(length))
    }

    private func intValue(of unit: ControlUnit, selector: UInt8,
                          aspect: VideoControlAspect, dataType: VideoControlDataType) -> Int64 {
        do {
            log.debug("Reading \(unit.rawValue, privacy: .public) control \(selector) aspect \(aspect.rawValue)...")
            let request = controlRequest(direction: .in, bRequest: aspect.rawValue,
                                         unit: unit, selector: selector, length: dataType.byteCount)
            let data = try device.controlTransferIn(request)
            let value = dataType.decode(data)
            log.debug("Read \(unit.rawValue, privacy: .public) control \(selector) aspect \(aspect.rawValue); value = \(value)")
            return value

        } catch {
            log.error("Unable to get aspect \(aspect.rawValue) of \(unit.rawValue, privacy: .public) control \(selector) – \(error, privacy: .public)")
            return 0
        }
    }

    private func setValue(_ value: Int64, of unit: ControlUnit, selector: UInt8,
                          dataType: VideoControlDataType) {
        do {
            log.debug("Setting \(unit.rawValue, privacy: .public) control \(selector) to \(value)...")
            let data = dataType.encode(value)
            let request = controlRequest(direction: .out, bRequest: UVC.setCur,
                                         unit: unit, selector: selector, length: data.count)
            try device.controlTransferOut(request, data: data)
            log.debug("Set \(unit.rawValue, privacy: .public) control \(selector) to \(value)")

        } catch {
            log.error("Unable to set \(unit.rawValue, privacy: .public) control \(selector) to \(value) – \(error, privacy: .public)")
        }
    }

    /// Resets a control to its default value by reading the default
    /// (GET_DEF) and writing it back as the current value (SET_CUR).
    private func resetControl(of unit: ControlUnit, selector: UInt8, dataType: VideoControlDataType) {
        do {
            log.debug("Resetting \(unit.rawValue, privacy: .public) control \(selector)...")
            let getDefault = controlRequest(direction: .in, bRequest: UVC.getDef,
                                            unit: unit, selector: selector, length: dataType.byteCount)
            let data = try device.controlTransferIn(getDefault)

            let setCurrent = controlRequest(direction: .out, bRequest: UVC.setCur,
                                            unit: unit, selector: selector, length: data.count)
            try device.controlTransferOut(setCurrent, data: data)
            log.debug("Reset \(unit.rawValue, privacy: .public) control \(selector)")

        } catch {
            log.error("Unable to reset \(unit.rawValue, privacy: .public) control \(selector) – \(error, privacy: .public)")
        }
    }
}
