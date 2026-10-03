//
//  DeviceSettings.swift
//  G2-iOS
//
//  The Settings characteristic — 12 bytes in contract v3 (thresholds-v3 §2.3):
//    [0–7]  retired (were VOC-index thresholds) — READ returns 0, written as 0
//    [8]    LED brightness u8 5–100
//    [9]    fan mode u8 0 Auto / 2 Manual (1 is rejected by firmware)
//    [10]   fan manual % u8 0–100
//    [11]   reserved
//
//  The client always writes all 12 bytes, so the brightness editor round-trips
//  the fan fields rather than clobbering them. The 8-byte legacy write is gone —
//  v3 firmware rejects any length other than 12.
//
//  v3 note: the VOC lo/med/hi/max thresholds and the Custom fan mode they drove
//  are retired. Every adjustable band now lives in the 60-byte Thresholds
//  characteristic (`ThresholdsBlob`).
//

import Foundation

/// The full 12-byte Settings payload (§2.3).
struct DeviceSettings: Equatable, Sendable {
    /// 5–100 %. Firmware clamps below 5 to 5 and never persists a lower value.
    var ledBrightnessPct: UInt8
    /// `nil` when byte 9 carries an undefined mode — reported, not guessed.
    var fanMode: FanMode?
    /// 0–100 %, only meaningful in Manual mode. 0 is a legal, persisted value.
    var fanManualPct: UInt8

    static let defaults = DeviceSettings(
        ledBrightnessPct: GATT.ledBrightnessDefault,
        fanMode: .auto,
        fanManualPct: 0
    )

    /// True when the device is parked in Manual at 0 % — the fan will stay off
    /// across the next ignition cycle, by firmware design (§5).
    var isManualOff: Bool {
        fanMode == .manual && fanManualPct == 0
    }

    /// Parses a 12-byte payload from a READ, or `nil` if malformed (§7). Bytes
    /// 0–7 are retired and ignored, whatever they hold.
    init?(data: Data) {
        guard data.count >= GATT.settingsPayloadLength else { return nil }
        let b = [UInt8](data)
        self.ledBrightnessPct = Self.clampBrightness(b[GATT.SettingsOffset.ledBrightness])
        self.fanMode = FanMode(wire: b[GATT.SettingsOffset.fanMode])
        self.fanManualPct = Swift.min(100, b[GATT.SettingsOffset.fanManualPct])
    }

    init(ledBrightnessPct: UInt8, fanMode: FanMode?, fanManualPct: UInt8) {
        self.ledBrightnessPct = Self.clampBrightness(ledBrightnessPct)
        self.fanMode = fanMode
        self.fanManualPct = Swift.min(100, fanManualPct)
    }

    /// Serializes the full 12-byte little-endian payload for a WRITE (§2.3).
    /// Bytes 0–7 are always zero: firmware ignores them, and nothing the app
    /// once stored there is meaningful any more.
    var encoded: Data {
        var bytes = [UInt8](repeating: 0, count: GATT.settingsPayloadLength)
        bytes[GATT.SettingsOffset.ledBrightness] = Self.clampBrightness(ledBrightnessPct)
        // An unknown device mode round-trips as Auto rather than as a value the
        // firmware would reject. `FanMode` has no case for the retired 1, so the
        // byte is only ever 0 or 2.
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
