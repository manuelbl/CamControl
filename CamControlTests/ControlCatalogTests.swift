//
//  ControlCatalogTests.swift
//  Tests for the control catalog's invariants and for turning a saved snapshot into
//  the ordered writes of a reapply.
//

import Testing

struct ControlCatalogTests {
    // MARK: - Catalog invariants

    @Test func everyControlIDHasExactlyOneEntry() {
        let ids = ControlCatalog.all.map(\.id)
        #expect(ids.count == Set(ids).count)
        #expect(Set(ids) == Set(ControlID.allCases))
    }

    @Test(arguments: ControlID.allCases)
    func lookupReturnsMatchingEntry(_ id: ControlID) {
        #expect(ControlCatalog.descriptor(for: id).id == id)
    }

    @Test(arguments: ControlCatalog.autoPairs.map(\.autoID))
    func autoDirectlyPrecedesItsManualValue(_ autoID: ControlID) throws {
        // The reapply and reset rely on this order: Auto must land before the manual value.
        let pair = try #require(ControlCatalog.autoPair(containing: autoID))
        let ids = ControlCatalog.all.map(\.id)
        let auto = try #require(ids.firstIndex(of: pair.autoID))
        let manual = try #require(ids.firstIndex(of: pair.manualID))
        #expect(auto + 1 == manual)
    }

    @Test func autoPairsAreFoundByEitherMember() {
        #expect(ControlCatalog.autoPair(containing: .exposureTime)?.autoID == .exposureAuto)
        #expect(ControlCatalog.autoPair(containing: .whiteBalanceAuto)?.manualID == .whiteBalanceTemp)
        #expect(ControlCatalog.autoPair(containing: .gain) == nil)
    }

    @Test func panAndTiltAreTheTwoAxesOfOneTuple() {
        let pan = ControlCatalog.descriptor(for: .pan).target
        let tilt = ControlCatalog.descriptor(for: .tilt).target
        #expect(pan.dataType == .sInt32Tuple && pan.tupleAxis == 0)
        #expect(tilt.dataType == .sInt32Tuple && tilt.tupleAxis == 1)
    }

    @Test func onlyTupleControlsHaveAnAxis() {
        for descriptor in ControlCatalog.all {
            #expect((descriptor.target.tupleAxis != nil) == (descriptor.target.dataType == .sInt32Tuple),
                    "\(descriptor.id)")
        }
    }

    // MARK: - Ordered writes

    @Test func writesFollowCatalogOrder() {
        let snapshot: [ControlID: Int64] = [.tilt: 7200, .brightness: 10, .backlight: 1, .zoom: 100]
        let ids = ControlCatalog.orderedWrites(from: snapshot).map(\.0)
        #expect(ids == [.backlight, .brightness, .zoom, .tilt])
    }

    @Test func writesCarryTheSnapshotValues() {
        let snapshot: [ControlID: Int64] = [.brightness: -5, .pan: -36000]
        let writes = ControlCatalog.orderedWrites(from: snapshot)
        #expect(writes.map(\.0) == [.brightness, .pan])
        #expect(writes.map(\.1) == [-5, -36000])
    }

    @Test func emptySnapshotYieldsNoWrites() {
        #expect(ControlCatalog.orderedWrites(from: [:]).isEmpty)
    }

    @Test func temperatureIsSkippedWhileAutoIsOn() {
        let snapshot: [ControlID: Int64] = [.whiteBalanceAuto: 1, .whiteBalanceTemp: 4500]
        let ids = ControlCatalog.orderedWrites(from: snapshot).map(\.0)
        #expect(ids == [.whiteBalanceAuto])
    }

    @Test func temperatureFollowsAutoWhenAutoIsOff() {
        let snapshot: [ControlID: Int64] = [.whiteBalanceTemp: 4500, .whiteBalanceAuto: 0]
        let ids = ControlCatalog.orderedWrites(from: snapshot).map(\.0)
        #expect(ids == [.whiteBalanceAuto, .whiteBalanceTemp])
    }

    @Test func exposureTimeIsSkippedWhileAutoExposureIsOn() {
        // Aperture priority (8) is "auto" on a webcam; gain is independent and still written.
        let snapshot: [ControlID: Int64] = [.exposureAuto: 8, .exposureTime: 167, .gain: 64]
        let ids = ControlCatalog.orderedWrites(from: snapshot).map(\.0)
        #expect(ids == [.exposureAuto, .gain])
    }

    @Test func exposureTimeFollowsAutoExposureWhenManual() {
        let snapshot: [ControlID: Int64] = [.gain: 64, .exposureTime: 167, .exposureAuto: 1]
        let ids = ControlCatalog.orderedWrites(from: snapshot).map(\.0)
        #expect(ids == [.exposureAuto, .exposureTime, .gain])
    }

    @Test func temperatureIsWrittenWhenAutoIsAbsent() {
        // A camera without WB Auto support saves only the temperature.
        let ids = ControlCatalog.orderedWrites(from: [.whiteBalanceTemp: 4500]).map(\.0)
        #expect(ids == [.whiteBalanceTemp])
    }
}
