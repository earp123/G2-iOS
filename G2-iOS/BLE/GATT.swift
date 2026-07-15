//
//  GATT.swift
//  G2-iOS
//
//  Authoritative GEUE Air Quality (G2) BLE GATT contract.
//
//  ⚠️ SOURCE OF TRUTH — these values mirror shipped ESP32-S3 firmware.
//  Do NOT change, guess, or "improve" any UUID, opcode, byte offset, scaling
//  factor, or sentinel. If a value is missing here, ask before assuming.
//

import CoreBluetooth

/// All identifiers and constants for the GEUE Air Quality GATT interface (§2).
///
/// `nonisolated` so the constants can be read from CoreBluetooth's dedicated-queue
/// (nonisolated) delegate callbacks. The CBUUID values are immutable, hence the
/// `nonisolated(unsafe)` annotations are safe.
nonisolated enum GATT {

    /// Advertised local name (§2.1).
    static let advertisedName = "GEUE Air Quality"

    /// Primary service — scan filters on this UUID (§2.1 / §2.2).
    nonisolated(unsafe) static let serviceUUID = CBUUID(string: "7A3E4F5B-8C2D-4E9A-B1F6-0D3C5E7F9A2B")

    /// Characteristic 1 — Sensor Data, READ + NOTIFY, 31-byte payload (§2.3).
    nonisolated(unsafe) static let sensorCharacteristicUUID = CBUUID(string: "7A3E4F5C-8C2D-4E9A-B1F6-0D3C5E7F9A2B")

    /// Characteristic 2 — Command, WRITE + WRITE_NO_RSP, 1–2 byte payload (§2.4).
    nonisolated(unsafe) static let commandCharacteristicUUID = CBUUID(string: "7A3E4F5D-8C2D-4E9A-B1F6-0D3C5E7F9A2B")

    /// Characteristic 3 — Settings (TVOC thresholds), READ + WRITE, 8-byte payload (§2.5).
    nonisolated(unsafe) static let settingsCharacteristicUUID = CBUUID(string: "7A3E4F5E-8C2D-4E9A-B1F6-0D3C5E7F9A2B")

    /// Classifies a discovered characteristic without leaking CoreBluetooth
    /// types across the BLE-queue → MainActor boundary.
    enum Characteristic: Sendable {
        case sensor
        case command
        case settings
        case unknown

        init(_ uuid: CBUUID) {
            switch uuid {
            case GATT.sensorCharacteristicUUID:   self = .sensor
            case GATT.commandCharacteristicUUID:  self = .command
            case GATT.settingsCharacteristicUUID: self = .settings
            default:                              self = .unknown
            }
        }
    }

    // MARK: - Command opcodes (§2.4)

    /// Command-characteristic opcodes. LOW/MED/HIGH/MAX map to 25/50/75/100%.
    enum Command: UInt8 {
        case syncHistory  = 0x01  // Firmware stub — routes to the stubbed history layer (§4).
        case fanManual    = 0x02  // [pct: u8] — exact fan speed 0–100% (2-byte write).
        case fanAuto      = 0x03  // AQI-driven auto mode.
        case fanOff       = 0x04  // Manual 0%.
        case fanLow       = 0x05  // Manual 25%.
        case fanMed       = 0x06  // Manual 50%.
        case fanHigh      = 0x07  // Manual 75%.
        case fanMax       = 0x08  // Manual 100%.
        case getStatus    = 0x09  // Force an immediate sensor notification (needs active CCCD).
        case fanTVOCAuto  = 0x0A  // TVOC-setpoint auto mode (uses Settings thresholds).
        case setTime      = 0x0B  // SET_TIME [sec min hr wday mday mon yr2k] — raw decimal, not BCD.
        case syncRecent   = 0x0C  // SYNC_RECENT [count: u32 LE] — stream newest N records (5-byte write).
    }

    /// ATT error returned by the device for an unknown opcode (§2.4).
    static let attErrorUnknownOpcode: UInt8 = 0x0E

    // MARK: - Sensor payload layout (§2.3)

    /// Required minimum length of the sensor characteristic payload (bytes).
    static let sensorPayloadLength = 31

    /// The sensor parser starts decoding here — bytes 0–7 are embedded BLE
    /// advertising-header bytes carried *inside* the GATT payload (§2.3 note).
    static let sensorPayloadDecodeOffset = 8

    // MARK: - Settings payload layout (§2.5)

    /// Settings characteristic length: 4 × uint16 LE.
    static let settingsPayloadLength = 8

    // MARK: - History packet demux (shares the Sensor characteristic)
    //
    // Live sensor notifications keep firing during a history stream, on the SAME
    // characteristic — demux on payload[0]: 0x02 = live, 0xA5 = history.
    // History packets are 0xA5, 0x48 ('H'), u24 total, u24 index, 22-byte record,
    // one reserved byte (BLE_HISTORY_PROTOCOL.md).

    /// payload[0] value that marks a history sync packet (vs live sensor data 0x02).
    static let historyPacketMarker: UInt8 = 0xA5
    /// payload[1] for a history packet (ASCII 'H').
    static let historyHeaderMarker: UInt8 = 0x48

    /// Wire offsets of the u24 LE total/index fields. Both are relative to THIS
    /// sync (a recent-N sync has total == N) and don't wrap for any realistic
    /// buffer, so index/total is a reliable progress fraction. Completion is still
    /// signalled by the all-zero record sentinel.
    static let historyTotalCountOffset = 2
    static let historyRecordIndexOffset = 5
    /// Byte offset of the geue_log_record_t within a history packet.
    static let historyRecordOffset = 8
    /// Length of geue_log_record_t (timestamp-first, PM-carrying flash struct).
    static let historyRecordLength = 22

    // MARK: - PM invalid sentinels (PM logging update, 2026-07-09)
    //
    // Firmware's shared PM→uint16 conversion (live payload, CAN frame, log record)
    // yields two special values, both meaning "no usable reading". Per Sam's call
    // they are treated identically as invalid — there is no distinct over-range UI.

    /// No valid reading — sensor absent or not warmed up.
    static let pmSentinelNoReading: UInt16 = 0xFFFF
    /// Over-range clamp — folded into the same invalid state as no-reading.
    static let pmSentinelOverRange: UInt16 = 0xFFFE

    /// The single canonical PM decode: raw µg/m³ → `Int`, or `nil` for either
    /// sentinel. Shared by SensorParser (live) and HistoryPacketParser (history)
    /// so the sentinel rule is never duplicated across the two files.
    static func decodePM(_ raw: UInt16) -> Int? {
        (raw == pmSentinelNoReading || raw == pmSentinelOverRange) ? nil : Int(raw)
    }
}
