//
//  HistoryPacketParserTests.swift
//  G2-iOSTests
//
//  Golden-vector tests for the 34-byte history packet and its 26-byte log
//  record v2 (§7). Length is the only thing separating a v2 packet from the
//  retired 31-byte v1 one on the wire, so the rejection cases matter as much as
//  the decode.
//

import Foundation
import Testing
@testable import G2_iOS

@Suite("HistoryPacketParser — history packet v2")
struct HistoryPacketParserTests {

    // MARK: - Record decode

    @Test("A 34-byte history packet decodes every log-record v2 field")
    func historyRecordDecodes() throws {
        guard case .record(let f, let index, let total) =
                try #require(HistoryPacketParser.parse(GoldenVectors.data(GoldenVectors.historyPacket)))
        else {
            Issue.record("expected a record packet")
            return
        }

        #expect(index == 1)
        #expect(total == 3)

        #expect(f.timestamp == GoldenVectors.historyTimestamp)
        #expect(f.temperatureC == 21.0)
        #expect(f.humidityPct == 52.5)
        #expect(f.vocIndex == 88.0)
        #expect(f.noxIndex == 9.5)
        #expect(f.co2Ppm == 540)
        #expect(f.pm1 == 4.0)
        #expect(f.pm25 == 7.2)
        #expect(f.pm4 == 9.1)
        #expect(f.pm10 == 12.0)
        #expect(f.aqClass == 2)
        #expect(f.status == 0x0B)
        #expect(f.sequence == 777)
    }

    @Test("Record status decodes with the same bit map as the live packet")
    func recordStatusSharesTheLiveBitMap() throws {
        guard case .record(let f, _, _) =
                try #require(HistoryPacketParser.parse(GoldenVectors.data(GoldenVectors.historyPacket)))
        else { return }
        let status = DeviceStatus(raw: f.status)
        #expect(status.sen66Present)
        #expect(status.isFresh)
        #expect(status.twaiOnline)
        #expect(!status.sen66Warming)
        #expect(!status.ionizerIsOn)
    }

    // MARK: - Sentinels inside a record

    @Test("Sentinel fields inside a record decode to nil, including PM 0xFFFE")
    func recordSentinels() throws {
        var bytes = GoldenVectors.historyPacket
        let r = GATT.historyRecordOffset
        let f = GATT.HistoryRecordOffset.self
        // INT16_MIN temperature; 0xFFFF humidity/VOC/NOx/CO2; 0xFFFE PM.
        bytes[r + f.temperature] = 0x00; bytes[r + f.temperature + 1] = 0x80
        for offset in [f.humidity, f.vocIndex, f.noxIndex, f.co2] {
            bytes[r + offset] = 0xFF; bytes[r + offset + 1] = 0xFF
        }
        for offset in [f.pm1, f.pm25, f.pm4, f.pm10] {
            bytes[r + offset] = 0xFE; bytes[r + offset + 1] = 0xFF
        }

        guard case .record(let fields, _, _) =
                try #require(HistoryPacketParser.parse(GoldenVectors.data(bytes)))
        else { return }

        #expect(fields.temperatureC == nil)
        #expect(fields.humidityPct == nil)
        #expect(fields.vocIndex == nil)
        #expect(fields.noxIndex == nil)
        #expect(fields.co2Ppm == nil)
        #expect(fields.pm1 == nil)
        #expect(fields.pm25 == nil)
        #expect(fields.pm4 == nil)
        #expect(fields.pm10 == nil)
        // Framing survives — the record is still a record, not a sentinel.
        #expect(fields.sequence == 777)
    }

    // MARK: - End-of-sync sentinel

    @Test("The all-zero record sentinel is reported as endOfSync, not as a record")
    func endOfSyncSentinel() throws {
        let packet = try #require(
            HistoryPacketParser.parse(GoldenVectors.data(GoldenVectors.historySentinelPacket)))
        guard case .endOfSync = packet else {
            Issue.record("an all-zero record must decode as endOfSync, got \(packet)")
            return
        }
    }

    @Test("A record that is zero except for one byte is NOT the sentinel")
    func nearlyZeroRecordIsNotSentinel() throws {
        var bytes = GoldenVectors.historySentinelPacket
        bytes[GATT.historyRecordOffset + GATT.HistoryRecordOffset.aqClass] = 1
        guard case .record = try #require(HistoryPacketParser.parse(GoldenVectors.data(bytes))) else {
            Issue.record("only an entirely zero record is the end-of-sync sentinel")
            return
        }
    }

    // MARK: - Rejections

    @Test("A 31-byte v1 history packet is rejected — length is the version signal")
    func legacy31ByteHistoryRejected() {
        // Correct markers, v1 length: exactly what pre-SEN66 firmware streams.
        var bytes = [UInt8](repeating: 0, count: 31)
        bytes[0] = GATT.historyPacketMarker
        bytes[1] = GATT.historyHeaderMarker
        bytes[2] = 3
        bytes[5] = 1
        bytes[12] = 0x42   // non-zero inside the v1 record, so it isn't a sentinel
        #expect(HistoryPacketParser.parse(GoldenVectors.data(bytes)) == nil)
    }

    @Test("A live v2 packet reaching the history parser is rejected on its marker")
    func livePacketRejected() {
        #expect(HistoryPacketParser.parse(GoldenVectors.data(GoldenVectors.validLivePacket)) == nil)
    }

    @Test("A wrong 'H' header byte is rejected")
    func wrongHeaderByteRejected() {
        var bytes = GoldenVectors.historyPacket
        bytes[1] = 0x49
        #expect(HistoryPacketParser.parse(GoldenVectors.data(bytes)) == nil)
    }

    @Test("Short history payloads are rejected without crashing", arguments: [0, 2, 8, 33])
    func shortHistoryPayloadsRejected(length: Int) {
        let bytes = [UInt8](GoldenVectors.historyPacket.prefix(length))
        #expect(HistoryPacketParser.parse(GoldenVectors.data(bytes)) == nil)
    }
}

