//
//  CameraDescriptorTests.swift
//  Tests for the configuration descriptor parser, using a descriptor
//  captured from a real camera plus synthetic descriptors for edge cases.
//  Expected values for the captured descriptor were decoded by hand from
//  the raw bytes (offsets per UVC 1.5, sections 3.7.2.3 and 3.7.2.5).
//

import Testing

// MARK: - Synthetic descriptor building blocks

/// Standard interface descriptor (9 bytes).
private func interfaceDescriptor(number: UInt8, class cls: UInt8, subclass: UInt8) -> [UInt8] {
    [9, 0x04, number, 0, 0, cls, subclass, 0, 0]
}

/// Class-specific VC interface header (12 bytes, no baInterfaceNr entries).
/// `totalLength` covers the header and everything through the last unit.
private func vcHeader(totalLength: UInt16) -> [UInt8] {
    [12, 0x24, 0x01, 0x00, 0x01, UInt8(totalLength & 0xff), UInt8(totalLength >> 8), 0, 0, 0, 0, 0]
}

/// Input terminal descriptor in its camera terminal variant (18 bytes).
private func cameraTerminal(id: UInt8, controls: UInt32) -> [UInt8] {
    [18, 0x24, 0x02, id, 0x01, 0x02, 0, 0, 0, 0, 0, 0, 0, 0, 3,
     UInt8(controls & 0xff), UInt8((controls >> 8) & 0xff), UInt8((controls >> 16) & 0xff)]
}

/// Processing unit descriptor (11 bytes, 3-byte bmControls, UVC 1.0 layout).
private func processingUnit(id: UInt8, controls: UInt32) -> [UInt8] {
    [11, 0x24, 0x05, id, 0x01, 0, 0, 3,
     UInt8(controls & 0xff), UInt8((controls >> 8) & 0xff), UInt8((controls >> 16) & 0xff)]
}

/// Wraps interface-level descriptors in a configuration descriptor (9 bytes
/// of header, wTotalLength filled in).
private func configuration(_ parts: [[UInt8]]) -> [UInt8] {
    let body = parts.flatMap { $0 }
    let total = UInt16(9 + body.count)
    return [9, 0x02, UInt8(total & 0xff), UInt8(total >> 8), 1, 1, 0, 0x80, 50] + body
}

/// A well-formed configuration with a VideoControl interface, camera
/// terminal 1 and processing unit 3.
private func syntheticCameraConfiguration() -> [UInt8] {
    let units = cameraTerminal(id: 1, controls: 0x00000a2e) + processingUnit(id: 3, controls: 0x0000175b)
    return configuration([
        interfaceDescriptor(number: 0, class: 0x0e, subclass: 0x01),
        vcHeader(totalLength: UInt16(12 + units.count)),
        units,
    ])
}

// MARK: - Tests

struct CameraDescriptorTests {
    @Test func parsesCapturedDellWB7022Descriptor() {
        let desc = CameraDescriptor(configurationDescriptor: dellWB7022ConfigurationDescriptor)
        #expect(desc.interfaceNumber == 0)
        #expect(desc.processingUnitID == 0x03)
        #expect(desc.processingUnitControls == 0x00175b)
        #expect(desc.cameraTerminalID == 0x01)
        #expect(desc.cameraTerminalControls == 0x020a2e)
    }

    @Test func parsesSyntheticCameraConfiguration() {
        let desc = CameraDescriptor(configurationDescriptor: syntheticCameraConfiguration())
        #expect(desc.interfaceNumber == 0)
        #expect(desc.processingUnitID == 3)
        #expect(desc.processingUnitControls == 0x175b)
        #expect(desc.cameraTerminalID == 1)
        #expect(desc.cameraTerminalControls == 0x0a2e)
    }

    @Test func emptyDataYieldsDefaults() {
        let desc = CameraDescriptor(configurationDescriptor: [])
        #expect(desc.interfaceNumber == -1)
        #expect(desc.processingUnitID == 0xff)
        #expect(desc.processingUnitControls == 0)
        #expect(desc.cameraTerminalID == 0xff)
        #expect(desc.cameraTerminalControls == 0)
    }

    @Test func nonVideoConfigurationYieldsDefaults() {
        let config = configuration([
            interfaceDescriptor(number: 0, class: 0x03, subclass: 0x01),  // HID
        ])
        let desc = CameraDescriptor(configurationDescriptor: config)
        #expect(desc.interfaceNumber == -1)
        #expect(desc.cameraTerminalID == 0xff)
        #expect(desc.processingUnitID == 0xff)
    }

    @Test func videoControlInterfaceWithoutUnitsKeepsUnitDefaults() {
        let config = configuration([
            interfaceDescriptor(number: 2, class: 0x0e, subclass: 0x01),
            vcHeader(totalLength: 12),
        ])
        let desc = CameraDescriptor(configurationDescriptor: config)
        #expect(desc.interfaceNumber == 2)
        #expect(desc.processingUnitID == 0xff)
        #expect(desc.processingUnitControls == 0)
        #expect(desc.cameraTerminalID == 0xff)
        #expect(desc.cameraTerminalControls == 0)
    }

    @Test func missingVCHeaderIsRejected() {
        // A VideoControl interface followed by a camera terminal but no
        // VC_HEADER descriptor: the interface must not be accepted.
        let config = configuration([
            interfaceDescriptor(number: 0, class: 0x0e, subclass: 0x01),
            cameraTerminal(id: 1, controls: 0x0a2e),
        ])
        let desc = CameraDescriptor(configurationDescriptor: config)
        #expect(desc.interfaceNumber == -1)
        #expect(desc.cameraTerminalID == 0xff)
    }

    @Test func nonCameraInputTerminalIsIgnored() {
        var terminal = cameraTerminal(id: 1, controls: 0x0a2e)
        terminal[4] = 0x00  // wTerminalType 0x0200: ITT_VENDOR_SPECIFIC
        terminal[5] = 0x02
        let config = configuration([
            interfaceDescriptor(number: 0, class: 0x0e, subclass: 0x01),
            vcHeader(totalLength: UInt16(12 + terminal.count)),
            terminal,
        ])
        let desc = CameraDescriptor(configurationDescriptor: config)
        #expect(desc.interfaceNumber == 0)
        #expect(desc.cameraTerminalID == 0xff)
        #expect(desc.cameraTerminalControls == 0)
    }

    @Test func overrunningTotalLengthIsRejected() {
        // wTotalLength claims more VC data than the buffer holds.
        var config = syntheticCameraConfiguration()
        config.removeLast(8)
        let desc = CameraDescriptor(configurationDescriptor: config)
        #expect(desc.interfaceNumber == -1)
        #expect(desc.cameraTerminalID == 0xff)
        #expect(desc.processingUnitID == 0xff)
    }

    @Test func truncatedCapturedDescriptorYieldsDefaults() {
        // Cutting the captured descriptor inside the VideoControl section
        // invalidates its wTotalLength, so nothing must be parsed.
        let truncated = Array(dellWB7022ConfigurationDescriptor.prefix(60))
        let desc = CameraDescriptor(configurationDescriptor: truncated)
        #expect(desc.interfaceNumber == -1)
        #expect(desc.cameraTerminalID == 0xff)
        #expect(desc.processingUnitID == 0xff)
    }

    @Test func zeroLengthDescriptorTerminatesParsing() {
        // A bLength of 0 must stop the walk instead of looping forever.
        var config = syntheticCameraConfiguration()
        config[9] = 0  // zero out the interface descriptor's bLength
        let desc = CameraDescriptor(configurationDescriptor: config)
        #expect(desc.interfaceNumber == -1)
    }

    @Test func descriptorLengthOverrunningBufferStopsParsing() {
        // A bLength pointing past the end of the buffer must stop the walk.
        var config = syntheticCameraConfiguration()
        config[9] = 0xff  // interface descriptor claims 255 bytes
        let desc = CameraDescriptor(configurationDescriptor: config)
        #expect(desc.interfaceNumber == -1)
    }

    @Test func undersizedUnitDescriptorsAreIgnored() {
        // Units whose bLength is too small to contain their bmControls
        // bitmap must be skipped, not read out of bounds.
        var terminal = cameraTerminal(id: 1, controls: 0x0a2e)
        terminal.removeLast(4)
        terminal[0] = UInt8(terminal.count)
        var unit = processingUnit(id: 3, controls: 0x175b)
        unit.removeLast(4)
        unit[0] = UInt8(unit.count)
        let units = terminal + unit
        let config = configuration([
            interfaceDescriptor(number: 0, class: 0x0e, subclass: 0x01),
            vcHeader(totalLength: UInt16(12 + units.count)),
            units,
        ])
        let desc = CameraDescriptor(configurationDescriptor: config)
        #expect(desc.interfaceNumber == 0)
        #expect(desc.cameraTerminalID == 0xff)
        #expect(desc.processingUnitID == 0xff)
    }

    // MARK: - Controllability (the admission test for a USB camera)

    @Test func realCameraIsControllable() {
        let desc = CameraDescriptor(configurationDescriptor: dellWB7022ConfigurationDescriptor)
        #expect(desc.isControllableCamera)
    }

    @Test func oneUnitIsEnoughToBeControllable() {
        // A VideoControl interface with only a processing unit still has controls to set.
        let units = processingUnit(id: 3, controls: 0x0000175b)
        let config = configuration([
            interfaceDescriptor(number: 0, class: 0x0e, subclass: 0x01),
            vcHeader(totalLength: UInt16(12 + units.count)),
            units,
        ])
        let desc = CameraDescriptor(configurationDescriptor: config)
        #expect(desc.isControllableCamera)
    }

    @Test func nonVideoDeviceIsNotControllable() {
        let config = configuration([
            interfaceDescriptor(number: 0, class: 0x03, subclass: 0x01),  // HID
        ])
        #expect(!CameraDescriptor(configurationDescriptor: config).isControllableCamera)
    }

    @Test func videoControlInterfaceWithoutUnitsIsNotControllable() {
        // Nothing to address controls on: no processing unit, no camera terminal.
        let config = configuration([
            interfaceDescriptor(number: 2, class: 0x0e, subclass: 0x01),
            vcHeader(totalLength: 12),
        ])
        #expect(!CameraDescriptor(configurationDescriptor: config).isControllableCamera)
    }
}
