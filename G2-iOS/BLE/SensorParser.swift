//
//  SensorParser.swift
//  G2-iOS
//
//  Defensive, length-checked decoder for the 31-byte Sensor Data payload (§2.3).
//
//  Critical: bytes 0–7 are embedded BLE advertising-header bytes carried *inside*
//  the GATT payload. Decoding starts at byte 8 (GATT.sensorPayloadDecodeOffset).
//  No force-unwraps; a short payload yields `.failure(.malformedPacket)` rather
//  than a crash, and sentinels become `Metric.invalid`.
//

import Foundation

enum SensorParseError: Error, Equatable, Sendable {
    /// Payload shorter than the required 31 bytes (§2.3 / §7).
    case malformedPacket(length: Int)
}

enum SensorParser {

    // Invalid sentinels (§2.3).
    private static let tempSentinel: Int16   = Int16(bitPattern: 0x8000)  // INT16_MIN
    private static let u16Sentinel: UInt16   = 0xFFFF

    /// Parses a raw characteristic payload into a `SensorReading`.
    ///
    /// - Parameter receivedAt: timestamp to stamp on the reading (injectable for tests).
    static func parse(_ data: Data, receivedAt: Date = Date()) -> Result<SensorReading, SensorParseError> {
        // Length-check before touching any byte (§7 — never crash on short packets).
        guard data.count >= GATT.sensorPayloadLength else {
            return .failure(.malformedPacket(length: data.count))
        }

        // `Data` may be sliced with a non-zero startIndex; normalise to a
        // 0-based array so fixed offsets from the spec are always valid.
        let b = [UInt8](data)
        let o = GATT.sensorPayloadDecodeOffset  // start decoding at byte 8

        // Multi-byte fields are little-endian.
        let tempRaw = readInt16LE(b, o + 0)     // bytes 8–9
        let humRaw  = readUInt16LE(b, o + 2)    // bytes 10–11
        let tvocRaw = readUInt16LE(b, o + 4)    // bytes 12–13
        let eco2Raw = readUInt16LE(b, o + 6)    // bytes 14–15
        let pm1Raw  = readUInt16LE(b, o + 8)    // bytes 16–17
        let pm25Raw = readUInt16LE(b, o + 10)   // bytes 18–19
        let pm10Raw = readUInt16LE(b, o + 12)   // bytes 20–21
        let aqiRaw  = b[o + 14]                  // byte 22
        let fanRaw  = b[o + 15]                  // byte 23
        let statRaw = b[o + 16]                  // byte 24
        let seqRaw  = readUInt16LE(b, o + 17)   // bytes 25–26
        // bytes 27–30 reserved — ignored.

        let reading = SensorReading(
            temperatureC: tempRaw == tempSentinel ? .invalid : .valid(Double(tempRaw) / 100.0),
            humidityPct:  humRaw  == u16Sentinel  ? .invalid : .valid(Double(humRaw) / 100.0),
            tvocPpb:      tvocRaw == u16Sentinel  ? .invalid : .valid(Int(tvocRaw)),
            eco2Ppm:      eco2Raw == u16Sentinel  ? .invalid : .valid(Int(eco2Raw)),
            // PM has two invalid sentinels (0xFFFF no-reading, 0xFFFE over-range);
            // GATT.decodePM folds both to nil so 0xFFFE never shows as 65534 (§ PM).
            pm1:          Metric(GATT.decodePM(pm1Raw)),
            pm25:         Metric(GATT.decodePM(pm25Raw)),
            pm10:         Metric(GATT.decodePM(pm10Raw)),
            aqi:          AQILevel(raw: aqiRaw),
            fanSpeedPct:  Int(fanRaw),
            status:       DeviceStatus(raw: statRaw),
            sequence:     seqRaw,
            receivedAt:   receivedAt
        )
        return .success(reading)
    }

    // MARK: - Little-endian readers (bounds already guaranteed by the length check)

    private static func readUInt16LE(_ b: [UInt8], _ i: Int) -> UInt16 {
        UInt16(b[i]) | (UInt16(b[i + 1]) << 8)
    }

    private static func readInt16LE(_ b: [UInt8], _ i: Int) -> Int16 {
        Int16(bitPattern: readUInt16LE(b, i))
    }
}
