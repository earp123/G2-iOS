//
//  AirClasses.swift
//  G2-iOS
//
//  The packed class byte — live packet byte 32 and log-record byte 22 in
//  contract v3 (thresholds-v3 §1.1 / firmware §2.1):
//
//    class_byte = (pm_class << 4) | gas_class
//      gas_class  bits 0–3   0 = unknown/warming, 1–5 (worst of VOC/NOx/CO2)
//      pm_class   bits 4–7   0 = unknown/warming, 1 good, 2 attention, 3 hazard
//                            (worst of PM1/PM2.5/PM10; PM4.0 is never classified)
//
//  Two LEDs on the device, two tiles in the app. Both classes come from
//  firmware and are never re-derived from raw values here — the band edges are
//  user-editable on the device, so only firmware knows where they sit.
//
//  A v2-era log record still on the device's flash carries `aq_class` 0–5 in
//  the same byte with the high nibble 0, so it decodes as its gas class with an
//  unknown (grey) PM class (§2.7).
//

import Foundation

/// Gas and PM class decoded from one packed byte (§1.1).
///
/// `nonisolated` so the history path can carry it across the HistoryDataStore
/// actor boundary inside `HistoryRecordFields`.
nonisolated struct AirClasses: Equatable, Hashable, Sendable {
    /// 0 unknown/warming, 1–5 — worst of VOC / NOx / CO₂.
    let gas: UInt8
    /// 0 unknown/warming, 1 good, 2 attention, 3 hazard — worst of PM1 / PM2.5 / PM10.
    let pm: UInt8

    /// Splits the wire byte: low nibble gas, high nibble PM.
    init(byte: UInt8) {
        gas = byte & 0x0F
        pm = byte >> 4
    }

    init(gas: UInt8, pm: UInt8) {
        self.gas = gas & 0x0F
        self.pm = pm & 0x0F
    }

    /// The packed wire byte — what the simulator and the mock emit.
    var byte: UInt8 { (pm << 4) | gas }

    /// Both classes unknown — the warming / no-reading state.
    static let unknown = AirClasses(byte: 0)
}
