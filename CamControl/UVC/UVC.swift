//
//  UVC.swift
//  USB Video Class protocol constants.
//
//  Names follow "USB Device Class Definition for Video Devices" (UVC 1.5);
//  the spec's identifier is noted next to each constant so values stay
//  cross-checkable against the standard.
//

/// Namespace for UVC protocol constants.
enum UVC {
    // MARK: Descriptor types

    /// Standard interface descriptor (DT_INTERFACE)
    static let descriptorTypeInterface: UInt8 = 0x04
    /// Class-specific interface descriptor (CS_INTERFACE)
    static let descriptorTypeCSInterface: UInt8 = 0x24

    // MARK: Video interface class / subclass codes

    /// Video interface class (CC_VIDEO)
    static let classVideo: UInt8 = 0x0e
    /// VideoControl interface subclass (SC_VIDEOCONTROL)
    static let subclassVideoControl: UInt8 = 0x01
    /// VideoStreaming interface subclass (SC_VIDEOSTREAMING)
    static let subclassVideoStreaming: UInt8 = 0x02

    // MARK: Class-specific VC interface descriptor subtypes

    /// VC_HEADER
    static let vcHeader: UInt8 = 0x01
    /// VC_INPUT_TERMINAL
    static let vcInputTerminal: UInt8 = 0x02
    /// VC_OUTPUT_TERMINAL
    static let vcOutputTerminal: UInt8 = 0x03
    /// VC_SELECTOR_UNIT
    static let vcSelectorUnit: UInt8 = 0x04
    /// VC_PROCESSING_UNIT
    static let vcProcessingUnit: UInt8 = 0x05
    /// VC_EXTENSION_UNIT
    static let vcExtensionUnit: UInt8 = 0x06

    // MARK: Input terminal types

    /// Camera sensor input terminal (ITT_CAMERA)
    static let terminalTypeCamera: UInt16 = 0x0201

    // MARK: Class-specific request codes
    //
    // The GET_* value-query codes (GET_CUR 0x81 … GET_DEF 0x87) live in
    // `VideoControlAspect`; only the codes used outside that enum are here.

    /// SET_CUR — set the current value of a control
    static let setCur: UInt8 = 0x01
    /// GET_DEF — get the default value of a control
    static let getDef: UInt8 = 0x87
}
