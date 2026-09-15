//
//  DeviceStatus.swift
//  G2-iOS
//
//  Two status surfaces from the live packet (§1.1):
//   • `DeviceStatus`  — the firmware status bitfield, byte 35.
//   • `SEN66Status`   — the SEN66's own device status register, bytes 36–39.
//
//  The byte-35 bit map is entirely new in v2 (the AHT21/ENS160/SPS30 bits are
//  gone), except bits 5 and 6, which keep their v1 ionizer meaning.
//

import Foundation

/// One decoded health indicator from a status bitfield.
struct StatusIndicator: Identifiable, Sendable {
    let bit: Int
    let label: String
    let isOn: Bool
    /// True when `isOn` is the *bad* state, so the UI can tint it as a problem
    /// rather than as a satisfied checkmark.
    var isFault: Bool = false
    var id: Int { bit }
}

/// The firmware status bitfield (live byte 35 / log-record byte 23), decoded
/// into labeled indicators (§1.1).
struct DeviceStatus: Equatable, Sendable {
    let raw: UInt8

    // Bit 7 is reserved — firmware defines no meaning, so we don't label it.
    private nonisolated static let labels: [(bit: Int, label: String, isFault: Bool)] = [
        (0, "SEN66 present",        false),
        (1, "Fresh reading",        false),
        (2, "SEN66 warming up",     false),
        (3, "TWAI (CAN) online",    false),
        (4, "SEN66 sticky error",   true),
        (5, "Ionizer fault",        true),
        (6, "Ionizer powered",      false),
    ]

    nonisolated var indicators: [StatusIndicator] {
        Self.labels.map { entry in
            StatusIndicator(
                bit: entry.bit,
                label: entry.label,
                isOn: raw & (1 << entry.bit) != 0,
                isFault: entry.isFault
            )
        }
    }

    private nonisolated func bit(_ index: UInt8) -> Bool { (raw & (1 << index)) != 0 }

    /// Bit 0 — the SEN66 was detected and is being polled.
    nonisolated var sen66Present: Bool { bit(0) }

    /// Bit 1 — this tick carried a freshly measured sample rather than a repeat
    /// of the cached one. Used alongside packet age for the freshness cue (§4).
    nonisolated var isFresh: Bool { bit(1) }

    /// Bit 2 — the SEN66 has not yet produced a valid PM, VOC and CO2 reading
    /// since its last start. Drives the "Warming up" wording (§2).
    nonisolated var sen66Warming: Bool { bit(2) }

    /// Bit 3 — TWAI (CAN) node initialised and not bus-off.
    nonisolated var twaiOnline: Bool { bit(3) }

    /// Bit 4 — any error bit is latched in the SEN66 device status register.
    /// Cleared with command `0x0F` (§1.6).
    nonisolated var sen66StickyError: Bool { bit(4) }

    /// Ionizer power state (bit 6). Unchanged from v1.
    nonisolated var ionizerIsOn: Bool { bit(6) }

    /// Ionizer health (bit 5, 0 = healthy). Only meaningful when powered.
    /// Unchanged from v1.
    nonisolated var ionizerIsHealthy: Bool { !bit(5) }

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

/// The SEN66's own 32-bit device status register (live bytes 36–39), decoded
/// per the SEN6x datasheet §4.3 (§1.1).
///
/// Only the bits the datasheet defines are surfaced; the register is carried raw
/// so an unexpected value can still be reported verbatim in diagnostics.
struct SEN66Status: Equatable, Sendable {
    let raw: UInt32

    /// Datasheet §4.3 bit positions. `isError` separates the five error bits
    /// from the fan-speed *warning*, which is advisory (§4 — surfaced yellow).
    private nonisolated static let flags: [(bit: Int, label: String, isError: Bool)] = [
        (21, "Fan speed out of range",       false),
        (11, "PM sensor error",              true),
        (9,  "CO₂ sensor error",             true),
        (7,  "Gas sensor error (VOC/NOx)",   true),
        (6,  "RH & T sensor error",          true),
        (4,  "Fan error",                    true),
    ]

    private nonisolated func bit(_ index: Int) -> Bool { (raw & (1 << UInt32(index))) != 0 }

    /// Bit 21 — the fan is running more than 10 % off its target speed. A
    /// warning, not an error: readings stay usable (§4).
    nonisolated var fanSpeedWarning: Bool { bit(21) }

    /// Bit 4 — the fan is switched on but not turning.
    nonisolated var fanError: Bool { bit(4) }
    /// Bit 6 — humidity & temperature sensor error.
    nonisolated var humidityTemperatureError: Bool { bit(6) }
    /// Bit 7 — VOC/NOx gas sensor error.
    nonisolated var gasError: Bool { bit(7) }
    /// Bit 9 — CO₂ sensor error.
    nonisolated var co2Error: Bool { bit(9) }
    /// Bit 11 — particulate-matter sensor error.
    nonisolated var pmError: Bool { bit(11) }

    /// True when any of the five datasheet error bits is set. Mirrors what
    /// firmware latches into status bit 4.
    nonisolated var hasError: Bool {
        Self.flags.contains { $0.isError && bit($0.bit) }
    }

    /// Every defined flag, for the diagnostics list. Fan-speed warning first so
    /// it reads at the top of the section where the UI tints it yellow.
    nonisolated var indicators: [StatusIndicator] {
        Self.flags.map { entry in
            StatusIndicator(bit: entry.bit, label: entry.label, isOn: bit(entry.bit), isFault: true)
        }
    }

    /// Only the flags that are currently set — the short list worth showing when
    /// everything is usually clean.
    nonisolated var activeIndicators: [StatusIndicator] {
        indicators.filter(\.isOn)
    }

    /// `true` when the register is completely clear.
    nonisolated var isClean: Bool { raw == 0 }

    /// Hex rendering for diagnostics, e.g. `0x00200000`.
    nonisolated var hexDescription: String { String(format: "0x%08X", raw) }
}

/// Device operating state, live byte 50 (§1.1).
///
/// Decoded with the synthesised `init?(rawValue:)` — an undefined value is
/// surfaced as `nil` ("—") rather than guessed into one of the three states.
enum DeviceState: UInt8, Sendable, CaseIterable {
    case standby = 0
    case enabled = 1
    case waitStandby = 2

    nonisolated var label: String {
        switch self {
        case .standby:     "Standby"
        case .enabled:     "Enabled"
        case .waitStandby: "Waiting for standby"
        }
    }
}
