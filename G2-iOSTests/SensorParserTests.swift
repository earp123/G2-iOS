//
//  SensorParserTests.swift
//  G2-iOSTests
//
//  Golden-vector tests for the 52-byte live packet (§7), contract v3. Each
//  expectation is stated in display units, so a scaling regression (÷10 vs
//  ÷100) fails loudly rather than shifting a decimal point unnoticed.
//

import Foundation
import Testing
@testable import G2_iOS

@Suite("SensorParser — live packet v3")
struct SensorParserTests {

    private func parsed(_ bytes: [UInt8]) throws -> SensorReading {
        let result = SensorParser.parse(GoldenVectors.data(bytes))
        guard case .success(let reading) = result else {
            Issue.record("expected a successful parse, got \(result)")
            throw ParseFailure.unexpected
        }
        return reading
    }

    enum ParseFailure: Error { case unexpected }

    // MARK: - A full, valid packet

    @Test("Every field of a valid 52-byte packet decodes to its display value")
    func validPacketDecodesEveryField() throws {
        let r = try parsed(GoldenVectors.validLivePacket)

        #expect(r.sequence == 4660)
        #expect(r.temperatureC.value == 23.45)
        #expect(r.humidityPct.value == 46.75)
        #expect(r.vocIndex.value == 123.4)
        #expect(r.noxIndex.value == 12.5)
        #expect(r.co2Ppm.value == 712)

        #expect(r.pm1.value == 5.6)
        #expect(r.pm25.value == 9.8)
        #expect(r.pm4.value == 11.1)
        #expect(r.pm10.value == 14.3)

        #expect(r.nc05.value == 8.9)
        #expect(r.nc1.value == 6.1)
        #expect(r.nc25.value == 5.4)
        #expect(r.nc4.value == 4.2)
        #expect(r.nc10.value == 3.3)

        #expect(r.classes == AirClasses(gas: 3, pm: 2))
        #expect(r.fanSpeedPct == 75)
        #expect(r.fanMode == .manual)
        #expect(r.deviceState == .enabled)

        // Raw values: ticks and ppm unscaled, RH ×100 and T ×200 descaled.
        #expect(r.rawVOCTicks.value == 30000)
        #expect(r.rawNOxTicks.value == 15000)
        #expect(r.rawCO2Ppm.value == 705)
        #expect(r.rawHumidityPct.value == 47.12)
        #expect(r.rawTemperatureC.value == 24.65)
    }

    @Test("Status byte 0x4B decodes to the v2 bit map (unchanged in v3)")
    func statusBitsDecode() throws {
        let r = try parsed(GoldenVectors.validLivePacket)
        #expect(r.status.sen66Present)          // bit 0
        #expect(r.status.isFresh)               // bit 1
        #expect(!r.status.sen66Warming)         // bit 2
        #expect(r.status.twaiOnline)            // bit 3
        #expect(!r.status.sen66StickyError)     // bit 4
        #expect(r.status.ionizerIsHealthy)      // bit 5 clear = healthy
        #expect(r.status.ionizerIsOn)           // bit 6
        #expect(r.status.ionizerState == .healthy)
    }

    @Test("SEN66 register bit 21 reads as a fan-speed warning, not an error")
    func sen66FanSpeedWarning() throws {
        let r = try parsed(GoldenVectors.validLivePacket)
        #expect(r.sen66Status.raw == 0x0020_0000)
        #expect(r.sen66Status.fanSpeedWarning)
        #expect(!r.sen66Status.hasError)        // the five error bits are clear
        #expect(!r.sen66Status.isClean)
        #expect(r.sen66Status.activeIndicators.count == 1)
        #expect(r.sen66Status.hexDescription == "0x00200000")
    }

    // MARK: - Sentinels

    @Test("Every invalid sentinel decodes to .invalid, never to a number")
    func allSentinelsDecodeInvalid() throws {
        let r = try parsed(GoldenVectors.allSentinelLivePacket)

        #expect(!r.temperatureC.isValid)
        #expect(!r.humidityPct.isValid)
        #expect(!r.vocIndex.isValid)
        #expect(!r.noxIndex.isValid)
        #expect(!r.co2Ppm.isValid)
        #expect(!r.pm1.isValid)
        #expect(!r.pm25.isValid)
        #expect(!r.pm4.isValid)
        #expect(!r.pm10.isValid)
        #expect(!r.nc05.isValid)
        #expect(!r.nc1.isValid)
        #expect(!r.nc25.isValid)
        #expect(!r.nc4.isValid)
        #expect(!r.nc10.isValid)
        #expect(!r.rawVOCTicks.isValid)
        #expect(!r.rawNOxTicks.isValid)
        #expect(!r.rawCO2Ppm.isValid)
        #expect(!r.rawHumidityPct.isValid)
        #expect(!r.rawTemperatureC.isValid)

        // Sentinels render as "—", never as 655.35 or -327.68.
        #expect(r.temperatureC.formatted(decimals: 1) == "—")
        #expect(r.pm25.formatted(decimals: 1) == "—")
        #expect(r.co2Ppm.formatted == "—")
    }

    @Test("PM 0xFFFE over-range is invalid, not 6553.4")
    func pmOverRangeSentinel() throws {
        let r = try parsed(GoldenVectors.pmOverRangeLivePacket)
        #expect(!r.pm1.isValid)
        #expect(!r.pm25.isValid)
        #expect(!r.pm4.isValid)
        #expect(!r.pm10.isValid)
        // Non-PM fields in the same packet still decode.
        #expect(r.vocIndex.value == 123.4)
        #expect(r.co2Ppm.value == 712)
    }

    @Test("0xFFFE is a PM-only sentinel — a VOC index of 6553.4 is not folded away")
    func overRangeIsPMOnly() {
        #expect(GATT.decodePMx10(0xFFFE) == nil)
        #expect(GATT.decodePMx10(0xFFFF) == nil)
        #expect(GATT.decodeU16x10(0xFFFE) == 6553.4)
        #expect(GATT.decodeU16x10(0xFFFF) == nil)
    }

    // MARK: - Packed class byte (thresholds-v3 §1.1)

    @Test("Byte 32 splits into gas (low nibble) and PM (high nibble)")
    func packedClassByteDecodes() throws {
        let r = try parsed(GoldenVectors.validLivePacket)   // 0x23
        #expect(r.classes.gas == 3)
        #expect(r.classes.pm == 2)
        #expect(r.gasLevel == .moderate)
        #expect(r.pmLevel == .attention)
        #expect(r.gasClassLabel == "Moderate")
        #expect(r.pmClassLabel == "Attention")
    }

    @Test("Gas and PM classes decode independently at byte 32", arguments: [
        (UInt8(0x00), UInt8(0), UInt8(0)),
        (0x01, 1, 0), (0x05, 5, 0),          // gas moves, PM stays unknown
        (0x10, 0, 1), (0x30, 0, 3),          // PM moves, gas stays unknown
        (0x15, 5, 1), (0x31, 1, 3), (0x34, 4, 3),
    ])
    func classNibblesAreIndependent(byte: UInt8, gas: UInt8, pm: UInt8) throws {
        var bytes = GoldenVectors.validLivePacket
        bytes[GATT.SensorOffset.classByte] = byte
        let r = try parsed(bytes)
        #expect(r.classes.gas == gas)
        #expect(r.classes.pm == pm)
        // Nothing else in the packet moves with the class byte.
        #expect(r.vocIndex.value == 123.4)
        #expect(r.pm25.value == 9.8)
    }

    @Test("PM over-range packet carries gas 3 with an unknown PM class")
    func pmInvalidMeansPMClassZero() throws {
        let r = try parsed(GoldenVectors.pmOverRangeLivePacket)   // 0x03
        #expect(r.classes == AirClasses(gas: 3, pm: 0))
        #expect(r.pmLevel == .unknown)
        #expect(r.pmClassLabel == "—")
    }

    @Test("Out-of-range nibbles are clamped to unknown, never to a real class")
    func outOfRangeNibblesAreUnknown() throws {
        var bytes = GoldenVectors.validLivePacket
        bytes[GATT.SensorOffset.classByte] = 0xF6   // gas 6, PM 15 — both undefined
        let r = try parsed(bytes)
        #expect(r.classes.gas == 6)
        #expect(r.classes.pm == 15)
        #expect(r.gasLevel == .unknown)
        #expect(r.pmLevel == .unknown)
    }

    // MARK: - Fan mode byte 34 (thresholds-v3 §2.6)

    @Test("Byte 34 decodes 0 Auto and 2 Manual")
    func fanModeByte34() throws {
        var bytes = GoldenVectors.validLivePacket
        bytes[GATT.SensorOffset.fanMode] = 0
        #expect(try parsed(bytes).fanMode == .auto)
        bytes[GATT.SensorOffset.fanMode] = 2
        #expect(try parsed(bytes).fanMode == .manual)
        bytes[GATT.SensorOffset.fanMode] = 3
        #expect(try parsed(bytes).fanMode == nil)   // undefined, not coerced
    }

    // MARK: - Warming state (§2)

    @Test("Warming packet: class byte 0 with status bit 2 reads as Warming up on both tiles")
    func warmingState() throws {
        let r = try parsed(GoldenVectors.warmingLivePacket)
        #expect(r.status.sen66Warming)
        #expect(r.classes == .unknown)
        #expect(r.gasLevel == .unknown)
        #expect(!r.gasLevel.isValid)
        #expect(!r.pmLevel.isValid)
        #expect(r.isWarmingUp)
        #expect(r.gasClassLabel == "Warming up")
        #expect(r.pmClassLabel == "Warming up")
    }

    @Test("Class byte 0 without the warming bit reads as — , not Warming up")
    func unknownWithoutWarmingBit() throws {
        let r = try parsed(GoldenVectors.allSentinelLivePacket)   // status 0x00
        #expect(!r.status.sen66Warming)
        #expect(r.gasLevel == .unknown)
        #expect(r.gasClassLabel == "—")
        #expect(r.pmClassLabel == "—")
    }

    // MARK: - Rejections

    @Test("A 31-byte legacy v1 packet is rejected, not best-effort decoded")
    func legacyPacketRejected() {
        let result = SensorParser.parse(GoldenVectors.data(GoldenVectors.legacyV1LivePacket))
        guard case .failure(let error) = result else {
            Issue.record("a 31-byte legacy packet must not parse")
            return
        }
        // It fails on length before the marker is even considered.
        #expect(error == .malformedPacket(length: 31))
    }

    @Test("A 52-byte packet still carrying the legacy 0x02 marker is rejected")
    func legacyMarkerRejected() {
        var bytes = GoldenVectors.validLivePacket
        bytes[0] = GATT.legacyLivePacketMarker
        let result = SensorParser.parse(GoldenVectors.data(bytes))
        #expect(result == .failure(.unsupportedMarker(0x02)))
        if case .failure(let error) = result {
            #expect(error.message.contains("pre-SEN66"))
        }
    }

    @Test("A history packet reaching the sensor parser is rejected on its marker")
    func historyMarkerRejected() {
        var bytes = GoldenVectors.validLivePacket
        bytes[0] = GATT.historyPacketMarker
        #expect(SensorParser.parse(GoldenVectors.data(bytes)) == .failure(.unsupportedMarker(0xA5)))
    }

    @Test("A contract-v2 packet (payload version 2) is rejected, not read as packed classes")
    func contractV2PacketRejected() {
        // Byte 32 of a v2 packet is aq_class with PM folded in; decoding it as a
        // packed byte would invent a gas class. Byte 1 is what tells them apart.
        #expect(GATT.livePayloadVersion == 0x03)
        #expect(SensorParser.parse(GoldenVectors.data(GoldenVectors.contractV2LivePacket))
                == .failure(.unsupportedPayloadVersion(0x02)))
    }

    @Test("An unexpected payload version is rejected rather than mis-decoded")
    func payloadVersionRejected() {
        var bytes = GoldenVectors.validLivePacket
        bytes[1] = 0x04
        #expect(SensorParser.parse(GoldenVectors.data(bytes)) == .failure(.unsupportedPayloadVersion(0x04)))
    }

    @Test("Short payloads fail without crashing", arguments: [0, 1, 31, 51])
    func shortPayloadsFail(length: Int) {
        let bytes = [UInt8](GoldenVectors.validLivePacket.prefix(length))
        #expect(SensorParser.parse(GoldenVectors.data(bytes)) == .failure(.malformedPacket(length: length)))
    }

    @Test("A payload longer than 52 bytes is rejected, not trimmed")
    func longPayloadRejected() {
        // The firmware note guards on `count == 52`. A longer payload means the
        // contract broke somewhere, so it is reported rather than silently
        // decoded from its first 52 bytes (notes §9).
        let bytes = GoldenVectors.validLivePacket + [0xAA, 0xBB]
        #expect(SensorParser.parse(GoldenVectors.data(bytes)) == .failure(.malformedPacket(length: 54)))
    }

    @Test("A Data slice with a non-zero start index decodes from the right offset")
    func slicedDataDecodes() throws {
        // Guards the [UInt8](data) normalisation: a sliced Data keeps the parent's
        // indices, so fixed offsets would read the wrong bytes without it.
        let padded = Data([0xDE, 0xAD]) + GoldenVectors.data(GoldenVectors.validLivePacket)
        let slice = padded.dropFirst(2)   // 52 bytes, but startIndex == 2
        guard case .success(let r) = SensorParser.parse(slice) else {
            Issue.record("a sliced payload must decode identically")
            return
        }
        #expect(r.sequence == 4660)
        #expect(r.temperatureC.value == 23.45)
    }
}
