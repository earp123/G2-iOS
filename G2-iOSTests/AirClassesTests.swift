//
//  AirClassesTests.swift
//  G2-iOSTests
//
//  The packed class byte and the two tiles it drives (thresholds-v3 §1.1):
//  low nibble gas 0–5, high nibble PM 0–3, coloured like the device's LEDs.
//

import Foundation
import SwiftUI
import Testing
@testable import G2_iOS

@Suite("AirClasses — packed gas / PM class byte")
struct AirClassesTests {

    @Test("init(byte:) splits low nibble gas, high nibble PM")
    func splitsNibbles() {
        let classes = AirClasses(byte: 0x35)
        #expect(classes.gas == 5)
        #expect(classes.pm == 3)
        #expect(AirClasses(byte: 0x00) == .unknown)
        #expect(AirClasses(byte: 0x10) == AirClasses(gas: 0, pm: 1))
        #expect(AirClasses(byte: 0x04) == AirClasses(gas: 4, pm: 0))
    }

    @Test("byte re-packs as (pm << 4) | gas for every legal pair")
    func packsBack() {
        for gas in UInt8(0)...5 {
            for pm in UInt8(0)...3 {
                let classes = AirClasses(gas: gas, pm: pm)
                #expect(classes.byte == (pm << 4) | gas)
                #expect(AirClasses(byte: classes.byte) == classes)
            }
        }
    }

    @Test("Gas tile colour: 0 grey, 1–2 green, 3 orange, 4–5 red")
    func gasTileColours() {
        #expect(AQILevel(raw: 0).color == Theme.textSecondary)
        #expect(AQILevel(raw: 1).color == Theme.aqiExcellent)
        #expect(AQILevel(raw: 2).color == Theme.aqiExcellent)
        #expect(AQILevel(raw: 3).color == Theme.aqiPoor)
        #expect(AQILevel(raw: 4).color == Theme.aqiUnhealthy)
        #expect(AQILevel(raw: 5).color == Theme.aqiUnhealthy)
        #expect(AQILevel(raw: 6).color == Theme.textSecondary)   // undefined → unknown
    }

    @Test("PM tile colour: 0 grey, 1 green, 2 orange, 3 red")
    func pmTileColours() {
        #expect(PMLevel(raw: 0).color == Theme.textSecondary)
        #expect(PMLevel(raw: 1).color == Theme.aqiExcellent)
        #expect(PMLevel(raw: 2).color == Theme.aqiPoor)
        #expect(PMLevel(raw: 3).color == Theme.aqiUnhealthy)
        #expect(PMLevel(raw: 4).color == Theme.textSecondary)    // undefined → unknown
    }

    @Test("PM labels follow firmware's good / attention / hazard naming")
    func pmLabels() {
        #expect(PMLevel.good.label == "Good")
        #expect(PMLevel.attention.label == "Attention")
        #expect(PMLevel.hazard.label == "Hazard")
        #expect(PMLevel.unknown.label == "—")
        #expect(PMLevel.unknown.label(isWarming: true) == "Warming up")
    }
}
