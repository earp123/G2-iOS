//
//  HistoryRecord.swift
//  G2-iOS
//
//  SwiftData model matching the firmware's 26-byte flash record, log record v2
//  (§1.2 / §3).
//
//  v2 note: `tvoc`/`eco2` are **removed, not renamed** — the semantics changed
//  (a VOC index is not a ppb concentration, and SEN66 CO₂ is measured rather than
//  equivalent). PM4.0, NOx index and the air-quality class join the record.
//  Because the app is pre-1.0 with no production data, the container points at a
//  new store file instead of carrying a versioned migration (§3, §9.4).
//
//  Values are stored in display units; `nil` for an optional field means the
//  firmware stored an invalid sentinel.
//

import Foundation
import SwiftData

@Model
final class HistoryRecord {
    /// Which monitor logged this record — the last two bytes of the peripheral's
    /// Bluetooth identifier (e.g. "9A2B"), so one app can cache several devices.
    /// (iOS hides the real BLE MAC; this is derived from CoreBluetooth's stable
    /// per-device UUID instead.) The mock source uses "MOCK".
    var deviceID: String = ""
    /// Firmware stores a Unix epoch from the DS3231 RTC; mock generates plausible times.
    var timestamp: Date
    var temperatureC: Double?   // °C,     nil = sentinel
    var humidityPct: Double?    // %,      nil = sentinel
    var vocIndex: Double?       // index,  nil = sentinel
    var noxIndex: Double?       // index,  nil = sentinel
    var co2Ppm: Double?         // ppm,    nil = sentinel
    var pm1: Double?            // µg/m³,  nil = sentinel (0xFFFF / 0xFFFE)
    var pm25: Double?
    var pm4: Double?
    var pm10: Double?
    var aqClass: Int            // 0–5 (0 = unknown/warming)
    var status: UInt8           // same bitfield as the live packet's byte 35
    var sequence: UInt16

    init(
        deviceID: String,
        timestamp: Date,
        temperatureC: Double?,
        humidityPct: Double?,
        vocIndex: Double?,
        noxIndex: Double?,
        co2Ppm: Double?,
        pm1: Double?,
        pm25: Double?,
        pm4: Double?,
        pm10: Double?,
        aqClass: Int,
        status: UInt8,
        sequence: UInt16
    ) {
        self.deviceID = deviceID
        self.timestamp = timestamp
        self.temperatureC = temperatureC
        self.humidityPct = humidityPct
        self.vocIndex = vocIndex
        self.noxIndex = noxIndex
        self.co2Ppm = co2Ppm
        self.pm1 = pm1
        self.pm25 = pm25
        self.pm4 = pm4
        self.pm10 = pm10
        self.aqClass = aqClass
        self.status = status
        self.sequence = sequence
    }

    /// Builds a record from decoded packet fields (BLE history upsert).
    convenience init(fields f: HistoryRecordFields, deviceID: String) {
        self.init(
            deviceID: deviceID,
            timestamp: f.timestamp,
            temperatureC: f.temperatureC,
            humidityPct: f.humidityPct,
            vocIndex: f.vocIndex,
            noxIndex: f.noxIndex,
            co2Ppm: f.co2Ppm,
            pm1: f.pm1,
            pm25: f.pm25,
            pm4: f.pm4,
            pm10: f.pm10,
            aqClass: f.aqClass,
            status: f.status,
            sequence: f.sequence
        )
    }

    var aqiLevel: AQILevel { AQILevel(rawValue: aqClass) ?? .unknown }
    var deviceStatus: DeviceStatus { DeviceStatus(raw: status) }

    /// Air-quality label with the record's own warming-up context applied (§2).
    var aqClassLabel: String { aqiLevel.label(isWarming: deviceStatus.sen66Warming) }
}
