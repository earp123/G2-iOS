//
//  TVOCThresholds.swift
//  Smart Air Monitor
//
//  The Settings characteristic: 4 × uint16 LE TVOC thresholds (§2.5).
//

import Foundation

/// TVOC thresholds for TVOC-auto fan mode (§2.5). Must be strictly increasing:
/// `lo < med < hi < max`. The firmware rejects non-monotonic writes (ATT error),
/// so we validate client-side before writing.
struct TVOCThresholds: Equatable, Sendable {
    var lo: UInt16
    var med: UInt16
    var hi: UInt16
    var max: UInt16

    /// Firmware defaults, in ppb (§2.5).
    static let defaults = TVOCThresholds(lo: 150, med: 350, hi: 650, max: 1000)

    /// `true` iff `lo < med < hi < max` (§2.5 / §6.4).
    var isMonotonic: Bool {
        lo < med && med < hi && hi < max
    }

    /// Serializes to the 8-byte little-endian payload for a WRITE (§2.5).
    var encoded: Data {
        var data = Data(capacity: GATT.settingsPayloadLength)
        for value in [lo, med, hi, max] {
            data.append(UInt8(value & 0x00FF))
            data.append(UInt8((value >> 8) & 0x00FF))
        }
        return data
    }

    /// Parses the 8-byte payload from a READ, or `nil` if malformed (§7).
    init?(data: Data) {
        guard data.count >= GATT.settingsPayloadLength else { return nil }
        let b = [UInt8](data)
        func u16(_ i: Int) -> UInt16 { UInt16(b[i]) | (UInt16(b[i + 1]) << 8) }
        self.lo  = u16(0)
        self.med = u16(2)
        self.hi  = u16(4)
        self.max = u16(6)
    }

    init(lo: UInt16, med: UInt16, hi: UInt16, max: UInt16) {
        self.lo = lo; self.med = med; self.hi = hi; self.max = max
    }
}

/// Read-only reference rows for the TVOC → fan-speed mapping table (§2.5).
extension TVOCThresholds {
    struct FanMappingRow: Identifiable {
        let id = UUID()
        let condition: String
        let fanSpeed: String
    }

    var fanMappingRows: [FanMappingRow] {
        [
            .init(condition: "< \(lo) ppb",  fanSpeed: "0%"),
            .init(condition: "≥ \(lo) ppb",  fanSpeed: "25%"),
            .init(condition: "≥ \(med) ppb", fanSpeed: "50%"),
            .init(condition: "≥ \(hi) ppb",  fanSpeed: "75%"),
            .init(condition: "≥ \(max) ppb", fanSpeed: "100%"),
        ]
    }
}
