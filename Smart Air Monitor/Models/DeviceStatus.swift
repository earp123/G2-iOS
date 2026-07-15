//
//  DeviceStatus.swift
//  Smart Air Monitor
//
//  Decodes the status bitfield (byte 24 of the sensor payload, §2.3).
//

import Foundation

/// One decoded sensor-health indicator from the status bitfield.
struct StatusIndicator: Identifiable, Sendable {
    let bit: Int
    let label: String
    let isOn: Bool
    var id: Int { bit }
}

/// The status bitfield (byte 24) decoded into labeled indicators (§2.3).
struct DeviceStatus: Equatable, Sendable {
    let raw: UInt8

    /// Bit → human-readable sensor subsystem (§2.3).
    // Bits 5–7 are reserved/unused — firmware defines no meaning, so we don't label them.
    private static let labels: [(bit: Int, label: String)] = [
        (0, "AHT21 initialised"),          // temp/humidity initialised
        (1, "AHT21 last read OK"),         // temp/humidity last read succeeded
        (2, "ENS160 initialised"),         // VOC/CO2 initialised
        (3, "TWAI (CAN) node online"),     // initialised AND not bus-off (firmware 2026-07-09)
        (4, "BMV080 (PM) measuring"),      // PM opened and measuring
    ]

    var indicators: [StatusIndicator] {
        Self.labels.map { entry in
            StatusIndicator(
                bit: entry.bit,
                label: entry.label,
                isOn: raw & (1 << entry.bit) != 0
            )
        }
    }
}
