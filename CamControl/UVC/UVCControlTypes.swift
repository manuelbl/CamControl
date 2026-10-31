//
//  UVCControlTypes.swift
//  Control selector and value-type enums for the UVC control surface.
//
//  Raw values are the control selectors / request codes from "USB Device Class
//  Definition for Video Devices" (UVC 1.5).
//

/// Processing Unit control selectors (UVC A.9.5, PU_*_CONTROL).
enum PUControl: UInt8, Sendable {
    case backlightCompensation = 0x01
    case brightness = 0x02
    case contrast = 0x03
    case gain = 0x04
    case powerLineFrequency = 0x05
    case hue = 0x06
    case saturation = 0x07
    case sharpness = 0x08
    case gamma = 0x09
    case whiteBalanceTemperature = 0x0A
    case whiteBalanceTemperatureAuto = 0x0B
    case whiteBalanceComponent = 0x0C
    case whiteBalanceComponentAuto = 0x0D
    case digitalMultiplier = 0x0E
    case digitalMultiplierLimit = 0x0F
    case hueAuto = 0x10
    case analogVideoStandard = 0x11
    case analogLockStatus = 0x12
    case contrastAuto = 0x13

    /// This control's bit in the processing unit descriptor's `bmControls`
    /// bitmap (UVC 3.7.2.5). Note the bitmap ordering differs from the
    /// selector ordering.
    var supportBit: UInt32 {
        switch self {
        case .brightness:                  0x0000_0001
        case .contrast:                    0x0000_0002
        case .hue:                         0x0000_0004
        case .saturation:                  0x0000_0008
        case .sharpness:                   0x0000_0010
        case .gamma:                       0x0000_0020
        case .whiteBalanceTemperature:     0x0000_0040
        case .whiteBalanceComponent:       0x0000_0080
        case .backlightCompensation:       0x0000_0100
        case .gain:                        0x0000_0200
        case .powerLineFrequency:          0x0000_0400
        case .hueAuto:                     0x0000_0800
        case .whiteBalanceTemperatureAuto: 0x0000_1000
        case .whiteBalanceComponentAuto:   0x0000_2000
        case .digitalMultiplier:           0x0000_4000
        case .digitalMultiplierLimit:      0x0000_8000
        case .analogVideoStandard:         0x0001_0000
        case .analogLockStatus:            0x0002_0000
        case .contrastAuto:                0x0004_0000
        }
    }
}

/// Camera Terminal control selectors (UVC A.9.4, CT_*_CONTROL).
enum CTControl: UInt8, Sendable {
    case scanningMode = 0x01
    case autoExposureMode = 0x02
    case autoExposurePriority = 0x03
    case exposureTimeAbsolute = 0x04
    case exposureTimeRelative = 0x05
    case focusAbsolute = 0x06
    case focusRelative = 0x07
    case focusAuto = 0x08
    case irisAbsolute = 0x09
    case irisRelative = 0x0A
    case zoomAbsolute = 0x0B
    case zoomRelative = 0x0C
    case panTiltAbsolute = 0x0D
    case panTiltRelative = 0x0E
    case rollAbsolute = 0x0F
    case rollRelative = 0x10
    case privacy = 0x11
    case focusSimple = 0x12
    case window = 0x13
    case regionOfInterest = 0x14

    /// This control's bit in the camera terminal descriptor's `bmControls`
    /// bitmap (UVC 3.7.2.3). Note `focusAuto` sits at bit 17, out of selector
    /// order.
    var supportBit: UInt32 {
        switch self {
        case .scanningMode:         0x0000_0001
        case .autoExposureMode:     0x0000_0002
        case .autoExposurePriority: 0x0000_0004
        case .exposureTimeAbsolute: 0x0000_0008
        case .exposureTimeRelative: 0x0000_0010
        case .focusAbsolute:        0x0000_0020
        case .focusRelative:        0x0000_0040
        case .irisAbsolute:         0x0000_0080
        case .irisRelative:         0x0000_0100
        case .zoomAbsolute:         0x0000_0200
        case .zoomRelative:         0x0000_0400
        case .panTiltAbsolute:      0x0000_0800
        case .panTiltRelative:      0x0000_1000
        case .rollAbsolute:         0x0000_2000
        case .rollRelative:         0x0000_4000
        case .focusAuto:            0x0002_0000
        case .privacy:              0x0004_0000
        case .focusSimple:          0x0008_0000
        case .window:               0x0010_0000
        case .regionOfInterest:     0x0020_0000
        }
    }
}

/// Which aspect of a control to query. Raw values are the UVC GET_* request
/// codes (UVC A.8), so an aspect can be used directly as `bRequest`.
enum VideoControlAspect: UInt8, Sendable {
    /// Current value (GET_CUR)
    case value = 0x81
    /// Minimum value (GET_MIN)
    case minimum = 0x82
    /// Maximum value (GET_MAX)
    case maximum = 0x83
    /// Step size (GET_RES)
    case resolution = 0x84
    /// Data length (GET_LEN)
    case length = 0x85
    /// Capability info bits (GET_INFO)
    case info = 0x86
    /// Default value (GET_DEF)
    case `default` = 0x87
}

/// Wire format of a control's value in the data stage.
enum VideoControlDataType: Int, Sendable {
    case uInt8 = 1
    case uInt16 = 2
    case sInt16 = 3
    case boolean = 4
    /// Two packed little-endian SInt32 values (e.g. Pan/Tilt Absolute).
    case sInt32Tuple = 5

    /// Number of bytes transferred in the data stage.
    var byteCount: Int {
        switch self {
        case .uInt8, .boolean: 1
        case .uInt16, .sInt16: 2
        case .sInt32Tuple: 8
        }
    }
}

// MARK: - Value marshalling

extension VideoControlDataType {
    /// Packs a control value into the little-endian wire format of this data type.
    func encode(_ value: Int64) -> [UInt8] {
        withUnsafeBytes(of: value.littleEndian) { Array($0.prefix(byteCount)) }
    }

    /// Unpacks a little-endian control value, sign-extending the signed types.
    /// `data` must hold at least `byteCount` bytes.
    func decode(_ data: [UInt8]) -> Int64 {
        switch self {
        case .uInt8, .boolean:
            Int64(data[0])
        case .uInt16:
            Int64(UInt16(data[0]) | UInt16(data[1]) << 8)
        case .sInt16:
            Int64(Int16(bitPattern: UInt16(data[0]) | UInt16(data[1]) << 8))
        case .sInt32Tuple:
            data.withUnsafeBytes { Int64(littleEndian: $0.loadUnaligned(as: Int64.self)) }
        }
    }

    /// Extracts a signed 32-bit axis from a packed `sInt32Tuple` value (axis 0 = low word /
    /// pan, axis 1 = high word / tilt), little-endian as the device marshals it.
    static func decompose(tuple: Int64, axis: Int) -> Int32 {
        let u = UInt64(bitPattern: tuple)
        let part = axis == 0 ? UInt32(truncatingIfNeeded: u) : UInt32(truncatingIfNeeded: u >> 32)
        return Int32(bitPattern: part)
    }

    /// Sets one signed 32-bit axis into a packed `sInt32Tuple` value, preserving the other axis.
    static func compose(into tuple: Int64, axis: Int, value: Int32) -> Int64 {
        var u = UInt64(bitPattern: tuple)
        let v = UInt64(UInt32(bitPattern: value))
        if axis == 0 {
            u = (u & 0xffffffff_00000000) | v
        } else {
            u = (u & 0x00000000_ffffffff) | (v << 32)
        }
        return Int64(bitPattern: u)
    }
}
