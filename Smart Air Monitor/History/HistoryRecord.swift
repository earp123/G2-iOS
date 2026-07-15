//
//  HistoryRecord.swift
//  Smart Air Monitor
//
//  SwiftData model matching the firmware's 16-byte flash record (§4.1).
//  PM is intentionally absent — it is not in the on-device record (§4.2).
//
//  nil for an optional field means the firmware stored an invalid sentinel.
//

import Foundation
import SwiftData

@Model
final class HistoryRecord {
    /// Firmware stores a Unix epoch from the DS3231 RTC; mock generates plausible times.
    var timestamp: Date
    var temperatureC: Double?   // nil = sentinel
    var humidityPct: Double?    // nil = sentinel
    var tvocPpb: Int?           // nil = sentinel
    var eco2Ppm: Int?           // nil = sentinel
    var aqi: Int                // 0–5
    var status: UInt8           // same bitfield as §2.3
    var sequence: UInt16

    init(
        timestamp: Date,
        temperatureC: Double?,
        humidityPct: Double?,
        tvocPpb: Int?,
        eco2Ppm: Int?,
        aqi: Int,
        status: UInt8,
        sequence: UInt16
    ) {
        self.timestamp = timestamp
        self.temperatureC = temperatureC
        self.humidityPct = humidityPct
        self.tvocPpb = tvocPpb
        self.eco2Ppm = eco2Ppm
        self.aqi = aqi
        self.status = status
        self.sequence = sequence
    }

    var aqiLevel: AQILevel { AQILevel(rawValue: aqi) ?? .warmingUp }
    var deviceStatus: DeviceStatus { DeviceStatus(raw: status) }
}
