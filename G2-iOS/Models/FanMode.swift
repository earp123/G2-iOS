//
//  FanMode.swift
//  G2-iOS
//
//  Fan operating modes and presets, mapped to command opcodes (§1.6 / §5).
//
//  The mode is device state, not app-local state: live byte 34 and settings
//  byte 9 both carry it, so the picker mirrors the device (§5).
//
//  v3 note: Custom (value 1, opcode 0x0A) is retired — the gas fan table in the
//  Thresholds characteristic subsumes it (thresholds-v3 §1). The modes are Auto
//  and Manual; value 1 stays reserved on the wire forever and firmware never
//  sends it.
//

import Foundation

/// Top-level fan mode. The raw values are the wire encoding of live byte 34 and
/// settings byte 9: 0 Auto, 2 Manual (thresholds-v3 §2.3 / §2.6). 1 was Custom
/// and is deliberately not renumbered.
enum FanMode: UInt8, CaseIterable, Identifiable, Sendable {
    case auto   = 0   // gas/PM fan tables, worst wins → 0x03
    case manual = 2   // presets + slider → 0x02/0x04…0x08

    var id: UInt8 { rawValue }

    /// Wire value of the retired Custom mode. Firmware v3 never sends it and
    /// rejects it on a settings write.
    static let retiredCustomWire: UInt8 = 1

    var title: String {
        switch self {
        case .auto:   "Auto"
        case .manual: "Manual"
        }
    }

    /// Short description shown under the picker when Auto is selected (§5).
    var note: String {
        switch self {
        case .auto:   "Auto (gas and PM classes)"
        case .manual: "Manual"
        }
    }

    /// The opcode that selects this mode. `.manual` has no single opcode — it is
    /// entered by sending a speed (a preset or the slider's `0x02`).
    var command: GATT.Command? {
        switch self {
        case .auto:   .fanAuto
        case .manual: nil
        }
    }

    /// Decodes live byte 34 / settings byte 9. `nil` for an undefined value —
    /// never silently coerced to a mode the device isn't in.
    ///
    /// The one exception is the retired Custom value 1: v3 firmware never sends
    /// it (it loads a saved 1 as Auto), so its arrival means a contract break.
    /// It decodes as `.auto` — what the device is actually running — and trips
    /// an assertion in debug builds (thresholds-v3 §2 item 2).
    init?(wire: UInt8) {
        self.init(wire: wire, onRetiredCustom: {
            assertionFailure("fan_mode 1 (retired Custom) received — contract v3 firmware never sends it")
        })
    }

    /// Same decode with the retired-value hook injected, so tests can verify the
    /// `1 → .auto` mapping and that the hook fires without tripping the debug
    /// assertion.
    init?(wire: UInt8, onRetiredCustom: () -> Void) {
        if wire == Self.retiredCustomWire {
            onRetiredCustom()
            self = .auto
            return
        }
        guard let mode = FanMode(rawValue: wire) else { return nil }
        self = mode
    }

    /// Wire encoding for settings byte 9 — only ever 0 or 2.
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
