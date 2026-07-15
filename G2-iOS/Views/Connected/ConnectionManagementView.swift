//
//  ConnectionManagementView.swift
//  G2-iOS
//
//  Connection management sheet (§3/§6.4): device name, link state, signal, MTU,
//  and user-initiated disconnect (returns to ScanView).
//

import SwiftUI

struct ConnectionManagementView: View {
    @Environment(BluetoothManager.self) private var bluetooth
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Theme.spacing) {
                    VStack(alignment: .leading, spacing: 12) {
                        InfoRow(label: "Device", value: bluetooth.connectedDevice?.name ?? "—")
                        Divider().overlay(Theme.hairline)
                        InfoRow(label: "Status", value: statusText)
                        Divider().overlay(Theme.hairline)
                        HStack {
                            Text("Signal").foregroundStyle(Theme.textSecondary)
                            Spacer()
                            if let rssi = bluetooth.liveRSSI {
                                Text("\(rssi) dBm").monospacedDigit().foregroundStyle(Theme.textPrimary)
                                SignalStrengthView(rssi: rssi)
                            } else {
                                Text("—").foregroundStyle(Theme.textSecondary)
                            }
                        }
                        Divider().overlay(Theme.hairline)
                        InfoRow(label: "Negotiated MTU",
                                value: bluetooth.mtu.map { "\($0) bytes" } ?? "Unavailable")
                    }
                    .font(.subheadline)
                    .card()

                    Button(role: .destructive) {
                        bluetooth.disconnect()
                        dismiss()
                    } label: {
                        Label("Disconnect", systemImage: "xmark.circle.fill")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Theme.aqiUnhealthy.opacity(0.18),
                                        in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
                            .foregroundStyle(Theme.aqiUnhealthy)
                    }
                }
                .padding(Theme.spacing)
            }
            .background(Theme.background)
            .navigationTitle("Connection")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var statusText: String {
        switch bluetooth.phase {
        case .connected:   "Connected"
        case .discovering: "Discovering…"
        case .connecting:  "Connecting…"
        case .disconnected: "Disconnected"
        }
    }
}

/// Simple label/value row used across detail and settings views.
struct InfoRow: View {
    let label: String
    let value: String
    var body: some View {
        HStack {
            Text(label).foregroundStyle(Theme.textSecondary)
            Spacer()
            Text(value).foregroundStyle(Theme.textPrimary).multilineTextAlignment(.trailing)
        }
    }
}
