//
//  DeviceRowView.swift
//  Smart Air Monitor
//
//  One scan-result row: name, disambiguating short id, live RSSI (§3/§5).
//

import SwiftUI

struct DeviceRowView: View {
    let device: DiscoveredDevice
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.spacing) {
                Image(systemName: "sensor.fill")
                    .font(.title3)
                    .foregroundStyle(Theme.accent)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 2) {
                    Text(device.name)
                        .font(.headline)
                        .foregroundStyle(Theme.textPrimary)
                    // Disambiguate same-named units by short identifier (§5).
                    Text("ID …\(device.shortIdentifier) · \(device.rssi) dBm")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .monospacedDigit()
                }

                Spacer()

                SignalStrengthView(rssi: device.rssi)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.textSecondary)
            }
            .card()
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(device.name), identifier ending \(device.shortIdentifier)")
        .accessibilityHint("Double-tap to connect")
    }
}
