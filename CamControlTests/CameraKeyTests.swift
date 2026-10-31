//
//  CameraKeyTests.swift
//  Tests for parsing AVFoundation's session identity into the USB triple — the join
//  between the identity the UI knows a camera by and the one USBCameraService does.
//

import Testing

struct CameraKeyTests {
    @Test func parsesSessionIDOfARealCamera() {
        // Dell Webcam WB7022: location 0x11000000, VID 0x413c, PID 0xc015.
        let key = CameraKey(sessionID: "0x11000000413cc015")
        #expect(key?.locationID == 0x1100_0000)
        #expect(key?.vendorID == 0x413c)
        #expect(key?.productID == 0xc015)
    }

    @Test func parsesShortLocationID() {
        // AVFoundation drops leading zeros of the location ID, so the string varies in
        // length; only the trailing eight digits are fixed-width.
        let key = CameraKey(sessionID: "0x14413cc015")
        #expect(key?.locationID == 0x14)
        #expect(key?.vendorID == 0x413c)
        #expect(key?.productID == 0xc015)
    }

    @Test func roundTripsThroughDescription() {
        let key = CameraKey(sessionID: "0x11000000413cc015")
        #expect(key?.description == "0x11000000413cc015")
    }

    @Test(arguments: [
        "",                     // no id at all
        "0x14",                 // too short to hold VID + PID
        "11000000413cc015",     // missing 0x prefix
        "0x11000000413cc015ff", // too long
        "0x110000004l3cc015",   // not hex (letter l)
    ])
    func rejectsNonUSBSessionIDs(_ sessionID: String) {
        // The built-in and Continuity cameras carry ids of a wholly different shape;
        // anything that isn't the USB triple must resolve to no camera at all.
        #expect(CameraKey(sessionID: sessionID) == nil)
    }

    @Test func distinguishesSamePortFromSameModel() {
        let onPortA = CameraKey(sessionID: "0x11000000413cc015")
        let onPortB = CameraKey(sessionID: "0x12000000413cc015")
        #expect(onPortA != onPortB)
        #expect(onPortA == CameraKey(sessionID: "0x11000000413cc015"))
    }
}
