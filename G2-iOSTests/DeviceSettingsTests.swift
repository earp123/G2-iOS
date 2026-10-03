//
//  DeviceSettingsTests.swift
//  G2-iOSTests
//
//  Round-trip and validation tests for the 12-byte Settings payload (contract
//  v3: bytes 0–7 retired), the fan-mode wire mapping, command opcodes, the Device
//  Name length rule, and the 40-byte Device Info payload and its version guard
//  (§7; thresholds-v3 §2).
//

import Foundation
import Testing
@testable import G2_iOS

@Suite("DeviceSettings — 12-byte settings payload v3")
struct DeviceSettingsTests {

    @Test("A 12-byte payload decodes to its documented fields")
    func decodesGoldenPayload() throws {
        let settings = try #require(DeviceSettings(data: GoldenVectors.data(GoldenVectors.settingsPayload)))
        #expect(settings == .defaults)
        #expect(settings.ledBrightnessPct == 50)
        #expect(settings.fanMode == .auto)
        #expect(settings.fanManualPct == 0)
    }

    @Test("Encode → decode round-trips every field")
    func encodeDecodeRoundTrip() throws {
        let original = DeviceSettings(ledBrightnessPct: 35, fanMode: .manual, fanManualPct: 60)
        let encoded = original.encoded
        #expect(encoded.count == GATT.settingsPayloadLength)

        let decoded = try #require(DeviceSettings(data: encoded))
        #expect(decoded == original)
        #expect(decoded.ledBrightnessPct == 35)
        #expect(decoded.fanMode == .manual)
        #expect(decoded.fanManualPct == 60)
    }

    @Test("The encoded payload matches the documented byte layout exactly")
    func encodedLayoutMatchesContract() {
        let encoded = [UInt8](DeviceSettings.defaults.encoded)
        #expect(encoded == GoldenVectors.settingsPayload)
        let o = GATT.SettingsOffset.self
        #expect(Array(encoded[o.retired ..< o.retired + o.retiredLength]) == [UInt8](repeating: 0, count: 8))
        #expect(encoded[o.ledBrightness] == 50)
        #expect(encoded[o.fanMode] == FanMode.auto.wire)
        #expect(encoded[o.fanManualPct] == 0)
        #expect(encoded[o.reserved] == 0)
        #expect(encoded.count == 12)
    }

    @Test("Retired bytes 0–7 are ignored on read and always written as zero")
    func retiredBytesAreZeroOnWrite() throws {
        let settings = try #require(
            DeviceSettings(data: GoldenVectors.data(GoldenVectors.settingsPayloadWithRetiredBytes)))
        #expect(settings.ledBrightnessPct == 50)
        #expect(settings.fanMode == .manual)
        #expect(settings.fanManualPct == 60)
        // The old VOC thresholds 100/150/250/400 are not carried forward.
        #expect([UInt8](settings.encoded) == [
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x32, 0x02, 0x3C, 0x00,
        ])
    }

    @Test("Every 12-byte write zeroes bytes 0–7, whatever the other fields hold")
    func everyWriteZeroesRetiredBytes() {
        for mode in [FanMode.auto, .manual] {
            for pct in [UInt8(0), 1, 60, 100, 255] {
                let bytes = [UInt8](DeviceSettings(ledBrightnessPct: 77, fanMode: mode, fanManualPct: pct).encoded)
                #expect(bytes.count == 12)
                #expect(bytes[0..<8].allSatisfy { $0 == 0 })
                #expect(bytes[GATT.SettingsOffset.fanMode] == mode.wire)
            }
        }
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
}

@Suite("FanMode — Auto / Manual, Custom retired")
struct FanModeTests {

    @Test("Wire values match live byte 34 / settings byte 9: 0 Auto, 2 Manual")
    func fanModeWireValues() {
        #expect(FanMode.auto.wire == 0)
        #expect(FanMode.manual.wire == 2)
        #expect(FanMode(wire: 0) == .auto)
        #expect(FanMode(wire: 2) == .manual)
        #expect(FanMode(wire: 3) == nil)
        #expect(FanMode(wire: 255) == nil)
    }

    @Test("The picker offers exactly Auto and Manual")
    func onlyAutoAndManual() {
        #expect(FanMode.allCases == [.auto, .manual])
        #expect(FanMode.allCases.map(\.title) == ["Auto", "Manual"])
        #expect(FanMode(rawValue: FanMode.retiredCustomWire) == nil)   // no case for 1
        #expect(FanMode.auto.command == .fanAuto)
        #expect(FanMode.manual.command == nil)
    }

    @Test("Byte value 1 (retired Custom) decodes as Auto and fires the debug-assertion hook")
    func retiredCustomDecodesAsAuto() {
        var hookFired = false
        let mode = FanMode(wire: 1, onRetiredCustom: { hookFired = true })
        #expect(mode == .auto)
        #expect(hookFired)
    }

    @Test("Defined values never fire the retired-value hook", arguments: [UInt8(0), 2, 3, 255])
    func definedValuesDoNotFireHook(wire: UInt8) {
        var hookFired = false
        _ = FanMode(wire: wire, onRetiredCustom: { hookFired = true })
        #expect(!hookFired)
    }

    @Test("No settings write can carry fan mode 1, which firmware rejects")
    func settingsNeverEncodeOne() {
        for mode in [FanMode.auto, .manual, nil] {
            let byte = [UInt8](DeviceSettings(ledBrightnessPct: 50, fanMode: mode, fanManualPct: 0).encoded)[
                GATT.SettingsOffset.fanMode]
            #expect(byte != FanMode.retiredCustomWire)
        }
    }
}

@Suite("Commands — opcode parameters")
struct CommandTests {

    @Test("The CO₂ recalibration reference the app sends is inside the accepted range")
    func co2ReferenceInRange() {
        #expect(GATT.co2RecalibrationRange == 350...2000)
        #expect(GATT.co2RecalibrationRange.contains(GATT.co2RecalibrationReferencePpm))
        #expect(GATT.co2RecalibrationReferencePpm == 400)
        // Boundaries firmware accepts, and the first value outside each end.
        #expect(GATT.co2RecalibrationRange.contains(350))
        #expect(GATT.co2RecalibrationRange.contains(2000))
        #expect(!GATT.co2RecalibrationRange.contains(349))
        #expect(!GATT.co2RecalibrationRange.contains(2001))
    }

    @Test("New v2 opcodes carry their documented values")
    func newOpcodes() {
        #expect(GATT.Command.fanCleaning.rawValue == 0x0D)
        #expect(GATT.Command.co2Recal.rawValue == 0x0E)
        #expect(GATT.Command.clearErrors.rawValue == 0x0F)
    }

    @Test("v3: 0x10 restores thresholds; 0x0A (Custom) no longer exists to be sent")
    func v3Opcodes() {
        #expect(GATT.Command.restoreThresholds.rawValue == 0x10)
        #expect(GATT.Command(rawValue: 0x10) == .restoreThresholds)
        #expect(GATT.Command(rawValue: 0x0A) == nil)
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
        #expect(info.contractVersion == 3)
        #expect(info.logRecordVersion == 3)
        #expect(info.isContractSupported)
    }

    @Test("This build implements contract 3 / log record 3")
    func buildVersions() {
        #expect(GATT.contractVersion == 3)
        #expect(GATT.historyRecordVersion == 3)
    }

    @Test("Guard: 3 / 3 is accepted")
    func guardAcceptsV3() throws {
        let info = try #require(DeviceInfo(data: GoldenVectors.data(GoldenVectors.deviceInfoPayload)))
        #expect(!info.requiresUpdate)
    }

    @Test("Guard: 2 / 2 lands in the update-required state (§9.3)")
    func guardRefusesV2() throws {
        let info = try #require(DeviceInfo(data: GoldenVectors.data(GoldenVectors.deviceInfoPayloadV2)))
        #expect(info.contractVersion == 2)
        #expect(info.logRecordVersion == 2)
        #expect(!info.isContractSupported)
        #expect(info.requiresUpdate)
    }

    @Test("Guard: anything but exactly 3 / 3 is refused", arguments: [
        (UInt8(3), UInt8(2)), (2, 3), (4, 4), (3, 4), (0, 0), (0, 3), (3, 0),
    ])
    func guardRefusesMixedVersions(contract: UInt8, record: UInt8) throws {
        var bytes = GoldenVectors.deviceInfoPayload
        bytes[GATT.DeviceInfoOffset.contractVersion] = contract
        bytes[GATT.DeviceInfoOffset.logRecordVersion] = record
        let info = try #require(DeviceInfo(data: GoldenVectors.data(bytes)))
        #expect(info.requiresUpdate)
    }

    @Test("A v3 unit that booted without a SEN66 still reports 3 / 3 and is accepted")
    func absentSensorKeepsVersions() throws {
        // Firmware zeroes only bytes 0–33 when the sensor is absent; the version
        // bytes are always populated (gatt-v3 notes §1).
        var bytes = [UInt8](repeating: 0, count: 40)
        bytes[GATT.DeviceInfoOffset.contractVersion] = 3
        bytes[GATT.DeviceInfoOffset.logRecordVersion] = 3
        let info = try #require(DeviceInfo(data: GoldenVectors.data(bytes)))
        #expect(info.serial.isEmpty)
        #expect(info.serialText == "—")
        #expect(info.firmwareVersionText == "0.0")
        #expect(!info.requiresUpdate)
    }

    @Test("An all-zero Device Info is not a v3 device and is refused")
    func allZeroInfoRefused() throws {
        let info = try #require(DeviceInfo(data: Data(repeating: 0, count: 40)))
        #expect(info.contractVersion == 0)
        #expect(!info.isContractSupported)
        #expect(info.requiresUpdate)
    }

    @Test("Payloads shorter than 40 bytes are rejected", arguments: [0, 32, 39])
    func shortInfoRejected(length: Int) {
        let bytes = [UInt8](GoldenVectors.deviceInfoPayload.prefix(length))
        #expect(DeviceInfo(data: GoldenVectors.data(bytes)) == nil)
    }
}
