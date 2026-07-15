//
//  HistoryPacketParser.swift
//  Smart Air Monitor
//
//  Decodes the 31-byte history notification packets that the device streams after
//  CMD_SYNC_HISTORY (0x01). History packets share the Sensor Data characteristic
//  and are distinguished from live readings by payload[0] == 0xA5 (§2).
//
//  Packet layout:
//    byte 0    : 0xA5 marker
//    byte 1    : 0x48 marker ('H')
//    bytes 2–3 : total record count (uint16 LE) — constant across a sync session
//    bytes 4–5 : record index (uint16 LE) — 0 = oldest; index == totalCount → sentinel
//    bytes 6–27: geue_log_record_t (22 bytes)
//    bytes 28–30: reserved 0x00
//
//  geue_log_record_t layout (grew 16 → 22 bytes; PM added, firmware 2026-07-09):
//    bytes 6–7  : temperature int16 LE (°C × 100); sentinel 0x8000
//    bytes 8–9  : humidity uint16 LE (% × 100); sentinel 0xFFFF
//    bytes 10–11: TVOC uint16 LE (ppb); sentinel 0xFFFF
//    bytes 12–13: eCO₂ uint16 LE (ppm); sentinel 0xFFFF
//    byte 14    : AQI uint8 (0–5)
//    byte 15    : status uint8 (same bitfield as Sensor char byte 24)
//    bytes 16–17: sequence uint16 LE
//    bytes 18–21: Unix timestamp uint32 LE
//    bytes 22–23: PM1.0 uint16 LE (µg/m³); sentinels 0xFFFF / 0xFFFE
//    bytes 24–25: PM2.5 uint16 LE (µg/m³); sentinels 0xFFFF / 0xFFFE
//    bytes 26–27: PM10  uint16 LE (µg/m³); sentinels 0xFFFF / 0xFFFE
//

import Foundation

enum HistoryPacketParser {

    struct Packet {
        let totalCount:  Int
        let recordIndex: Int
        /// nil when this is the end-of-sync sentinel (recordIndex == totalCount).
        let fields: HistoryRecordFields?
    }

    static func parse(_ data: Data) -> Packet? {
        let b = [UInt8](data)
        guard b.count >= GATT.sensorPayloadLength,
              b[0] == GATT.historyPacketMarker,
              b[1] == GATT.historyHeaderMarker else { return nil }

        let totalCount  = Int(readUInt16LE(b, GATT.historyTotalCountOffset))
        let recordIndex = Int(readUInt16LE(b, GATT.historyRecordIndexOffset))

        if recordIndex == totalCount {
            return Packet(totalCount: totalCount, recordIndex: recordIndex, fields: nil)
        }

        let r = GATT.historyRecordOffset
        let tempRaw  = readInt16LE(b, r + 0)
        let humRaw   = readUInt16LE(b, r + 2)
        let tvocRaw  = readUInt16LE(b, r + 4)
        let eco2Raw  = readUInt16LE(b, r + 6)
        let aqiByte  = b[r + 8]
        let statByte = b[r + 9]
        let seqRaw   = readUInt16LE(b, r + 10)
        let tsRaw    = readUInt32LE(b, r + 12)
        let pm1Raw   = readUInt16LE(b, r + 16)   // record bytes 16–17
        let pm25Raw  = readUInt16LE(b, r + 18)   // record bytes 18–19
        let pm10Raw  = readUInt16LE(b, r + 20)   // record bytes 20–21

        let fields = HistoryRecordFields(
            timestamp:    Date(timeIntervalSince1970: TimeInterval(tsRaw)),
            temperatureC: tempRaw == Int16(bitPattern: 0x8000) ? nil : Double(tempRaw) / 100.0,
            humidityPct:  humRaw  == 0xFFFF ? nil : Double(humRaw) / 100.0,
            tvocPpb:      tvocRaw == 0xFFFF ? nil : Int(tvocRaw),
            eco2Ppm:      eco2Raw == 0xFFFF ? nil : Int(eco2Raw),
            aqi:          Int(aqiByte),
            status:       statByte,
            sequence:     seqRaw,
            pm1:          GATT.decodePM(pm1Raw),   // 0xFFFF / 0xFFFE → nil (shared rule)
            pm25:         GATT.decodePM(pm25Raw),
            pm10:         GATT.decodePM(pm10Raw)
        )
        return Packet(totalCount: totalCount, recordIndex: recordIndex, fields: fields)
    }

    private static func readUInt16LE(_ b: [UInt8], _ i: Int) -> UInt16 {
        UInt16(b[i]) | (UInt16(b[i + 1]) << 8)
    }

    private static func readUInt32LE(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) | (UInt32(b[i + 1]) << 8) | (UInt32(b[i + 2]) << 16) | (UInt32(b[i + 3]) << 24)
    }

    private static func readInt16LE(_ b: [UInt8], _ i: Int) -> Int16 {
        Int16(bitPattern: readUInt16LE(b, i))
    }
}
