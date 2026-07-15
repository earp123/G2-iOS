//
//  SensorReading.swift
//  G2-iOS
//
//  A fully decoded sensor-data packet (§2.3). Every field that carries an
//  invalid sentinel is surfaced as `Metric.invalid`, never as a real number.
//

import Foundation

/// One decoded reading from the Sensor Data characteristic (§2.3).
struct SensorReading: Equatable, Sendable {
    var temperatureC: Metric<Double>   // °C (sentinel 0x8000)
    var humidityPct: Metric<Double>    // %  (sentinel 0xFFFF)
    var tvocPpb: Metric<Int>           // ppb (sentinel 0xFFFF)
    var eco2Ppm: Metric<Int>           // ppm (sentinel 0xFFFF)
    var pm1: Metric<Int>               // µg/m³ (sentinel 0xFFFF)
    var pm25: Metric<Int>              // µg/m³ (sentinel 0xFFFF)
    var pm10: Metric<Int>              // µg/m³ (sentinel 0xFFFF)
    var aqi: AQILevel                  // UBA 1–5 (0 = warming up)
    var fanSpeedPct: Int               // byte 23, 0–100
    var status: DeviceStatus           // byte 24 bitfield
    var sequence: UInt16               // bytes 25–26, wraps at 65535

    /// Wall-clock time this reading was received by the client.
    var receivedAt: Date
}
