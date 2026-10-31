//
//  CameraDescriptor.swift
//  Parses a USB configuration descriptor for the UVC entities the app
//  controls: the VideoControl interface, the processing unit and the
//  camera terminal.
//
//  Layouts follow "USB Device Class Definition for Video Devices" (UVC 1.5),
//  sections 3.7.2 (VC interface header), 3.7.2.3 (camera terminal) and
//  3.7.2.5 (processing unit). Field names from the spec are used throughout
//  so offsets stay cross-checkable against the standard.
//

/// Cursor over raw descriptor bytes. All USB multi-byte fields are
/// little-endian. Callers are responsible for bounds checks; offsets
/// outside `bytes` trap.
struct DescriptorReader {
    let bytes: [UInt8]

    func u8(_ offset: Int) -> UInt8 { bytes[offset] }

    func u16(_ offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }

    /// 24-bit little-endian bitmap field (e.g. a 3-byte `bmControls`).
    func u24(_ offset: Int) -> UInt32 {
        UInt32(bytes[offset]) | (UInt32(bytes[offset + 1]) << 8) | (UInt32(bytes[offset + 2]) << 16)
    }
}

/// The UVC-relevant parts of a camera's configuration descriptor.
///
/// If the configuration contains no VideoControl interface,
/// `interfaceNumber` stays `-1`; if the interface lacks a processing unit
/// or camera terminal, the respective ID stays `0xff` and its control
/// bitmap stays `0`.
struct CameraDescriptor {
    /// bInterfaceNumber of the VideoControl interface, or -1 if none found.
    private(set) var interfaceNumber: Int = -1
    /// bUnitID of the processing unit, or 0xff if none found.
    private(set) var processingUnitID: UInt8 = 0xff
    /// bmControls bitmap of the processing unit (UVC 1.5, table 3-8).
    private(set) var processingUnitControls: UInt32 = 0
    /// bTerminalID of the camera terminal, or 0xff if none found.
    private(set) var cameraTerminalID: UInt8 = 0xff
    /// bmControls bitmap of the camera terminal (UVC 1.5, table 3-6).
    private(set) var cameraTerminalControls: UInt32 = 0

    /// True if the device is a camera the app can control: it has a
    /// VideoControl interface, and that interface exposes a processing unit
    /// or a camera terminal to address controls on.
    var isControllableCamera: Bool {
        interfaceNumber != -1 && (processingUnitID != 0xff || cameraTerminalID != 0xff)
    }

    // Offsets into a standard interface descriptor (USB 3.2, table 9-24).
    private enum InterfaceDesc {
        static let bInterfaceNumber = 2
        static let bInterfaceClass = 5
        static let bInterfaceSubClass = 6
        static let length = 9
    }

    // Offsets into the class-specific VC interface header (UVC 1.5, 3.7.2).
    private enum VCHeaderDesc {
        static let wTotalLength = 5
        static let minLength = 12
    }

    // Offsets into an input terminal descriptor; the trailing fields exist
    // only in its camera terminal variant (UVC 1.5, 3.7.2.1 and 3.7.2.3).
    private enum InputTerminalDesc {
        static let bTerminalID = 3
        static let wTerminalType = 4
        static let bmControls = 15
        static let cameraMinLength = 18
    }

    // Offsets into a processing unit descriptor (UVC 1.5, 3.7.2.5).
    private enum ProcessingUnitDesc {
        static let bUnitID = 3
        static let bmControls = 8
        static let minLength = 11
    }

    init(configurationDescriptor: [UInt8]) {
        parse(DescriptorReader(bytes: configurationDescriptor))
    }

    /// Walks all descriptors in the configuration, looking for a
    /// VideoControl interface.
    private mutating func parse(_ reader: DescriptorReader) {
        let end = reader.bytes.count
        var offset = 0

        // Every descriptor starts with bLength and bDescriptorType.
        while offset + 2 < end {
            let bLength = Int(reader.u8(offset))

            // A zero or overrunning bLength means the data is malformed;
            // stop rather than loop forever or read out of bounds.
            guard bLength > 0, offset + bLength <= end else { break }

            if reader.u8(offset + 1) == UVC.descriptorTypeInterface,
               bLength >= InterfaceDesc.length,
               reader.u8(offset + InterfaceDesc.bInterfaceClass) == UVC.classVideo,
               reader.u8(offset + InterfaceDesc.bInterfaceSubClass) == UVC.subclassVideoControl {
                parseVideoControlInterface(reader, at: offset)
            }

            offset += bLength
        }
    }

    /// Parses the class-specific descriptors following the VideoControl
    /// interface descriptor at `interfaceOffset`.
    private mutating func parseVideoControlInterface(_ reader: DescriptorReader, at interfaceOffset: Int) {
        let end = reader.bytes.count

        // The class-specific VC interface header immediately follows the
        // standard interface descriptor.
        var offset = interfaceOffset + Int(reader.u8(interfaceOffset))
        guard offset + VCHeaderDesc.minLength <= end,
              reader.u8(offset + 1) == UVC.descriptorTypeCSInterface,
              reader.u8(offset + 2) == UVC.vcHeader
        else { return }

        // wTotalLength covers the header plus all unit and terminal
        // descriptors of the VideoControl interface.
        let vcEnd = offset + Int(reader.u16(offset + VCHeaderDesc.wTotalLength))
        guard vcEnd <= end else { return }

        interfaceNumber = Int(reader.u8(interfaceOffset + InterfaceDesc.bInterfaceNumber))

        offset += Int(reader.u8(offset))

        // Iterate the unit and terminal descriptors. wTotalLength bounds
        // the walk, but some devices understate it slightly, so a trailing
        // descriptor may extend a few bytes past vcEnd; reads are therefore
        // bounded by the buffer, not by vcEnd.
        while offset + 2 < vcEnd {
            let bLength = Int(reader.u8(offset))
            guard bLength > 0, offset + bLength <= end else { break }

            if reader.u8(offset + 1) == UVC.descriptorTypeCSInterface {
                switch reader.u8(offset + 2) {
                case UVC.vcInputTerminal:
                    if bLength >= InputTerminalDesc.cameraMinLength,
                       reader.u16(offset + InputTerminalDesc.wTerminalType) == UVC.terminalTypeCamera {
                        cameraTerminalID = reader.u8(offset + InputTerminalDesc.bTerminalID)
                        cameraTerminalControls = reader.u24(offset + InputTerminalDesc.bmControls)
                    }
                case UVC.vcProcessingUnit:
                    if bLength >= ProcessingUnitDesc.minLength {
                        processingUnitID = reader.u8(offset + ProcessingUnitDesc.bUnitID)
                        processingUnitControls = reader.u24(offset + ProcessingUnitDesc.bmControls)
                    }
                default:
                    break
                }
            }

            offset += bLength
        }
    }
}
