//
//  HistoryPacketParser.swift
//  G2-iOS
//
//  Decodes the 31-byte history notification packets the device streams after a
//  sync command (0x01 full dump, 0x0C recent-N). History packets share the Sensor
//  Data characteristic and are distinguished from live readings by payload[0]
//  (BLE_HISTORY_PROTOCOL.md).
//
//  Packet framing (31 bytes, little-endian):
//    byte 0     : 0xA5 history marker (live packets have 0x02 here)
//    byte 1     : 0x48 ('H')
//    bytes 2–4  : total u24 LE — record count in THIS sync (recent-N → N)
//    bytes 5–7  : index u24 LE — 0-based position within THIS sync
//    bytes 8–29 : geue_log_record_t (22 bytes, below)
//    byte 30    : reserved 0x00
//
//  u24 total/index don't wrap for any realistic buffer (max ~16.7M records), so
//  index/total are a trustworthy progress fraction. End-of-sync is still detected
//  by the sentinel packet whose 22 record bytes are all zero (index == total on
//  that packet as well) — always sent, even for a count-0 sync.
//
//  geue_log_record_t layout (packed, timestamp FIRST — flash struct order):
//    bytes 8–11 : timestamp uint32 LE (Unix epoch seconds; may be a small
//                 seconds-since-boot value if the RTC read failed at log time —
//                 the caching layer plausibility-checks it)
//    bytes 12–13: temperature int16 LE (°C × 100); sentinel 0x8000
//    bytes 14–15: humidity uint16 LE (% × 100); sentinel 0xFFFF
//    bytes 16–17: TVOC uint16 LE (ppb); sentinel 0xFFFF
//    bytes 18–19: eCO₂ uint16 LE (ppm); sentinel 0xFFFF
//    byte 20    : AQI uint8 (UBA 1–5); 0 = invalid/warming up
//    byte 21    : status uint8 (same bitfield as the Sensor characteristic)
//    bytes 22–23: sequence uint16 LE (cross-ref only, NOT an ordering key)
//    bytes 24–25: PM1.0 uint16 LE (µg/m³); sentinels 0xFFFF / 0xFFFE
//    bytes 26–27: PM2.5 uint16 LE (µg/m³); sentinels 0xFFFF / 0xFFFE
//    bytes 28–29: PM10  uint16 LE (µg/m³); sentinels 0xFFFF / 0xFFFE
//

import Foundation

enum HistoryPacketParser {

    enum Packet: Sendable {
        /// One decoded record plus its u24 position within this sync (for progress).
        case record(HistoryRecordFields, index: Int, total: Int)
        /// End-of-sync: the 22 record bytes were all zero.
        case endOfSync
    }

    /// Returns nil if this is not a valid history packet (wrong length/markers) —
    /// e.g. a live sensor packet that reached here by mistake.
    static func parse(_ data: Data) -> Packet? {
        let b = [UInt8](data)
        guard b.count >= GATT.sensorPayloadLength,
              b[0] == GATT.historyPacketMarker,
              b[1] == GATT.historyHeaderMarker else { return nil }

        let r = GATT.historyRecordOffset                // 8
        let recordEnd = r + GATT.historyRecordLength    // 8 ..< 30

        // End-of-sync sentinel: all 22 record bytes are zero.
        if b[r..<recordEnd].allSatisfy({ $0 == 0 }) {
            return .endOfSync
        }

        let total = Int(readUInt24LE(b, GATT.historyTotalCountOffset))
        let index = Int(readUInt24LE(b, GATT.historyRecordIndexOffset))

        let tsRaw    = readUInt32LE(b, r + 0)    // bytes 8–11
        let tempRaw  = readInt16LE(b, r + 4)     // bytes 12–13
        let humRaw   = readUInt16LE(b, r + 6)    // bytes 14–15
        let tvocRaw  = readUInt16LE(b, r + 8)    // bytes 16–17
        let eco2Raw  = readUInt16LE(b, r + 10)   // bytes 18–19
        let aqiByte  = b[r + 12]                 // byte 20
        let statByte = b[r + 13]                 // byte 21
        let seqRaw   = readUInt16LE(b, r + 14)   // bytes 22–23
        let pm1Raw   = readUInt16LE(b, r + 16)   // bytes 24–25
        let pm25Raw  = readUInt16LE(b, r + 18)   // bytes 26–27
        let pm10Raw  = readUInt16LE(b, r + 20)   // bytes 28–29

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
        return .record(fields, index: index, total: total)
    }

    private static func readUInt16LE(_ b: [UInt8], _ i: Int) -> UInt16 {
        UInt16(b[i]) | (UInt16(b[i + 1]) << 8)
    }

    private static func readUInt24LE(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) | (UInt32(b[i + 1]) << 8) | (UInt32(b[i + 2]) << 16)
    }

    private static func readUInt32LE(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) | (UInt32(b[i + 1]) << 8) | (UInt32(b[i + 2]) << 16) | (UInt32(b[i + 3]) << 24)
    }

    private static func readInt16LE(_ b: [UInt8], _ i: Int) -> Int16 {
        Int16(bitPattern: readUInt16LE(b, i))
    }
}
