//
//  AQILevel.swift
//  G2-iOS
//
//  The derived air-quality class, byte 32 of the live packet and byte 22 of a
//  log record (§1.1 / §1.2).
//
//  v2 note: this is no longer the ENS160 UBA index. The SEN66 firmware derives
//  `aq_class` 0–5 itself — worst-component-wins across VOC index, NOx index, CO2
//  and PM (firmware §4) — and the app only displays the class it is given. The
//  band edges live in firmware and are pending client sign-off; nothing here
//  recomputes them.
//

import SwiftUI

/// Derived air-quality class. `0` means the device has no class yet — either the
/// SEN66 is still warming up or no reading is available (§2).
enum AQILevel: Int, CaseIterable, Sendable {
    case unknown   = 0   // Warming up, or no reading
    case excellent = 1
    case good      = 2
    case moderate  = 3
    case poor      = 4
    case unhealthy = 5

    /// Maps a raw byte to a class, clamping out-of-range values to `.unknown`.
    init(raw: UInt8) {
        self = AQILevel(rawValue: Int(raw)) ?? .unknown
    }

    /// Label with no warming-up context available — `.unknown` renders as "—".
    /// Prefer `label(isWarming:)` wherever the status byte is in hand (§2).
    nonisolated var label: String { label(isWarming: false) }

    /// `.unknown` reads as "Warming up" only when the device says it is warming
    /// (status bit 2); otherwise there is simply nothing to show (§2).
    nonisolated func label(isWarming: Bool) -> String {
        switch self {
        case .unknown:   isWarming ? "Warming up" : "—"
        case .excellent: "Excellent"
        case .good:      "Good"
        case .moderate:  "Moderate"
        case .poor:      "Poor"
        case .unhealthy: "Unhealthy"
        }
    }

    /// True when the class is a real reading (not the 0 sentinel).
    nonisolated var isValid: Bool { self != .unknown }

    /// Air-quality color semantics — green (excellent) → red (unhealthy) (§4).
    var color: Color {
        switch self {
        case .unknown:   Theme.textSecondary
        case .excellent: Theme.aqiExcellent
        case .good:      Theme.aqiGood
        case .moderate:  Theme.aqiModerate
        case .poor:      Theme.aqiPoor
        case .unhealthy: Theme.aqiUnhealthy
        }
    }
}
