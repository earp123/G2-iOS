//
//  DeviceStatus.swift
//  G2-iOS
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
    // Bits 7 is reserved/unused — firmware defines no meaning, so we don't label it.
    private nonisolated static let labels: [(bit: Int, label: String)] = [
        (0, "AHT21 initialised"),          // temp/humidity initialised
        (1, "AHT21 last read OK"),         // temp/humidity last read succeeded
        (2, "ENS160 initialised"),         // VOC/CO2 initialised
        (3, "TWAI (CAN) node online"),     // initialised AND not bus-off (firmware 2026-07-09)
        (4, "BMV080 (PM) measuring"),      // PM opened and measuring
        (5, "Ionizer health status"),      // Ionizer health (0=healthy, 1=faulted, only valid when bit6=1)
        (6, "Ionizer power"),              // Ionizer power (0=off, 1=on)
    ]

    nonisolated var indicators: [StatusIndicator] {
        Self.labels.map { entry in
            StatusIndicator(
                bit: entry.bit,
                label: entry.label,
                isOn: raw & (1 << entry.bit) != 0
            )
        }
    }

    /// Ionizer power state (bit 6, 0x40).
    nonisolated var ionizerIsOn: Bool {
        (raw & 0x40) != 0
    }

    /// Ionizer health status (bit 5, 0x20). Only meaningful when ionizerIsOn is true.
    /// Returns true if ionizer is healthy, false if faulted.
    nonisolated var ionizerIsHealthy: Bool {
        (raw & 0x20) == 0   // bit5=0 means healthy, bit5=1 means faulted
    }

    /// Combined ionizer state for display purposes.
    enum IonizerState: Sendable {
        case off
        case healthy
        case faulted
    }

    nonisolated var ionizerState: IonizerState {
        guard ionizerIsOn else { return .off }
        return ionizerIsHealthy ? .healthy : .faulted
    }
}
