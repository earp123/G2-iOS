//
//  ConnectionChip.swift
//  G2-iOS
//
//  Persistent, unobtrusive connection status chip shown in every tab's nav bar
//  (§3). Tapping it opens connection management.
//

import SwiftUI

struct ConnectionChip: View {
    @Environment(BluetoothManager.self) private var bluetooth
    @State private var showingManagement = false

    var body: some View {
        Button {
            showingManagement = true
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(bluetooth.phase == .connected ? Theme.aqiExcellent : Theme.aqiPoor)
                    .frame(width: 7, height: 7)
                Text(bluetooth.connectedDevice?.name ?? "Device")
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .foregroundStyle(Theme.textPrimary)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Theme.surfaceHi, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Connection: \(bluetooth.connectedDevice?.name ?? "device")")
        .accessibilityHint("Double-tap for connection details and disconnect")
        .sheet(isPresented: $showingManagement) {
            ConnectionManagementView()
                .presentationDetents([.medium])
                .presentationBackground(Theme.background)
        }
    }
}
