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
//  v3 note: log-record byte 22 is now a packed gas/PM class byte (thresholds-v3
//  §2.7). `aqClass` keeps its column and now holds the **gas** class 0–5 —
//  firmware's own aq_class became gas-only in v3, and the CSV export's
//  `aq_class` column follows it unchanged. The PM class 0–3 is a new optional
//  column, so the existing store migrates lightweight: a row cached before it
//  existed reads `nil`, and renders exactly like a v2-era record streamed from
//  flash (high nibble 0) — a grey PM tile. The firmware log-record version bump
//  to 3 still wipes the cache on the first sync (§2).
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
    var aqClass: Int            // gas class 0–5 (0 = unknown/warming)
    var pmClass: Int?           // PM class 0–3 (0 = unknown/warming); nil = cached before v3
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
        pmClass: Int?,
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
        self.pmClass = pmClass
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
            aqClass: Int(f.classes.gas),
            pmClass: Int(f.classes.pm),
            status: f.status,
            sequence: f.sequence
        )
    }

    /// Gas class — drives the record's gas tile.
    var aqiLevel: AQILevel { AQILevel(rawValue: aqClass) ?? .unknown }
    /// PM class — drives the record's PM tile. Unknown (grey) for a v2-era
    /// record or a row cached before the column existed.
    var pmLevel: PMLevel { PMLevel(rawValue: pmClass ?? 0) ?? .unknown }
    var deviceStatus: DeviceStatus { DeviceStatus(raw: status) }

    /// Gas-class label with the record's own warming-up context applied (§2).
    var aqClassLabel: String { aqiLevel.label(isWarming: deviceStatus.sen66Warming) }
    /// PM-class label with the record's own warming-up context applied (§2).
    var pmClassLabel: String { pmLevel.label(isWarming: deviceStatus.sen66Warming) }
}
