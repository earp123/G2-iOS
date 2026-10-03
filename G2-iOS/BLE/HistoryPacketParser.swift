//
//  HistoryPacketParser.swift
//  G2-iOS
//
//  Decodes the 34-byte history notification packets the device streams after a
//  sync command (0x01 full dump, 0x0C recent-N). History packets share the Sensor
//  Data characteristic and are distinguished from live readings by payload[0]
//  (§1.2).
//
//  Packet framing (34 bytes, little-endian):
//    byte 0     : 0xA5 history marker (live v2 packets have 0x03 here)
//    byte 1     : 0x48 ('H')
//    bytes 2–4  : total u24 LE — record count in THIS sync (recent-N → N)
//    bytes 5–7  : index u24 LE — 0-based position within THIS sync
//    bytes 8–33 : geue_log_record_t v3 (26 bytes, below)
//
//  u24 total/index don't wrap for any realistic buffer (max ~16.7M records), so
//  index/total are a trustworthy progress fraction. End-of-sync is still detected
//  by the sentinel packet whose 26 record bytes are all zero (index == total on
//  that packet as well) — always sent, even for a count-0 sync.
//
//  Log record v3 layout (packed, no padding, §1.2), offsets relative to byte 8.
//  Identical to v2 except byte +22 (thresholds-v3 §2.7):
//    +0  : timestamp u32 LE (Unix epoch seconds; may be a small seconds-since-boot
//          value if the RTC read failed at log time — the caching layer
//          plausibility-checks it)
//    +4  : temperature i16 LE ×100 °C; sentinel INT16_MIN
//    +6  : humidity    u16 LE ×100 %;  sentinel 0xFFFF
//    +8  : VOC index   u16 LE ×10;     sentinel 0xFFFF
//    +10 : NOx index   u16 LE ×10;     sentinel 0xFFFF
//    +12 : CO2         u16 LE ppm;     sentinel 0xFFFF
//    +14 : PM1.0       u16 LE ×10 µg/m³; sentinels 0xFFFF / 0xFFFE
//    +16 : PM2.5       u16 LE ×10
//    +18 : PM4.0       u16 LE ×10
//    +20 : PM10        u16 LE ×10
//    +22 : class byte u8 — packed like live byte 32: low nibble gas class 0–5,
//          high nibble PM class 0–3 (0 = unknown/warming). A record logged by
//          v2 firmware carries aq_class 0–5 here with the high nibble 0, so it
//          decodes with an unknown (grey) PM class.
//    +23 : status   u8 (same bitfield as the live packet's byte 35)
//    +24 : sequence u16 LE (cross-ref only, NOT an ordering key)
//
//  Number concentrations and raw values are not logged (firmware §6.3).
//
//  A 31-byte v1 packet is rejected on length — that is how a client tells the two
//  record versions apart on the wire (§1.2).
//

import Foundation

enum HistoryPacketParser {

    enum Packet: Sendable {
        /// One decoded record plus its u24 position within this sync (for progress).
        case record(HistoryRecordFields, index: Int, total: Int)
        /// End-of-sync: the 26 record bytes were all zero.
        case endOfSync
    }

    /// Returns nil if this is not a valid v2 history packet (wrong length or
    /// markers) — e.g. a live sensor packet that reached here by mistake, or a
    /// 31-byte packet from pre-SEN66 firmware.
    static func parse(_ data: Data) -> Packet? {
        let b = [UInt8](data)
        // Exact length, per the firmware note's guard (`count == 34`): length is
        // what separates a v2 packet from the retired 31-byte v1 one, so anything
        // else is rejected rather than decoded from its first 34 bytes.
        guard b.count == GATT.historyPacketLength,
              b[0] == GATT.historyPacketMarker,
              b[1] == GATT.historyHeaderMarker else { return nil }

        let r = GATT.historyRecordOffset                // 8
        let recordEnd = r + GATT.historyRecordLength    // 8 ..< 34

        // End-of-sync sentinel: all 26 record bytes are zero.
        if b[r..<recordEnd].allSatisfy({ $0 == 0 }) {
            return .endOfSync
        }

        let total = Int(readU24(b, GATT.historyTotalCountOffset))
        let index = Int(readU24(b, GATT.historyRecordIndexOffset))

        let f = GATT.HistoryRecordOffset.self
        let fields = HistoryRecordFields(
            timestamp:    Date(timeIntervalSince1970: TimeInterval(readU32(b, r + f.timestamp))),
            temperatureC: GATT.decodeI16x100(readI16(b, r + f.temperature)),
            humidityPct:  GATT.decodeU16x100(readU16(b, r + f.humidity)),
            vocIndex:     GATT.decodeU16x10(readU16(b, r + f.vocIndex)),
            noxIndex:     GATT.decodeU16x10(readU16(b, r + f.noxIndex)),
            co2Ppm:       GATT.decodeU16(readU16(b, r + f.co2)).map(Double.init),
            pm1:          GATT.decodePMx10(readU16(b, r + f.pm1)),
            pm25:         GATT.decodePMx10(readU16(b, r + f.pm25)),
            pm4:          GATT.decodePMx10(readU16(b, r + f.pm4)),
            pm10:         GATT.decodePMx10(readU16(b, r + f.pm10)),
            classes:      AirClasses(byte: b[r + f.classByte]),
            status:       b[r + f.status],
            sequence:     readU16(b, r + f.sequence)
        )
        return .record(fields, index: index, total: total)
    }

    // MARK: - Little-endian readers (bounds guaranteed by the length check)

    private static func readU16(_ b: [UInt8], _ i: Int) -> UInt16 {
        UInt16(b[i]) | (UInt16(b[i + 1]) << 8)
    }

    private static func readU24(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) | (UInt32(b[i + 1]) << 8) | (UInt32(b[i + 2]) << 16)
    }

    private static func readU32(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) | (UInt32(b[i + 1]) << 8) | (UInt32(b[i + 2]) << 16) | (UInt32(b[i + 3]) << 24)
    }

    private static func readI16(_ b: [UInt8], _ i: Int) -> Int16 {
        Int16(bitPattern: readU16(b, i))
    }
}
