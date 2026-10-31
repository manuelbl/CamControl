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

    @Test func whiteBalanceAutoPrecedesTemperature() throws {
        // The reapply relies on this order: the Auto flag must land before the temperature.
        let ids = ControlCatalog.all.map(\.id)
        let auto = try #require(ids.firstIndex(of: .whiteBalanceAuto))
        let temp = try #require(ids.firstIndex(of: .whiteBalanceTemp))
        #expect(auto < temp)
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

    @Test func temperatureIsWrittenWhenAutoIsAbsent() {
        // A camera without WB Auto support saves only the temperature.
        let ids = ControlCatalog.orderedWrites(from: [.whiteBalanceTemp: 4500]).map(\.0)
        #expect(ids == [.whiteBalanceTemp])
    }
}
