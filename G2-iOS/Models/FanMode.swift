//
//  FanMode.swift
//  G2-iOS
//
//  Fan operating modes and presets, mapped to command opcodes (§2.4 / §6.2).
//

import Foundation

/// Top-level fan mode shown in the segmented control (§6.2).
enum FanMode: String, CaseIterable, Identifiable, Sendable {
    case auto      // AQI-driven       → 0x03
    case tvocAuto  // TVOC-setpoint    → 0x0A
    case manual    // presets + slider → 0x02/0x04…0x08

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto:     "Auto (AQI)"
        case .tvocAuto: "TVOC Auto"
        case .manual:   "Manual"
        }
    }
}

/// Manual fan presets. Labels map to 25/50/75/100% — NOT 33/66/100 (§2.4 note).
enum FanPreset: CaseIterable, Identifiable, Sendable {
    case off, low, med, high, max

    var id: String { title }

    var title: String {
        switch self {
        case .off:  "Off"
        case .low:  "Low"
        case .med:  "Med"
        case .high: "High"
        case .max:  "Max"
        }
    }

    /// Percentage shown in the UI — the source of truth for the label (§2.4 note).
    var percent: Int {
        switch self {
        case .off:  0
        case .low:  25
        case .med:  50
        case .high: 75
        case .max:  100
        }
    }

    var command: GATT.Command {
        switch self {
        case .off:  .fanOff
        case .low:  .fanLow
        case .med:  .fanMed
        case .high: .fanHigh
        case .max:  .fanMax
        }
    }
}
