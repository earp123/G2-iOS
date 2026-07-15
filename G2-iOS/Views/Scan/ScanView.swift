//
//  ScanView.swift
//  G2-iOS
//
//  Pre-connection landing (§3 Phase A). Filtered scan, multi-device list with live
//  RSSI, connect-with-cancel, and explicit handling of every Bluetooth/scan state
//  (§5/§7). Per-session connect only — no auto-reconnect (§3/§9).
//

import SwiftUI

struct ScanView: View {
    @Environment(BluetoothManager.self) private var bluetooth

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                content
                connectingOverlay
            }
            .navigationTitle("GEUE Air Quality")
            .toolbarBackground(Theme.background, for: .navigationBar)
        }
        .onChange(of: bluetooth.availability) { _, new in
            if new.isReady { bluetooth.startScan() }
        }
        .onAppear {
            if bluetooth.availability.isReady { bluetooth.startScan() }
        }
        .onDisappear {
            bluetooth.stopScan()   // stop scanning when leaving the view (battery, §3)
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if let guidance = bluetooth.availability.guidance {
            unavailableState(guidance)
        } else {
            ScrollView {
                VStack(spacing: Theme.spacing) {
                    if let banner = bluetooth.lastDisconnectReason?.bannerText {
                        disconnectBanner(banner)
                    }
                    header
                    if bluetooth.isSimulated { simulatorNote }
                    scanButton
                    resultsSection
                }
                .padding(Theme.spacing)
            }
        }
    }

    private var header: some View {
        VStack(spacing: 8) {
            Image(systemName: "wind")
                .font(.system(size: 56))
                .foregroundStyle(Theme.accent.gradient)
                .symbolEffect(.pulse, isActive: bluetooth.scanState == .scanning)
            Text("Connect your monitor")
                .font(.title3.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
            Text("Scan for nearby GEUE Air Quality devices over Bluetooth.")
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 24)
        .padding(.bottom, 8)
    }

    private var simulatorNote: some View {
        HStack(spacing: 8) {
            Image(systemName: "ladybug.fill").foregroundStyle(Theme.aqiModerate)
            Text("Simulator build — there is no Bluetooth radio, so these are synthetic units feeding mock readings through the real parser.")
                .font(.caption2)
                .foregroundStyle(Theme.textSecondary)
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(Theme.aqiModerate.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var scanButton: some View {
        Button {
            bluetooth.clearDisconnectReason()
            bluetooth.startScan()
        } label: {
            HStack {
                if bluetooth.scanState == .scanning {
                    ProgressView().tint(Theme.background)
                    Text("Scanning…")
                } else {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                    Text(bluetooth.scanState == .noResults ? "Scan again" : "Scan")
                }
            }
            .font(.headline)
            .foregroundStyle(Theme.background)
            .frame(maxWidth: .infinity)
            .padding()
            .background(Theme.accent, in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
        }
        .disabled(bluetooth.scanState == .scanning)
    }

    @ViewBuilder
    private var resultsSection: some View {
        if !bluetooth.discoveredDevices.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("DEVICES (\(bluetooth.discoveredDevices.count))")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.textSecondary)
                ForEach(bluetooth.discoveredDevices) { device in
                    DeviceRowView(device: device) { bluetooth.connect(to: device.id) }
                }
            }
        } else if bluetooth.scanState == .scanning {
            emptyState(icon: "dot.radiowaves.left.and.right",
                       title: "Searching…",
                       message: "Looking for GEUE Air Quality units in range.")
        } else if bluetooth.scanState == .noResults {
            emptyState(icon: "magnifyingglass",
                       title: "No monitors found",
                       message: "Make sure your device is powered on and nearby, then scan again.")
        } else {
            emptyState(icon: "antenna.radiowaves.left.and.right",
                       title: "Ready to scan",
                       message: "Tap Scan to discover your monitor.")
        }
    }

    // MARK: - States

    private func unavailableState(_ guidance: String) -> some View {
        ContentUnavailableView {
            Label("Bluetooth unavailable", systemImage: "exclamationmark.triangle")
        } description: {
            Text(guidance)
        }
        .foregroundStyle(Theme.textPrimary)
    }

    private func emptyState(icon: String, title: String, message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 36))
                .foregroundStyle(Theme.textSecondary)
            Text(title).font(.headline).foregroundStyle(Theme.textPrimary)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private func disconnectBanner(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle.fill").foregroundStyle(Theme.accent)
            Text(text)
                .font(.footnote)
                .foregroundStyle(Theme.textPrimary)
            Spacer(minLength: 0)
            Button {
                bluetooth.clearDisconnectReason()
            } label: {
                Image(systemName: "xmark").font(.caption.weight(.bold))
            }
            .foregroundStyle(Theme.textSecondary)
        }
        .padding()
        .background(Theme.surfaceHi, in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
    }

    // MARK: - Connecting overlay

    @ViewBuilder
    private var connectingOverlay: some View {
        if bluetooth.phase == .connecting || bluetooth.phase == .discovering {
            ZStack {
                Color.black.opacity(0.6).ignoresSafeArea()
                VStack(spacing: Theme.spacing) {
                    ProgressView().controlSize(.large).tint(Theme.accent)
                    Text("Connecting to \(bluetooth.connectedDevice?.name ?? "device")…")
                        .font(.headline)
                        .foregroundStyle(Theme.textPrimary)
                    Button("Cancel", role: .cancel) { bluetooth.cancelConnect() }
                        .buttonStyle(.bordered)
                        .tint(Theme.accent)
                }
                .padding(28)
                .background(Theme.surfaceHi, in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
                .padding(40)
            }
            .transition(.opacity)
        }
    }
}
