//
//  SensorParser.swift
//  G2-iOS
//
//  Defensive, length-checked decoder for the 52-byte Sensor Data payload (§1.1).
//
//  Contract v2 decodes from byte 0 — the eight fake advertising-header bytes that
//  prefixed the v1 payload are gone. Byte 0 must be the live marker 0x03; the
//  retired v1 marker 0x02 is rejected, not best-effort decoded, because every
//  field behind it moved (§1.1).
//
//  No force-unwraps: a short, mis-marked or wrong-version payload yields a
//  `.failure` the UI reports non-fatally, never a crash. Every scaled field goes
//  through the shared `GATT.decode*` family so a sentinel rule is defined once.
//

import Foundation

enum SensorParseError: Error, Equatable, Sendable {
    /// Payload shorter than the required 52 bytes (§1.1 / §7).
    case malformedPacket(length: Int)
    /// Byte 0 was not the live-v2 marker. Carries the marker actually seen, so a
    /// legacy `0x02` device is identifiable from the message (§1.1).
    case unsupportedMarker(UInt8)
    /// Byte 1 was not payload version 0x02 (§1.1).
    case unsupportedPayloadVersion(UInt8)

    /// User-facing, non-fatal description (§7).
    var message: String {
        switch self {
        case .malformedPacket(let length):
            "Malformed packet (\(length) bytes, expected \(GATT.sensorPayloadLength))"
        case .unsupportedMarker(let marker) where marker == GATT.legacyLivePacketMarker:
            "Device is running pre-SEN66 firmware (legacy 0x02 packet) — update required"
        case .unsupportedMarker(let marker):
            String(format: "Unrecognised packet marker 0x%02X", marker)
        case .unsupportedPayloadVersion(let version):
            String(format: "Unsupported payload version 0x%02X", version)
        }
    }
}

enum SensorParser {

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
        let o = GATT.SensorOffset.self

        // Reject anything that isn't a live v2 packet — including the retired
        // 0x02 layout, whose fields all sit at different offsets (§1.1).
        guard b[o.marker] == GATT.livePacketMarker else {
            return .failure(.unsupportedMarker(b[o.marker]))
        }
        guard b[o.payloadVersion] == GATT.livePayloadVersion else {
            return .failure(.unsupportedPayloadVersion(b[o.payloadVersion]))
        }

        let reading = SensorReading(
            temperatureC:    Metric(GATT.decodeI16x100(readI16(b, o.temperature))),
            humidityPct:     Metric(GATT.decodeU16x100(readU16(b, o.humidity))),
            vocIndex:        Metric(GATT.decodeU16x10(readU16(b, o.vocIndex))),
            noxIndex:        Metric(GATT.decodeU16x10(readU16(b, o.noxIndex))),
            co2Ppm:          Metric(GATT.decodeU16(readU16(b, o.co2))),
            // PM carries two invalid sentinels (0xFFFF no-reading, 0xFFFE
            // over-range); decodePMx10 folds both to nil (§1).
            pm1:             Metric(GATT.decodePMx10(readU16(b, o.pm1))),
            pm25:            Metric(GATT.decodePMx10(readU16(b, o.pm25))),
            pm4:             Metric(GATT.decodePMx10(readU16(b, o.pm4))),
            pm10:            Metric(GATT.decodePMx10(readU16(b, o.pm10))),
            nc05:            Metric(GATT.decodeU16x10(readU16(b, o.nc05))),
            nc1:             Metric(GATT.decodeU16x10(readU16(b, o.nc1))),
            nc25:            Metric(GATT.decodeU16x10(readU16(b, o.nc25))),
            nc4:             Metric(GATT.decodeU16x10(readU16(b, o.nc4))),
            nc10:            Metric(GATT.decodeU16x10(readU16(b, o.nc10))),
            rawVOCTicks:     Metric(GATT.decodeU16(readU16(b, o.rawVOCTicks))),
            rawNOxTicks:     Metric(GATT.decodeU16(readU16(b, o.rawNOxTicks))),
            rawCO2Ppm:       Metric(GATT.decodeU16(readU16(b, o.rawCO2))),
            rawHumidityPct:  Metric(GATT.decodeI16x100(readI16(b, o.rawHumidity))),
            rawTemperatureC: Metric(GATT.decodeI16x200(readI16(b, o.rawTemperature))),
            aqClass:         AQILevel(raw: b[o.aqClass]),
            fanSpeedPct:     Int(b[o.fanPercent]),
            fanMode:         FanMode(wire: b[o.fanMode]),
            status:          DeviceStatus(raw: b[o.status]),
            sen66Status:     SEN66Status(raw: readU32(b, o.sen66Status)),
            deviceState:     DeviceState(rawValue: b[o.deviceState]),
            sequence:        readU16(b, o.sequence),
            receivedAt:      receivedAt
        )
        return .success(reading)
    }

    // MARK: - Little-endian readers (bounds already guaranteed by the length check)

    private static func readU16(_ b: [UInt8], _ i: Int) -> UInt16 {
        UInt16(b[i]) | (UInt16(b[i + 1]) << 8)
    }

    private static func readI16(_ b: [UInt8], _ i: Int) -> Int16 {
        Int16(bitPattern: readU16(b, i))
    }

    private static func readU32(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i])
            | (UInt32(b[i + 1]) << 8)
            | (UInt32(b[i + 2]) << 16)
            | (UInt32(b[i + 3]) << 24)
    }
}
