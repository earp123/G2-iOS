//
//  AQILevel.swift
//  G2-iOS
//
//  The two firmware-derived classes carried in the packed class byte — live
//  byte 32 and log-record byte 22 (thresholds-v3 §1.1, see `AirClasses`):
//   • `AQILevel` — the **gas** class, low nibble, 0–5 (worst of VOC / NOx / CO₂).
//   • `PMLevel`  — the **PM** class, high nibble, 0–3 (worst of PM1 / PM2.5 / PM10).
//
//  v3 note: PM no longer folds into the gas class — each has its own LED on the
//  device and its own tile in the app. The colours mirror the LEDs: gas 0 grey,
//  1–2 green, 3 orange, 4–5 red; PM 0 grey, 1 green, 2 orange, 3 red. The app
//  only displays the classes it is given; the band edges are user-editable on
//  the device and nothing here recomputes them.
//

import SwiftUI

/// Gas class (low nibble of the class byte). `0` means the device has no class
/// yet — either the SEN66 is still warming up or no reading is available (§2).
enum AQILevel: Int, CaseIterable, Sendable {
    case unknown   = 0   // Warming up, or no reading
    case excellent = 1
    case good      = 2
    case moderate  = 3
    case poor      = 4
    case unhealthy = 5

    /// Maps a raw class to a level, clamping out-of-range values to `.unknown`.
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

    /// Gas tile colour, matching the device's gas LED (§1.1): 0 grey,
    /// 1–2 green, 3 orange, 4–5 red.
    var color: Color {
        switch self {
        case .unknown:              Theme.textSecondary
        case .excellent, .good:     Theme.aqiExcellent
        case .moderate:             Theme.aqiPoor
        case .poor, .unhealthy:     Theme.aqiUnhealthy
        }
    }
}

/// PM class (high nibble of the class byte), worst of PM1 / PM2.5 / PM10 —
/// PM4.0 is reported but never classified. `0` means warming or no valid PM.
/// A log record written before contract v3 carries 0 here (§1.1).
enum PMLevel: Int, CaseIterable, Sendable {
    case unknown   = 0
    case good      = 1
    case attention = 2
    case hazard    = 3

    /// Maps a raw class to a level, clamping out-of-range values to `.unknown`.
    init(raw: UInt8) {
        self = PMLevel(rawValue: Int(raw)) ?? .unknown
    }

    /// Label with no warming-up context available — `.unknown` renders as "—".
    nonisolated var label: String { label(isWarming: false) }

    /// `.unknown` reads as "Warming up" only while the device says so (§2).
    nonisolated func label(isWarming: Bool) -> String {
        switch self {
        case .unknown:   isWarming ? "Warming up" : "—"
        case .good:      "Good"
        case .attention: "Attention"
        case .hazard:    "Hazard"
        }
    }

    /// True when the class is a real reading (not the 0 sentinel).
    nonisolated var isValid: Bool { self != .unknown }

    /// PM tile colour, matching the device's PM LED (§1.1): 0 grey, 1 green,
    /// 2 orange, 3 red.
    var color: Color {
        switch self {
        case .unknown:   Theme.textSecondary
        case .good:      Theme.aqiExcellent
        case .attention: Theme.aqiPoor
        case .hazard:    Theme.aqiUnhealthy
        }
    }
}
