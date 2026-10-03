//
//  ThresholdsBlobTests.swift
//  G2-iOSTests
//
//  The 60-byte Thresholds characteristic (firmware thresholds-v3 §2.2):
//  golden-vector pack/unpack, round trips, and every firmware validation rule
//  in both its passing and failing form — including the six rejection cases
//  from firmware §4 item 9. `validate()` must be exactly as strict as firmware:
//  never looser (the write would bounce off an ATT error), never stricter (a
//  blob the device holds would be uneditable).
//

import Foundation
import Testing
@testable import G2_iOS

@Suite("ThresholdsBlob — 60-byte thresholds characteristic")
struct ThresholdsBlobTests {

    /// `GoldenVectors.thresholdsNonDefaultPayload`, field by field.
    private static let nonDefault = ThresholdsBlob(
        version: 1,
        vocEdges: [5, 16, 27, 38],
        noxEdges: [10, 40, 300, 500],
        co2Edges: [400, 1200, 5000, 40000],
        pm1Attention: 51, pm1Hazard: 123,
        pm25Attention: 100, pm25Hazard: 555,
        pm10Attention: 60, pm10Hazard: 2000,
        fanGas: [10, 20, 30, 40, 100],
        fanPM: [0, 60, 99],
        fanDownDelaySeconds: 3600,
        ionizerRunOnMinutes: 1440,
        hysteresisVOC: 4,
        hysteresisNOx: 9,
        hysteresisCO2: 399,
        hysteresisPM: 50
    )

    // MARK: - Golden vectors

    @Test("Defaults pack byte for byte to the §2.2 golden vector")
    func defaultsPackToGolden() {
        let packed = [UInt8](ThresholdsBlob.defaults.pack())
        #expect(packed.count == 60)
        #expect(packed == GoldenVectors.thresholdsDefaultsPayload)
    }

    @Test("The defaults golden vector unpacks to exactly the documented defaults")
    func goldenUnpacksToDefaults() throws {
        let blob = try #require(ThresholdsBlob.unpack(GoldenVectors.data(GoldenVectors.thresholdsDefaultsPayload)))
        #expect(blob == .defaults)
        #expect(blob.version == 1)
        #expect(blob.vocEdges == [100, 150, 250, 350])
        #expect(blob.noxEdges == [20, 50, 100, 200])
        #expect(blob.co2Edges == [800, 1000, 1500, 2000])
        #expect(blob.pm1Attention == 70 && blob.pm1Hazard == 250)       // 7.0 / 25.0
        #expect(blob.pm25Attention == 90 && blob.pm25Hazard == 350)     // 9.0 / 35.0
        #expect(blob.pm10Attention == 450 && blob.pm10Hazard == 1500)   // 45.0 / 150.0
        #expect(blob.fanGas == [0, 25, 50, 75, 100])
        #expect(blob.fanPM == [20, 50, 100])
        #expect(blob.fanDownDelaySeconds == 0)
        #expect(blob.ionizerRunOnMinutes == 60)
        #expect(blob.hysteresisVOC == 0 && blob.hysteresisNOx == 0)
        #expect(blob.hysteresisCO2 == 0 && blob.hysteresisPM == 0)
        #expect(blob.validate() == nil)
    }

    @Test("A blob with every field off-default packs and unpacks against its golden vector")
    func nonDefaultGoldenVector() throws {
        #expect([UInt8](Self.nonDefault.pack()) == GoldenVectors.thresholdsNonDefaultPayload)
        let decoded = try #require(ThresholdsBlob.unpack(GoldenVectors.data(GoldenVectors.thresholdsNonDefaultPayload)))
        #expect(decoded == Self.nonDefault)
        #expect(decoded.validate() == nil)
    }

    // MARK: - Round trips

    @Test("unpack(pack(x)) == x and pack(unpack(bytes)) == bytes")
    func roundTrips() throws {
        for blob in [ThresholdsBlob.defaults, Self.nonDefault] {
            #expect(ThresholdsBlob.unpack(blob.pack()) == blob)
        }
        for bytes in [GoldenVectors.thresholdsDefaultsPayload, GoldenVectors.thresholdsNonDefaultPayload] {
            let blob = try #require(ThresholdsBlob.unpack(Data(bytes)))
            #expect([UInt8](blob.pack()) == bytes)
        }
    }

    @Test("A Data slice with a non-zero start index unpacks from the right offset")
    func slicedDataUnpacks() throws {
        let padded = Data([0xDE, 0xAD]) + Data(GoldenVectors.thresholdsNonDefaultPayload)
        let blob = try #require(ThresholdsBlob.unpack(padded.dropFirst(2)))
        #expect(blob == Self.nonDefault)
    }

    @Test("Every field lands at its §2.2 byte offset, little-endian, touching nothing else",
          arguments: ThresholdsBlob.Field.allCases)
    func fieldOffsets(field: ThresholdsBlob.Field) {
        // Offsets written out from the §2.2 table, not taken from GATT.
        let offset: Int
        switch field {
        case .gasEdge(.voc, let i): offset = 2 + 2 * i
        case .gasEdge(.nox, let i): offset = 10 + 2 * i
        case .gasEdge(.co2, let i): offset = 18 + 2 * i
        case .pmAttention(.pm1):    offset = 26
        case .pmHazard(.pm1):       offset = 28
        case .pmAttention(.pm25):   offset = 30
        case .pmHazard(.pm25):      offset = 32
        case .pmAttention(.pm10):   offset = 34
        case .pmHazard(.pm10):      offset = 36
        case .fanGas(let i):        offset = 38 + i
        case .fanPM(let i):         offset = 43 + i
        case .fanDownDelay:         offset = 46
        case .ionizerRunOn:         offset = 48
        case .hysteresis(.voc):     offset = 50
        case .hysteresis(.nox):     offset = 52
        case .hysteresis(.co2):     offset = 54
        case .hysteresisPM:         offset = 56
        }
        let isByte: Bool
        switch field {
        case .fanGas, .fanPM: isByte = true
        default:              isByte = false
        }

        var blob = ThresholdsBlob.defaults
        blob[field] = isByte ? 0x5A : 0xA55A
        #expect(blob[field] == (isByte ? 0x5A : 0xA55A))

        let base = [UInt8](ThresholdsBlob.defaults.pack())
        let packed = [UInt8](blob.pack())
        #expect(packed[offset] == 0x5A)
        if !isByte { #expect(packed[offset + 1] == 0xA5) }
        let touched = isByte ? [offset] : [offset, offset + 1]
        for i in packed.indices where !touched.contains(i) {
            #expect(packed[i] == base[i], "byte \(i) changed when setting \(field)")
        }
    }

    @Test("Field.allCases covers all 32 editable numbers once each")
    func fieldInventory() {
        let all = ThresholdsBlob.Field.allCases
        #expect(all.count == 12 + 6 + 5 + 3 + 2 + 3 + 1)
        #expect(Set(all).count == all.count)
        #expect(all.filter(\.isTenths).count == 7)   // six PM edges + PM hysteresis
        #expect(ThresholdsBlob.Field.fanGas(0).wireMax == 255)
        #expect(ThresholdsBlob.Field.gasEdge(.co2, 3).wireMax == 65535)
    }

    // MARK: - Length and reserved bytes

    @Test("Firmware §4.9 case 1: anything but exactly 60 bytes is not a blob",
          arguments: [0, 12, 59, 61, 120])
    func wrongLengthRejected(length: Int) {
        let bytes = Array(GoldenVectors.thresholdsDefaultsPayload.prefix(length))
            + [UInt8](repeating: 0, count: Swift.max(0, length - 60))
        #expect(bytes.count == length)
        #expect(ThresholdsBlob.unpack(Data(bytes)) == nil)
        #expect(GATT.thresholdsPayloadLength == 60)
    }

    @Test("pack() always writes exactly 60 bytes, even from malformed arrays")
    func packIsAlwaysSixtyBytes() {
        var blob = ThresholdsBlob.defaults
        blob.vocEdges = [1, 2]              // short — padded with zeros
        blob.fanPM = [1, 2, 3, 4, 5]        // long — truncated
        let packed = [UInt8](blob.pack())
        #expect(packed.count == 60)
        #expect(Array(packed[2..<10]) == [0x01, 0x00, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00])
        #expect(Array(packed[43..<46]) == [1, 2, 3])
        // validate() sees the same four values pack() writes: 1, 2, 0, 0.
        #expect(blob.validate() == .edgesNotIncreasing(.voc))
    }

    @Test("Reserved bytes are ignored on read and written as zero")
    func reservedBytes() throws {
        var bytes = GoldenVectors.thresholdsDefaultsPayload
        bytes[1] = 0xAB
        bytes[58] = 0xCD
        bytes[59] = 0xEF
        let blob = try #require(ThresholdsBlob.unpack(Data(bytes)))
        #expect(blob == .defaults)          // reserved content carries no meaning
        #expect(blob.validate() == nil)     // and is not a validation failure
        let packed = [UInt8](blob.pack())
        #expect(packed[1] == 0 && packed[58] == 0 && packed[59] == 0)
        #expect(packed == GoldenVectors.thresholdsDefaultsPayload)
    }

    // MARK: - Firmware §4 item 9 — the six documented rejections

    @Test("Firmware §4.9 case 2: version = 2 is rejected")
    func firmwareCaseVersion2() {
        var blob = ThresholdsBlob.defaults
        blob.version = 2
        #expect(blob.validate() == .unsupportedVersion(2))
    }

    @Test("Firmware §4.9 case 3: voc_edge = 100/100/250/350 is rejected")
    func firmwareCaseVOCNotIncreasing() {
        var blob = ThresholdsBlob.defaults
        blob.vocEdges = [100, 100, 250, 350]
        #expect(blob.validate() == .edgesNotIncreasing(.voc))
    }

    @Test("Firmware §4.9 case 4: fan_gas[0] = 101 is rejected")
    func firmwareCaseFanGas101() {
        var blob = ThresholdsBlob.defaults
        blob.fanGas[0] = 101
        #expect(blob.validate() == .fanGasAboveMax(gasClass: 1))
    }

    @Test("Firmware §4.9 case 5: hyst_co2 = 200 with co2_edge 800/1000/1500/2000 is rejected")
    func firmwareCaseCO2Hysteresis() {
        var blob = ThresholdsBlob.defaults
        #expect(blob.co2Edges == [800, 1000, 1500, 2000])
        blob.hysteresisCO2 = 200
        #expect(blob.validate() == .hysteresisTooLarge(.co2, smallestGap: 200))
    }

    @Test("Firmware §4.9 case 6: fan_down_delay_s = 3601 is rejected")
    func firmwareCaseDelay3601() {
        var blob = ThresholdsBlob.defaults
        blob.fanDownDelaySeconds = 3601
        #expect(blob.validate() == .fanDownDelayAboveMax)
    }

    // MARK: - Every rule, passing and failing

    @Test("version must be exactly 1", arguments: [UInt8(0), 2, 3, 255])
    func versionRule(bad: UInt8) {
        var blob = ThresholdsBlob.defaults
        #expect(blob.validate() == nil)
        blob.version = bad
        #expect(blob.validate() == .unsupportedVersion(bad))
    }

    @Test("Each gas row must be strictly increasing", arguments: ThresholdsBlob.GasChannel.allCases)
    func strictlyIncreasing(channel: ThresholdsBlob.GasChannel) {
        // Equal neighbours at each position, then a decrease, all fail.
        let failing: [[UInt16]] = [[10, 10, 30, 40], [10, 20, 20, 40], [10, 20, 30, 30], [10, 30, 20, 40], [40, 30, 20, 10]]
        for edges in failing {
            var blob = ThresholdsBlob.defaults
            set(&blob, channel, edges)
            #expect(blob.validate() == .edgesNotIncreasing(channel), "\(edges)")
        }
        var blob = ThresholdsBlob.defaults
        set(&blob, channel, [10, 20, 30, 40])
        #expect(blob.validate() == nil)
    }

    @Test("No lower bound on edges: C1 may be 0, consecutive integers are fine",
          arguments: ThresholdsBlob.GasChannel.allCases)
    func noLowerBound(channel: ThresholdsBlob.GasChannel) {
        var blob = ThresholdsBlob.defaults
        set(&blob, channel, [0, 1, 2, 3])
        #expect(blob.validate() == nil)
        set(&blob, channel, [5, 6, 7, 8])   // the acceptance test's "gas tile goes red" edges
        #expect(blob.validate() == nil)
    }

    @Test("C4 ceiling: VOC 500, NOx 500, CO2 40000", arguments: [
        (ThresholdsBlob.GasChannel.voc, UInt16(500)), (.nox, 500), (.co2, 40000),
    ])
    func edgeCeiling(channel: ThresholdsBlob.GasChannel, max: UInt16) {
        #expect(channel.edgeMax == max)
        var blob = ThresholdsBlob.defaults
        set(&blob, channel, [1, 2, 3, max])
        #expect(blob.validate() == nil)
        set(&blob, channel, [1, 2, 3, max + 1])
        #expect(blob.validate() == .edgeAboveMax(channel, max: max))
    }

    @Test("Gas hysteresis must stay below the smallest adjacent-edge gap",
          arguments: ThresholdsBlob.GasChannel.allCases)
    func gasHysteresis(channel: ThresholdsBlob.GasChannel) {
        var blob = ThresholdsBlob.defaults
        // Gaps 100 / 10 / 190: the smallest is in the middle, not first.
        set(&blob, channel, [100, 200, 210, 400])
        setHysteresis(&blob, channel, 9)
        #expect(blob.validate() == nil)
        setHysteresis(&blob, channel, 10)
        #expect(blob.validate() == .hysteresisTooLarge(channel, smallestGap: 10))
        setHysteresis(&blob, channel, 0)
        #expect(blob.validate() == nil)
    }

    @Test("Default edges allow hysteresis up to min(gap, C1) − 1 per gas", arguments: [
        (ThresholdsBlob.GasChannel.voc, UInt16(50), UInt16(100)), (.nox, 30, 20), (.co2, 200, 800),
    ])
    func defaultGaps(channel: ThresholdsBlob.GasChannel, gap: UInt16, c1: UInt16) {
        var blob = ThresholdsBlob.defaults
        let limit = min(gap, c1)
        setHysteresis(&blob, channel, limit - 1)
        #expect(blob.validate() == nil)
        setHysteresis(&blob, channel, limit)
        #expect(blob.validate() == (gap <= c1
            ? .hysteresisTooLarge(channel, smallestGap: gap)
            : .hysteresisNotBelowFirstEdge(channel, c1: c1)))
    }

    @Test("Non-zero gas hysteresis must stay below C1, or class 1 could never return",
          arguments: ThresholdsBlob.GasChannel.allCases)
    func gasHysteresisBelowFirstEdge(channel: ThresholdsBlob.GasChannel) {
        var blob = ThresholdsBlob.defaults
        // Wide gaps so only the C1 floor can bite: C1 30, then 100-wide steps.
        blob[.gasEdge(channel, 0)] = 30
        blob[.gasEdge(channel, 1)] = 130
        blob[.gasEdge(channel, 2)] = 230
        blob[.gasEdge(channel, 3)] = 330
        setHysteresis(&blob, channel, 29)
        #expect(blob.validate() == nil)
        setHysteresis(&blob, channel, 30)
        #expect(blob.validate() == .hysteresisNotBelowFirstEdge(channel, c1: 30))
        // C1 = 0 still allows hysteresis 0, and only 0.
        blob[.gasEdge(channel, 0)] = 0
        setHysteresis(&blob, channel, 0)
        #expect(blob.validate() == nil)
        setHysteresis(&blob, channel, 1)
        #expect(blob.validate() == .hysteresisNotBelowFirstEdge(channel, c1: 0))
    }

    @Test("A row that is out of order reports the ordering error, not a hysteresis one")
    func hysteresisSkippedOnBrokenRow() {
        var blob = ThresholdsBlob.defaults
        blob.noxEdges = [50, 20, 100, 200]
        blob.hysteresisNOx = 400
        #expect(blob.validationErrors() == [.edgesNotIncreasing(.nox)])
    }

    @Test("PM attention must be below hazard", arguments: ThresholdsBlob.PMChannel.allCases)
    func pmAttentionBelowHazard(channel: ThresholdsBlob.PMChannel) {
        var blob = ThresholdsBlob.defaults
        let hazard = blob.hazard(channel)
        blob[.pmAttention(channel)] = hazard - 1
        #expect(blob.validate() == nil)
        blob[.pmAttention(channel)] = hazard
        #expect(blob.validate() == .attentionNotBelowHazard(channel))
        blob[.pmAttention(channel)] = hazard + 1
        #expect(blob.validate() == .attentionNotBelowHazard(channel))
        blob[.pmAttention(channel)] = 0     // no lower bound
        #expect(blob.validate() == nil)
    }

    @Test("PM hysteresis must stay below the narrowest hazard − attention band")
    func pmHysteresis() {
        var blob = ThresholdsBlob.defaults
        // Raise PM1/PM2.5 attention so only the band rule can bite: bands PM1
        // 38.0−20.0 = 18.0, PM2.5 30.0, PM10 105.0 → 18.0 (180); lowest attention 20.0.
        blob.pm1Attention = 200;  blob.pm1Hazard = 380
        blob.pm25Attention = 200; blob.pm25Hazard = 500
        blob.hysteresisPM = 179
        #expect(blob.validate() == nil)
        blob.hysteresisPM = 180
        #expect(blob.validate() == .pmHysteresisTooLarge(smallestBand: 180))

        // Make PM10 the narrowest (2.0) — the rule follows it.
        blob.pm10Attention = 1480
        blob.hysteresisPM = 19
        #expect(blob.validate() == nil)
        blob.hysteresisPM = 20
        #expect(blob.validate() == .pmHysteresisTooLarge(smallestBand: 20))
    }

    @Test("Non-zero PM hysteresis must stay below the lowest attention edge")
    func pmHysteresisBelowAttention() {
        var blob = ThresholdsBlob.defaults
        // Defaults: lowest attention is PM1's 7.0 (70), narrowest band 18.0.
        blob.hysteresisPM = 69
        #expect(blob.validate() == nil)
        blob.hysteresisPM = 70
        #expect(blob.validate() == .pmHysteresisNotBelowAttention(smallestAttention: 70))
        blob.hysteresisPM = 100         // the review's case: PM would stick at attention
        #expect(blob.validate() == .pmHysteresisNotBelowAttention(smallestAttention: 70))
        blob.pm10Attention = 0          // attention 0 allows hysteresis 0 only
        blob.hysteresisPM = 0
        #expect(blob.validate() == nil)
        blob.hysteresisPM = 1
        #expect(blob.validate() == .pmHysteresisNotBelowAttention(smallestAttention: 0))
    }

    @Test("A broken PM pair reports the pair, not a hysteresis error")
    func pmHysteresisSkippedOnBrokenPair() {
        var blob = ThresholdsBlob.defaults
        blob.pm25Attention = 400                 // above its 350 hazard
        blob.hysteresisPM = 1000
        #expect(blob.validationErrors() == [.attentionNotBelowHazard(.pm25)])
    }

    @Test("Every fan % must be 100 or less", arguments: Array(0..<5))
    func fanGasCeiling(index: Int) {
        var blob = ThresholdsBlob.defaults
        blob.fanGas[index] = 100
        #expect(blob.validate() == nil)
        blob.fanGas[index] = 101
        #expect(blob.validate() == .fanGasAboveMax(gasClass: index + 1))
        blob.fanGas[index] = 0
        #expect(blob.validate() == nil)
    }

    @Test("Every PM fan % must be 100 or less", arguments: Array(0..<3))
    func fanPMCeiling(index: Int) {
        var blob = ThresholdsBlob.defaults
        blob.fanPM[index] = 100
        #expect(blob.validate() == nil)
        blob.fanPM[index] = 101
        #expect(blob.validate() == .fanPMAboveMax(pmClass: index + 1))
    }

    @Test("Fan-down delay: 3600 s passes, 3601 s fails")
    func fanDownDelayCeiling() {
        var blob = ThresholdsBlob.defaults
        blob.fanDownDelaySeconds = 3600
        #expect(blob.validate() == nil)
        blob.fanDownDelaySeconds = 3601
        #expect(blob.validate() == .fanDownDelayAboveMax)
    }

    @Test("Ionizer run-on: 1440 min passes, 1441 min fails")
    func ionizerRunOnCeiling() {
        var blob = ThresholdsBlob.defaults
        blob.ionizerRunOnMinutes = 1440
        #expect(blob.validate() == nil)
        blob.ionizerRunOnMinutes = 0
        #expect(blob.validate() == nil)
        blob.ionizerRunOnMinutes = 1441
        #expect(blob.validate() == .ionizerRunOnAboveMax)
    }

    // MARK: - Ordering and reporting

    @Test("validate() returns the failure firmware would hit first")
    func firstFailureFollowsFirmwareOrder() {
        var blob = ThresholdsBlob.defaults
        blob.ionizerRunOnMinutes = 2000
        blob.fanPM[2] = 150
        blob.co2Edges = [800, 800, 1500, 2000]
        #expect(blob.validate() == .edgesNotIncreasing(.co2))
        blob.version = 9
        #expect(blob.validate() == .unsupportedVersion(9))
        #expect(blob.validationErrors() == [
            .unsupportedVersion(9),
            .edgesNotIncreasing(.co2),
            .fanPMAboveMax(pmClass: 3),
            .ionizerRunOnAboveMax,
        ])
    }

    @Test("Each error is placed under its own editor row")
    func errorRows() {
        #expect(ThresholdsBlob.ValidationError.edgesNotIncreasing(.nox).row == .gasEdges(.nox))
        #expect(ThresholdsBlob.ValidationError.edgeAboveMax(.co2, max: 40000).row == .gasEdges(.co2))
        #expect(ThresholdsBlob.ValidationError.hysteresisTooLarge(.voc, smallestGap: 50).row == .hysteresis(.voc))
        #expect(ThresholdsBlob.ValidationError.attentionNotBelowHazard(.pm10).row == .pmEdges(.pm10))
        #expect(ThresholdsBlob.ValidationError.pmHysteresisTooLarge(smallestBand: 180).row == .hysteresisPM)
        #expect(ThresholdsBlob.ValidationError.fanGasAboveMax(gasClass: 2).row == .fanGas)
        #expect(ThresholdsBlob.ValidationError.fanPMAboveMax(pmClass: 1).row == .fanPM)
        #expect(ThresholdsBlob.ValidationError.fanDownDelayAboveMax.row == .fanDownDelay)
        #expect(ThresholdsBlob.ValidationError.ionizerRunOnAboveMax.row == .ionizerRunOn)
        #expect(ThresholdsBlob.ValidationError.unsupportedVersion(2).row == .version)
    }

    @Test("Messages name the field, and PM values read in µg/m³")
    func messages() {
        #expect(ThresholdsBlob.ValidationError.edgesNotIncreasing(.co2).message.contains("CO₂"))
        #expect(ThresholdsBlob.ValidationError.pmHysteresisTooLarge(smallestBand: 180).message.contains("18.0 µg/m³"))
        #expect(ThresholdsBlob.ValidationError.fanGasAboveMax(gasClass: 4).message.contains("gas class 4"))
    }

    @Test("Never stricter than firmware: every boundary at once still validates")
    func boundariesValidateTogether() {
        let blob = ThresholdsBlob(
            version: 1,
            vocEdges: [0, 1, 2, 500],
            noxEdges: [0, 250, 499, 500],
            co2Edges: [0, 20000, 39999, 40000],
            pm1Attention: 0, pm1Hazard: 1,
            pm25Attention: 0, pm25Hazard: 65535,
            pm10Attention: 65534, pm10Hazard: 65535,
            fanGas: [100, 100, 100, 100, 100],
            fanPM: [100, 100, 100],
            fanDownDelaySeconds: 3600,
            ionizerRunOnMinutes: 1440,
            hysteresisVOC: 0,       // smallest VOC gap is 1
            hysteresisNOx: 0,       // smallest NOx gap is 1
            hysteresisCO2: 0,       // smallest CO2 gap is 1
            hysteresisPM: 0         // narrowest PM band is 0.1
        )
        #expect(blob.validate() == nil)
        #expect(ThresholdsBlob.unpack(blob.pack()) == blob)
    }

    @Test("tenthsText renders ×10 wire values with exactly one decimal")
    func tenthsText() {
        #expect(ThresholdsBlob.tenthsText(0) == "0.0")
        #expect(ThresholdsBlob.tenthsText(25) == "2.5")
        #expect(ThresholdsBlob.tenthsText(250) == "25.0")
        #expect(ThresholdsBlob.tenthsText(65535) == "6553.5")
    }

    // MARK: - Helpers

    private func set(_ blob: inout ThresholdsBlob, _ channel: ThresholdsBlob.GasChannel, _ edges: [UInt16]) {
        for (i, edge) in edges.enumerated() { blob[.gasEdge(channel, i)] = edge }
    }

    private func setHysteresis(_ blob: inout ThresholdsBlob, _ channel: ThresholdsBlob.GasChannel, _ value: UInt16) {
        blob[.hysteresis(channel)] = value
    }
}
