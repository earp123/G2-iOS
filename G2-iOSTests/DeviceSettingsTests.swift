//
//  DeviceSettingsTests.swift
//  G2-iOSTests
//
//  Round-trip and validation tests for the 12-byte Settings payload, the Device
//  Name length rule, and the 40-byte Device Info payload (§7).
//

import Foundation
import Testing
@testable import G2_iOS

@Suite("DeviceSettings — 12-byte settings payload v2")
struct DeviceSettingsTests {

    @Test("A 12-byte payload decodes to its documented fields")
    func decodesGoldenPayload() throws {
        let settings = try #require(DeviceSettings(data: GoldenVectors.data(GoldenVectors.settingsPayload)))
        #expect(settings.thresholds == VOCThresholds(lo: 100, med: 150, hi: 250, max: 400))
        #expect(settings.thresholds == .defaults)
        #expect(settings.ledBrightnessPct == 50)
        #expect(settings.fanMode == .custom)
        #expect(settings.fanManualPct == 0)
    }

    @Test("Encode → decode round-trips every field")
    func encodeDecodeRoundTrip() throws {
        let original = DeviceSettings(
            thresholds: VOCThresholds(lo: 80, med: 200, hi: 300, max: 460),
            ledBrightnessPct: 35,
            fanMode: .manual,
            fanManualPct: 60
        )
        let encoded = original.encoded
        #expect(encoded.count == GATT.settingsPayloadLength)

        let decoded = try #require(DeviceSettings(data: encoded))
        #expect(decoded == original)
        #expect(decoded.thresholds.lo == 80)
        #expect(decoded.thresholds.max == 460)
        #expect(decoded.ledBrightnessPct == 35)
        #expect(decoded.fanMode == .manual)
        #expect(decoded.fanManualPct == 60)
    }

    @Test("The encoded payload matches the documented byte layout exactly")
    func encodedLayoutMatchesContract() {
        let encoded = [UInt8](DeviceSettings.defaults.encoded)
        let o = GATT.SettingsOffset.self
        // Thresholds little-endian: 100, 150, 250, 400.
        #expect(Array(encoded[o.thresholds..<(o.thresholds + 8)])
                == [0x64, 0x00, 0x96, 0x00, 0xFA, 0x00, 0x90, 0x01])
        #expect(encoded[o.ledBrightness] == 50)
        #expect(encoded[o.fanMode] == FanMode.auto.wire)
        #expect(encoded[o.fanManualPct] == 0)
        #expect(encoded[o.reserved] == 0)
        #expect(encoded.count == 12)
    }

    @Test("The client always writes 12 bytes, never the legacy 8")
    func alwaysWritesTwelveBytes() {
        #expect(DeviceSettings.defaults.encoded.count == 12)
        #expect(GATT.settingsPayloadLength == 12)
    }

    // MARK: - Brightness clamping (§1.3)

    @Test("Brightness below the 5% floor displays as 5, matching what firmware keeps")
    func brightnessBelowFloorClamps() throws {
        let settings = try #require(
            DeviceSettings(data: GoldenVectors.data(GoldenVectors.settingsPayloadBelowBrightnessFloor)))
        #expect(settings.ledBrightnessPct == GATT.ledBrightnessMin)   // 3 → 5
        #expect(settings.fanMode == .manual)
        // The clamp survives a re-encode, so the UI can never write back a 3.
        #expect([UInt8](settings.encoded)[GATT.SettingsOffset.ledBrightness] == 5)
    }

    @Test("Brightness above 100 displays as 100")
    func brightnessAboveCeilingClamps() throws {
        let settings = try #require(
            DeviceSettings(data: GoldenVectors.data(GoldenVectors.settingsPayloadAboveBrightnessCeiling)))
        #expect(settings.ledBrightnessPct == GATT.ledBrightnessMax)   // 200 → 100
        #expect(settings.fanMode == .auto)
        #expect(settings.fanManualPct == 60)
    }

    @Test("clampBrightness maps the boundaries", arguments: [
        (UInt8(0), UInt8(5)), (3, 5), (5, 5), (50, 50), (100, 100), (101, 100), (255, 100),
    ])
    func brightnessBoundaries(input: UInt8, expected: UInt8) {
        #expect(DeviceSettings.clampBrightness(input) == expected)
    }

    // MARK: - Malformed payloads

    @Test("Payloads shorter than 12 bytes are rejected", arguments: [0, 1, 8, 11])
    func shortSettingsRejected(length: Int) {
        let bytes = [UInt8](GoldenVectors.settingsPayload.prefix(length))
        #expect(DeviceSettings(data: GoldenVectors.data(bytes)) == nil)
    }

    @Test("An undefined fan mode is surfaced as nil, not coerced to a real mode")
    func undefinedFanModeIsNil() throws {
        var bytes = GoldenVectors.settingsPayload
        bytes[GATT.SettingsOffset.fanMode] = 7
        let settings = try #require(DeviceSettings(data: GoldenVectors.data(bytes)))
        #expect(settings.fanMode == nil)
        // It re-encodes as Auto rather than as a value firmware would reject.
        #expect([UInt8](settings.encoded)[GATT.SettingsOffset.fanMode] == FanMode.auto.wire)
    }

    // MARK: - Threshold validation (§1.3)

    @Test("Defaults are monotonic and in range")
    func defaultsAreValid() {
        #expect(VOCThresholds.defaults.isMonotonic)
        #expect(VOCThresholds.defaults.isInRange)
        #expect(VOCThresholds.defaults.isValid)
    }

    @Test("Non-monotonic thresholds are rejected")
    func nonMonotonicRejected() {
        #expect(!VOCThresholds(lo: 200, med: 150, hi: 250, max: 400).isMonotonic)
        #expect(!VOCThresholds(lo: 100, med: 100, hi: 250, max: 400).isMonotonic)   // equal, not <
        #expect(!VOCThresholds(lo: 100, med: 150, hi: 400, max: 400).isMonotonic)
    }

    @Test("Thresholds outside the 1–500 index scale are rejected")
    func outOfRangeRejected() {
        #expect(!VOCThresholds(lo: 0, med: 150, hi: 250, max: 400).isInRange)      // 0 < min
        #expect(!VOCThresholds(lo: 100, med: 150, hi: 250, max: 501).isInRange)    // > 500
        #expect(VOCThresholds(lo: 1, med: 2, hi: 3, max: 500).isInRange)           // both ends legal
    }

    @Test("Manual 0% is recognised as the fan-off-at-next-start state (§5)")
    func manualOffDetected() {
        var settings = DeviceSettings.defaults
        settings.fanMode = .manual
        settings.fanManualPct = 0
        #expect(settings.isManualOff)

        settings.fanManualPct = 1
        #expect(!settings.isManualOff)

        settings.fanMode = .auto
        settings.fanManualPct = 0
        #expect(!settings.isManualOff)   // Auto at 0% is the controller's choice
    }

    @Test("Fan mode wire values match live byte 34 / settings byte 9")
    func fanModeWireValues() {
        #expect(FanMode.auto.wire == 0)
        #expect(FanMode.custom.wire == 1)
        #expect(FanMode.manual.wire == 2)
        #expect(FanMode(wire: 0) == .auto)
        #expect(FanMode(wire: 1) == .custom)
        #expect(FanMode(wire: 2) == .manual)
        #expect(FanMode(wire: 3) == nil)
        #expect(FanMode(wire: 255) == nil)
        // The renamed mode keeps opcode 0x0A (§1.6).
        #expect(FanMode.custom.title == "Custom")
        #expect(FanMode.custom.command == .fanCustom)
        #expect(GATT.Command.fanCustom.rawValue == 0x0A)
    }
}

@Suite("Device Name — 20-byte UTF-8 rule")
struct DeviceNameTests {

    @Test("A plain ASCII name within budget is accepted")
    func asciiNameAccepted() {
        #expect(DeviceNameRules.isValid("Bay 3 Truck"))
        #expect(DeviceNameRules.byteCount("Bay 3 Truck") == 11)
        #expect(BluetoothManager.encodedDeviceName("Bay 3 Truck")?.count == 11)
    }

    @Test("The limit is 20 BYTES, not 20 characters — multi-byte UTF-8")
    func multiByteNameCountsBytes() {
        // 13 characters, but "ä"/"ü" cost 2 bytes each and the truck emoji 4:
        // "Bäy 3 Trück 🚚" = 10 ASCII + 2×2 + 4 = 18 bytes.
        let name = "Bäy 3 Trück 🚚"
        #expect(name.count == 13)
        #expect(DeviceNameRules.byteCount(name) == 18)
        #expect(DeviceNameRules.isValid(name))
        #expect(BluetoothManager.encodedDeviceName(name)?.count == 18)

        // One more emoji pushes it to 22 bytes — over budget despite being only
        // 14 characters.
        let tooLong = name + "🚚"
        #expect(tooLong.count == 14)
        #expect(DeviceNameRules.byteCount(tooLong) == 22)
        #expect(!DeviceNameRules.isValid(tooLong))
        #expect(BluetoothManager.encodedDeviceName(tooLong) == nil)
    }

    @Test("Truncation never splits a multi-byte scalar")
    func truncationRespectsScalarBoundaries() {
        let truncated = DeviceNameRules.truncated("Bäy 3 Trück 🚚🚚")
        #expect(DeviceNameRules.byteCount(truncated) <= GATT.deviceNameMaxBytes)
        // Valid UTF-8 round-trips; a split scalar would not.
        #expect(String(decoding: Array(truncated.utf8), as: UTF8.self) == truncated)
        #expect(truncated == "Bäy 3 Trück 🚚")
    }

    @Test("A 20-byte name is accepted and a 21-byte one is not")
    func exactBoundary() {
        let twenty = String(repeating: "A", count: 20)
        let twentyOne = String(repeating: "A", count: 21)
        #expect(DeviceNameRules.isValid(twenty))
        #expect(!DeviceNameRules.isValid(twentyOne))
        #expect(BluetoothManager.encodedDeviceName(twenty)?.count == 20)
        #expect(BluetoothManager.encodedDeviceName(twentyOne) == nil)
    }

    @Test("Empty, whitespace-only and NUL-bearing names are rejected")
    func emptyAndNULRejected() {
        #expect(!DeviceNameRules.isValid(""))
        #expect(!DeviceNameRules.isValid("   "))
        #expect(!DeviceNameRules.isValid("\n\t"))
        #expect(!DeviceNameRules.isValid("Bay\0 3"))
        #expect(BluetoothManager.encodedDeviceName("") == nil)
        #expect(BluetoothManager.encodedDeviceName("   ") == nil)
    }

    @Test("Surrounding whitespace is trimmed before the length check and the write")
    func whitespaceTrimmed() {
        #expect(BluetoothManager.encodedDeviceName("  Bay 3  ") == Data("Bay 3".utf8))
        // 20 bytes of content plus padding still fits once trimmed.
        let padded = "  " + String(repeating: "A", count: 20) + "  "
        #expect(BluetoothManager.encodedDeviceName(padded)?.count == 20)
    }
}

@Suite("DeviceInfo — 40-byte payload")
struct DeviceInfoTests {

    @Test("A 40-byte payload decodes serial, firmware and versions")
    func decodesGoldenPayload() throws {
        let info = try #require(DeviceInfo(data: GoldenVectors.data(GoldenVectors.deviceInfoPayload)))
        #expect(info.serial == "SEN66-0A1B2C3D4E5F")   // NUL padding stripped
        #expect(info.firmwareMajor == 1)
        #expect(info.firmwareMinor == 4)
        #expect(info.firmwareVersionText == "1.4")
        #expect(info.contractVersion == 2)
        #expect(info.logRecordVersion == 2)
        #expect(info.isContractSupported)
    }

    @Test("A contract version other than 2 is reported, not accommodated (§9.3)")
    func wrongContractVersionFlagged() throws {
        var bytes = GoldenVectors.deviceInfoPayload
        bytes[GATT.DeviceInfoOffset.contractVersion] = 3
        let info = try #require(DeviceInfo(data: GoldenVectors.data(bytes)))
        #expect(info.contractVersion == 3)
        #expect(!info.isContractSupported)
    }

    @Test("A unit that booted without a SEN66 reports an empty serial")
    func absentSensorReportsZeros() throws {
        let info = try #require(DeviceInfo(data: Data(repeating: 0, count: 40)))
        #expect(info.serial.isEmpty)
        #expect(info.serialText == "—")
        #expect(info.contractVersion == 0)
        #expect(!info.isContractSupported)
    }

    @Test("Payloads shorter than 40 bytes are rejected", arguments: [0, 32, 39])
    func shortInfoRejected(length: Int) {
        let bytes = [UInt8](GoldenVectors.deviceInfoPayload.prefix(length))
        #expect(DeviceInfo(data: GoldenVectors.data(bytes)) == nil)
    }
}
