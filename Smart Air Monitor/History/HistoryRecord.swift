//
//  HistoryRecord.swift
//  Smart Air Monitor
//
//  SwiftData model matching the firmware's 22-byte flash record (§4.1). PM
//  (PM1.0/PM2.5/PM10) is logged since firmware 2026-07-09 — field names match
//  SensorReading's live PM fields (pm1/pm25/pm10); typing follows this model's
//  own `Int?`-for-sentinel convention.
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
    var pm1: Int?               // µg/m³, nil = sentinel (0xFFFF / 0xFFFE)
    var pm25: Int?              // µg/m³, nil = sentinel
    var pm10: Int?              // µg/m³, nil = sentinel

    init(
        timestamp: Date,
        temperatureC: Double?,
        humidityPct: Double?,
        tvocPpb: Int?,
        eco2Ppm: Int?,
        aqi: Int,
        status: UInt8,
        sequence: UInt16,
        pm1: Int? = nil,
        pm25: Int? = nil,
        pm10: Int? = nil
    ) {
        self.timestamp = timestamp
        self.temperatureC = temperatureC
        self.humidityPct = humidityPct
        self.tvocPpb = tvocPpb
        self.eco2Ppm = eco2Ppm
        self.aqi = aqi
        self.status = status
        self.sequence = sequence
        self.pm1 = pm1
        self.pm25 = pm25
        self.pm10 = pm10
    }

    var aqiLevel: AQILevel { AQILevel(rawValue: aqi) ?? .warmingUp }
    var deviceStatus: DeviceStatus { DeviceStatus(raw: status) }
}
