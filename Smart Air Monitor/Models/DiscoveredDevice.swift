//
//  DiscoveredDevice.swift
//  Smart Air Monitor
//
//  A peripheral surfaced in the scan list (§3 Phase A / §5).
//

import Foundation

/// A scan result, keyed by `peripheral.identifier` and updated in place (§5).
struct DiscoveredDevice: Identifiable, Equatable, Sendable {
    let id: UUID
    let name: String
    var rssi: Int

    /// Last 4 of the identifier UUID, used to disambiguate same-named units (§5).
    var shortIdentifier: String {
        String(id.uuidString.suffix(4))
    }

    /// Coarse signal bucket for the strength glyph (0…3).
    var signalBars: Int {
        switch rssi {
        case ..<(-90): 0
        case ..<(-75): 1
        case ..<(-60): 2
        default:       3
        }
    }
}
