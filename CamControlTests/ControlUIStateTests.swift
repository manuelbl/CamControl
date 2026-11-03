//
//  ControlUIStateTests.swift
//  Tests for how a control's native value is interpreted for display: slider read-outs
//  and bounds, toggle state, anti-flicker segments and resolution snapping.
//

import Foundation
import Testing

/// A supported control with the given range and current value.
private func state(_ id: ControlID, value: Int64,
                   min: Int64, max: Int64, resolution: Int64 = 1) -> ControlUIState {
    ControlUIState(from: ControlSnapshot(
        id: id,
        state: ControlState(supported: true, value: value),
        range: ControlRange(minimum: min, maximum: max, resolution: resolution, default: min)))
}

private func unsupported(_ id: ControlID) -> ControlUIState {
    ControlUIState(from: ControlSnapshot(
        id: id, state: ControlState(supported: false, value: 0), range: nil))
}

struct ControlUIStateTests {
    // MARK: - Display text

    @Test func percentIsPositionWithinRange() {
        // Brightness spans -64…64; 0 sits halfway.
        #expect(state(.brightness, value: 0, min: -64, max: 64).displayText == 50.formatted(.percent))
        #expect(state(.brightness, value: -64, min: -64, max: 64).displayText == 0.formatted(.percent))
        #expect(state(.brightness, value: 64, min: -64, max: 64).displayText == 100.formatted(.percent))
    }

    @Test func percentIsRounded() {
        // 1/3 → 33.3 %, 2/3 → 66.7 %
        #expect(state(.contrast, value: 1, min: 0, max: 3).displayText == 33.formatted(.percent))
        #expect(state(.contrast, value: 2, min: 0, max: 3).displayText == 67.formatted(.percent))
    }

    @Test func percentOfDegenerateRangeIsDash() {
        #expect(state(.zoom, value: 100, min: 100, max: 100).displayText == "—")
    }

    @Test func kelvinShowsNativeValue() {
        // The number is formatted per locale (e.g. "4,600K" or "4'600K").
        #expect(state(.whiteBalanceTemp, value: 4600, min: 2800, max: 6500).displayText
                == "\(4600.formatted())K")
    }

    @Test func degreesConvertFromArcSeconds() {
        #expect(state(.pan, value: 36000, min: -36000, max: 36000).displayText == "10°")
        #expect(state(.tilt, value: -7200, min: -36000, max: 36000).displayText == "-2°")
        #expect(state(.pan, value: 5400, min: -36000, max: 36000).displayText == "2°")  // 1.5° rounds up
    }

    @Test func shutterShowsFractionOfASecond() {
        // Native unit is 100 µs: 167 → 16.7 ms ≈ 1/60 s.
        #expect(state(.exposureTime, value: 167, min: 1, max: 20000).displayText == "1/60 s")
        #expect(state(.exposureTime, value: 1, min: 1, max: 20000).displayText == "1/10000 s")
        #expect(state(.exposureTime, value: 5000, min: 1, max: 20000).displayText == "1/2 s")
    }

    @Test func shutterShowsWholeSecondsFromOneSecond() {
        #expect(state(.exposureTime, value: 10000, min: 1, max: 20000).displayText == "1 s")
        #expect(state(.exposureTime, value: 20000, min: 1, max: 20000).displayText == "2 s")
    }

    @Test func selfDescribingControlsHaveNoText() {
        #expect(state(.backlight, value: 1, min: 0, max: 1).displayText == "")
    }

    @Test func unsupportedIsDash() {
        #expect(unsupported(.brightness).displayText == "—")
    }

    // MARK: - Slider bounds

    @Test func sliderBoundsSpanTheRange() {
        #expect(state(.brightness, value: 0, min: -64, max: 64).sliderBounds == -64...64)
    }

    @Test func linearSliderPositionIsTheNativeValue() {
        let s = state(.brightness, value: 8, min: -64, max: 64)
        #expect(s.sliderPosition == 8)
        #expect(s.value(atSliderPosition: 7.6) == 8)
    }

    @Test func exposureSliderIsLogarithmic() throws {
        // 1…10000: 100 sits halfway on a log scale.
        let s = state(.exposureTime, value: 100, min: 1, max: 10000)
        let bounds = try #require(s.sliderBounds)
        #expect(abs(s.sliderPosition - (bounds.lowerBound + bounds.upperBound) / 2) < 1e-9)
    }

    @Test func exposureSliderEndsMapToRangeEnds() throws {
        let s = state(.exposureTime, value: 100, min: 3, max: 2047)
        let bounds = try #require(s.sliderBounds)
        #expect(s.value(atSliderPosition: bounds.lowerBound) == 3)
        #expect(s.value(atSliderPosition: bounds.upperBound) == 2047)
    }

    @Test(arguments: [3, 4, 50, 167, 2046, 2047] as [Int64])
    func exposureSliderRoundTrips(_ value: Int64) {
        let s = state(.exposureTime, value: value, min: 3, max: 2047)
        #expect(s.value(atSliderPosition: s.sliderPosition) == value)
    }

    @Test func exposureSliderSnapsAndClamps() throws {
        // Resolution 10 anchored at 5: 5, 15, 25, …; positions beyond the ends clamp.
        let s = state(.exposureTime, value: 105, min: 5, max: 1005, resolution: 10)
        #expect(s.value(atSliderPosition: log(103)) == 105)
        let bounds = try #require(s.sliderBounds)
        #expect(s.value(atSliderPosition: bounds.upperBound + 1) == 1005)
        #expect(s.value(atSliderPosition: bounds.lowerBound - 1) == 5)
    }

    @Test func exposureSliderHandlesRangeStartingAtZero() throws {
        let s = state(.exposureTime, value: 0, min: 0, max: 1000)
        let bounds = try #require(s.sliderBounds)
        #expect(bounds.lowerBound.isFinite)
        #expect(s.value(atSliderPosition: s.sliderPosition) == 0)
        #expect(s.value(atSliderPosition: bounds.upperBound) == 1000)
    }

    @Test func degenerateOrUnsupportedRangeHasNoBounds() {
        #expect(state(.zoom, value: 100, min: 100, max: 100).sliderBounds == nil)
        #expect(unsupported(.zoom).sliderBounds == nil)
    }

    // MARK: - Toggle

    @Test func toggleIsOnAboveMinimum() {
        #expect(!state(.backlight, value: 0, min: 0, max: 1).isToggledOn)
        #expect(state(.backlight, value: 1, min: 0, max: 1).isToggledOn)
        // Backlight compensation can be a wider numeric range on the wire.
        #expect(!state(.backlight, value: 0, min: 0, max: 2).isToggledOn)
        #expect(state(.backlight, value: 2, min: 0, max: 2).isToggledOn)
    }

    @Test func unsupportedToggleIsOff() {
        #expect(!unsupported(.whiteBalanceAuto).isToggledOn)
    }

    @Test func autoExposureToggleIsOnInAnyAutoMode() {
        // Range min = manual (1); shutter priority (4) also counts as auto.
        #expect(!state(.exposureAuto, value: 1, min: 1, max: 8).isToggledOn)
        #expect(state(.exposureAuto, value: 8, min: 1, max: 8).isToggledOn)
        #expect(state(.exposureAuto, value: 4, min: 1, max: 8).isToggledOn)
    }

    // MARK: - Auto-exposure range

    @Test func autoExposurePrefersAperturePriority() {
        #expect(ControlRange.autoExposure(modes: 0x09, default: 8)
                == ControlRange(minimum: 1, maximum: 8, resolution: 1, default: 8))
        #expect(ControlRange.autoExposure(modes: 0x0f, default: 2)?.maximum == 8)
    }

    @Test func autoExposureFallsBackToAutoMode() {
        #expect(ControlRange.autoExposure(modes: 0x03, default: 2)
                == ControlRange(minimum: 1, maximum: 2, resolution: 1, default: 2))
    }

    @Test func autoExposureNeedsManualAndAnAutoMode() {
        #expect(ControlRange.autoExposure(modes: 0x08, default: 8) == nil)   // no manual
        #expect(ControlRange.autoExposure(modes: 0x01, default: 1) == nil)   // manual only
        #expect(ControlRange.autoExposure(modes: 0x05, default: 1) == nil)   // shutter priority only
    }

    // MARK: - Anti-flicker segments

    @Test func flickerOffersAutoOnlyWhenMaximumAllowsIt() {
        #expect(state(.antiFlicker, value: 1, min: 0, max: 2).flickerSegments.map(\.value) == [0, 1, 2])
        #expect(state(.antiFlicker, value: 1, min: 0, max: 3).flickerSegments.map(\.value) == [0, 1, 2, 3])
    }

    // MARK: - Snapping

    @Test func snapsToResolutionGridAnchoredAtMinimum() {
        // 2800…6500 in steps of 10: grid points are 2800, 2810, …
        let range = ControlRange(minimum: 2800, maximum: 6500, resolution: 10, default: 4600)
        #expect(snapped(4603.9, to: range) == 4600)
        #expect(snapped(4605.1, to: range) == 4610)
        // Anchored at an odd minimum: 1, 4, 7, …
        let odd = ControlRange(minimum: 1, maximum: 100, resolution: 3, default: 1)
        #expect(snapped(5, to: odd) == 4)
        #expect(snapped(6, to: odd) == 7)
    }

    @Test func snapsNegativeValues() {
        let range = ControlRange(minimum: -36000, maximum: 36000, resolution: 3600, default: 0)
        #expect(snapped(-5000, to: range) == -3600)
        #expect(snapped(-5500, to: range) == -7200)
    }

    @Test func zeroResolutionSnapsToIntegers() {
        let range = ControlRange(minimum: 0, maximum: 100, resolution: 0, default: 50)
        #expect(snapped(41.6, to: range) == 42)
    }

    @Test func missingRangeRoundsToInteger() {
        #expect(snapped(41.4, to: nil) == 41)
    }
}
