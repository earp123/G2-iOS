//
//  DeviceSettings.swift
//  G2-iOS
//
//  The Settings characteristic — 12 bytes in contract v2 (§1.3):
//    [0–7]  VOC-index thresholds lo/med/hi/max, 4 × u16 LE
//    [8]    LED brightness u8 5–100
//    [9]    fan mode u8 0/1/2
//    [10]   fan manual % u8 0–100
//    [11]   reserved
//
//  The client always writes all 12 bytes (§1.3), so every editor — thresholds,
//  brightness, fan — round-trips the other fields rather than clobbering them.
//
//  v2 note: the thresholds are **VOC index (1–500)**, not TVOC ppb. The unit
//  changed, not just the name, so `TVOCThresholds` became `VOCThresholds` and
//  the firmware defaults moved to 100/150/250/400.
//

import Foundation

/// VOC-index thresholds for Custom fan mode (§1.3). Must be strictly increasing:
/// `lo < med < hi < max`. The firmware rejects non-monotonic writes (ATT error),
/// so we validate client-side before writing.
struct VOCThresholds: Equatable, Sendable {
    var lo: UInt16
    var med: UInt16
    var hi: UInt16
    var max: UInt16

    /// Firmware defaults, in VOC index units (§1.3).
    static let defaults = VOCThresholds(lo: 100, med: 150, hi: 250, max: 400)

    /// Valid range for every threshold — the VOC index scale (§1.3).
    static let validRange = Int(GATT.vocIndexMin)...Int(GATT.vocIndexMax)

    /// `true` iff `lo < med < hi < max` (§1.3 / §6).
    var isMonotonic: Bool {
        lo < med && med < hi && hi < max
    }

    /// `true` iff every threshold sits on the 1–500 index scale (§1.3).
    var isInRange: Bool {
        [lo, med, hi, max].allSatisfy { Self.validRange.contains(Int($0)) }
    }

    var isValid: Bool { isMonotonic && isInRange }

    init(lo: UInt16, med: UInt16, hi: UInt16, max: UInt16) {
        self.lo = lo; self.med = med; self.hi = hi; self.max = max
    }

    /// Decodes bytes 0–7 of a settings payload.
    init(bytes b: [UInt8], at offset: Int) {
        func u16(_ i: Int) -> UInt16 { UInt16(b[i]) | (UInt16(b[i + 1]) << 8) }
        self.lo  = u16(offset + 0)
        self.med = u16(offset + 2)
        self.hi  = u16(offset + 4)
        self.max = u16(offset + 6)
    }

    /// The four thresholds as little-endian bytes (8 bytes).
    var encodedBytes: [UInt8] {
        [lo, med, hi, max].flatMap { [UInt8($0 & 0x00FF), UInt8(($0 >> 8) & 0x00FF)] }
    }
}

/// Read-only reference rows for the VOC index → fan-speed mapping table (§6).
extension VOCThresholds {
    struct FanMappingRow: Identifiable {
        let id = UUID()
        let condition: String
        let fanSpeed: String
    }

    var fanMappingRows: [FanMappingRow] {
        [
            .init(condition: "< \(lo)",  fanSpeed: "0%"),
            .init(condition: "≥ \(lo)",  fanSpeed: "25%"),
            .init(condition: "≥ \(med)", fanSpeed: "50%"),
            .init(condition: "≥ \(hi)",  fanSpeed: "75%"),
            .init(condition: "≥ \(max)", fanSpeed: "100%"),
        ]
    }
}

/// The full 12-byte Settings payload (§1.3).
struct DeviceSettings: Equatable, Sendable {
    var thresholds: VOCThresholds
    /// 5–100 %. Firmware clamps below 5 to 5 and never persists a lower value.
    var ledBrightnessPct: UInt8
    /// `nil` when byte 9 carries an undefined mode — reported, not guessed.
    var fanMode: FanMode?
    /// 0–100 %, only meaningful in Manual mode. 0 is a legal, persisted value.
    var fanManualPct: UInt8

    static let defaults = DeviceSettings(
        thresholds: .defaults,
        ledBrightnessPct: GATT.ledBrightnessDefault,
        fanMode: .auto,
        fanManualPct: 0
    )

    /// True when the device is parked in Manual at 0 % — the fan will stay off
    /// across the next ignition cycle, by firmware design (§5).
    var isManualOff: Bool {
        fanMode == .manual && fanManualPct == 0
    }

    /// Parses a 12-byte payload from a READ, or `nil` if malformed (§7).
    init?(data: Data) {
        guard data.count >= GATT.settingsPayloadLength else { return nil }
        let b = [UInt8](data)
        self.thresholds = VOCThresholds(bytes: b, at: GATT.SettingsOffset.thresholds)
        self.ledBrightnessPct = Self.clampBrightness(b[GATT.SettingsOffset.ledBrightness])
        self.fanMode = FanMode(wire: b[GATT.SettingsOffset.fanMode])
        self.fanManualPct = Swift.min(100, b[GATT.SettingsOffset.fanManualPct])
    }

    init(thresholds: VOCThresholds, ledBrightnessPct: UInt8, fanMode: FanMode?, fanManualPct: UInt8) {
        self.thresholds = thresholds
        self.ledBrightnessPct = Self.clampBrightness(ledBrightnessPct)
        self.fanMode = fanMode
        self.fanManualPct = Swift.min(100, fanManualPct)
    }

    /// Serializes the full 12-byte little-endian payload for a WRITE (§1.3).
    var encoded: Data {
        var bytes = [UInt8](repeating: 0, count: GATT.settingsPayloadLength)
        bytes.replaceSubrange(
            GATT.SettingsOffset.thresholds..<(GATT.SettingsOffset.thresholds + 8),
            with: thresholds.encodedBytes
        )
        bytes[GATT.SettingsOffset.ledBrightness] = Self.clampBrightness(ledBrightnessPct)
        // An unknown device mode round-trips as Auto rather than as a value the
        // firmware would reject (it rejects fan_mode > 2).
        bytes[GATT.SettingsOffset.fanMode] = (fanMode ?? .auto).wire
        bytes[GATT.SettingsOffset.fanManualPct] = Swift.min(100, fanManualPct)
        bytes[GATT.SettingsOffset.reserved] = 0
        return Data(bytes)
    }

    /// Firmware clamps brightness into 5–100 (§1.3); we mirror it so the UI never
    /// shows a value the device would silently change underneath it.
    static func clampBrightness(_ raw: UInt8) -> UInt8 {
        Swift.min(GATT.ledBrightnessMax, Swift.max(GATT.ledBrightnessMin, raw))
    }
}
