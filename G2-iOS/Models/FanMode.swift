//
//  FanMode.swift
//  G2-iOS
//
//  Fan operating modes and presets, mapped to command opcodes (§1.6 / §5).
//
//  v2 note: the mode is no longer app-local state. Live byte 34 and settings
//  byte 9 both carry it, so the picker mirrors the device (§5). "TVOC Auto" is
//  renamed **Custom** — the opcode (0x0A) is unchanged, but its thresholds are
//  now VOC index rather than ppb (§1.3).
//

import Foundation

/// Top-level fan mode. The raw values are the wire encoding of live byte 34 and
/// settings byte 9: 0 Auto, 1 Custom, 2 Manual (§1.1 / §1.3).
enum FanMode: UInt8, CaseIterable, Identifiable, Sendable {
    case auto   = 0   // aq_class-driven  → 0x03
    case custom = 1   // VOC-index setpoints → 0x0A
    case manual = 2   // presets + slider → 0x02/0x04…0x08

    var id: UInt8 { rawValue }

    var title: String {
        switch self {
        case .auto:   "Auto"
        case .custom: "Custom"
        case .manual: "Manual"
        }
    }

    /// Short description shown under the picker when an auto mode is selected (§5).
    var note: String {
        switch self {
        case .auto:   "Auto (air-quality class)"
        case .custom: "Custom (VOC index thresholds)"
        case .manual: "Manual"
        }
    }

    /// The opcode that selects this mode. `.manual` has no single opcode — it is
    /// entered by sending a speed (a preset or the slider's `0x02`).
    var command: GATT.Command? {
        switch self {
        case .auto:   .fanAuto
        case .custom: .fanCustom
        case .manual: nil
        }
    }

    /// Decodes live byte 34 / settings byte 9. `nil` for an undefined value —
    /// never silently coerced to a mode the device isn't in.
    init?(wire: UInt8) {
        self.init(rawValue: wire)
    }

    /// Wire encoding for settings byte 9.
    var wire: UInt8 { rawValue }
}

/// Manual fan presets. Labels map to 25/50/75/100% — NOT 33/66/100 (§1.6 note).
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

    /// Percentage shown in the UI — the source of truth for the label (§1.6 note).
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
