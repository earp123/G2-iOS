//
//  AQILevel.swift
//  Smart Air Monitor
//
//  ENS160 UBA air-quality index scale (§2.3).
//

import SwiftUI

/// UBA air-quality index, byte 22 of the sensor payload (§2.3).
enum AQILevel: Int, CaseIterable, Sendable {
    case warmingUp = 0   // Invalid / warming up
    case excellent = 1
    case good      = 2
    case moderate  = 3
    case poor      = 4
    case unhealthy = 5

    /// Maps a raw byte to a level, clamping unknown values to `.warmingUp`.
    init(raw: UInt8) {
        self = AQILevel(rawValue: Int(raw)) ?? .warmingUp
    }

    var label: String {
        switch self {
        case .warmingUp: "Warming up"
        case .excellent: "Excellent"
        case .good:      "Good"
        case .moderate:  "Moderate"
        case .poor:      "Poor"
        case .unhealthy: "Unhealthy"
        }
    }

    /// True when the index is a real reading (not the 0 warming-up sentinel).
    var isValid: Bool { self != .warmingUp }

    /// AQI color semantics — green (good) → red (unhealthy) (§6).
    var color: Color {
        switch self {
        case .warmingUp: Theme.textSecondary
        case .excellent: Theme.aqiExcellent
        case .good:      Theme.aqiGood
        case .moderate:  Theme.aqiModerate
        case .poor:      Theme.aqiPoor
        case .unhealthy: Theme.aqiUnhealthy
        }
    }
}
