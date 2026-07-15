//
//  ConnectionState.swift
//  Smart Air Monitor
//
//  Connection lifecycle and Bluetooth-availability states (§3 / §7).
//

import Foundation

/// High-level connection lifecycle used to gate navigation (§3).
enum ConnectionPhase: Equatable, Sendable {
    case disconnected
    case connecting
    case discovering          // connected, discovering services/characteristics
    case connected            // service + characteristics ready, CCCD subscribed
}

/// Why the app returned to the scan screen — drives the ScanView banner (§3 / §7).
enum DisconnectReason: Equatable, Sendable {
    case userInitiated
    case linkLoss(String?)        // unexpected drop (device re-advertises)
    case connectFailed(String?)
    case discoveryFailed(String?)

    var bannerText: String? {
        switch self {
        case .userInitiated:
            return nil  // expected — no alarming banner
        case .linkLoss:
            return "Lost connection to the device. It re-advertises automatically — scan again to reconnect."
        case .connectFailed(let msg):
            return "Couldn’t connect\(msg.map { ": \($0)" } ?? ""). Try scanning again."
        case .discoveryFailed(let msg):
            return "Connected, but the device’s services couldn’t be read\(msg.map { " (\($0))" } ?? ""). Try again."
        }
    }
}

/// Bluetooth-radio availability, mapped from `CBManagerState` (§7).
enum BluetoothAvailability: Equatable, Sendable {
    case unknown          // resetting / .unknown — transient
    case poweredOff
    case unauthorized
    case unsupported
    case ready

    var guidance: String? {
        switch self {
        case .unknown:      "Preparing Bluetooth…"
        case .poweredOff:   "Bluetooth is off. Turn it on in Settings or Control Center to scan for your monitor."
        case .unauthorized: "GEUE Air Quality needs Bluetooth permission. Enable it in Settings › GEUE Air Quality."
        case .unsupported:  "This device doesn’t support Bluetooth Low Energy."
        case .ready:        nil
        }
    }

    var isReady: Bool { self == .ready }
}

/// Result of an attempted command write, for user-facing feedback (§7).
enum CommandFeedback: Equatable, Hashable, Sendable {
    case rejected(String)   // ATT 0x0E or other write failure
    case timedOut
}
