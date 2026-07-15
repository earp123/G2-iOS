//
//  SettingsView.swift
//  Smart Air Monitor
//
//  TVOC threshold editor + device diagnostics + time-sync + connection management
//  (§6.4). Thresholds are validated strictly-increasing client-side and the editor
//  is pre-populated from a READ of the Settings characteristic (§2.5).
//

import SwiftUI

struct SettingsView: View {
    @Environment(BluetoothManager.self) private var bluetooth

    // Editor state (ppb), pre-populated from the device READ.
    @State private var lo = Int(TVOCThresholds.defaults.lo)
    @State private var med = Int(TVOCThresholds.defaults.med)
    @State private var hi = Int(TVOCThresholds.defaults.hi)
    @State private var maxVal = Int(TVOCThresholds.defaults.max)
    @State private var didPopulate = false
    @State private var timeSyncNote: String?

    private var edited: TVOCThresholds {
        TVOCThresholds(lo: UInt16(lo), med: UInt16(med), hi: UInt16(hi), max: UInt16(maxVal))
    }
    private var isValid: Bool { edited.isMonotonic }

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.spacing) {
                thresholdEditor
                fanMappingReference
                diagnostics
                timeSyncStub
                disconnectButton
            }
            .padding(Theme.spacing)
        }
        .background(Theme.background)
        .onAppear {
            bluetooth.readSettings()
            populateIfPossible()
        }
        .onChange(of: bluetooth.thresholds) { _, _ in populateIfPossible() }
    }

    // MARK: - TVOC threshold editor (§6.4 / §2.5)

    private var thresholdEditor: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader("TVOC THRESHOLDS (ppb)")

            thresholdStepper("Low",    value: $lo)
            thresholdStepper("Medium", value: $med)
            thresholdStepper("High",   value: $hi)
            thresholdStepper("Max",    value: $maxVal)

            if !isValid {
                Label("Values must be strictly increasing: low < medium < high < max.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(Theme.aqiPoor)
            }

            HStack {
                Button("Reset to defaults") {
                    let d = TVOCThresholds.defaults
                    lo = Int(d.lo); med = Int(d.med); hi = Int(d.hi); maxVal = Int(d.max)
                }
                .font(.subheadline)
                .tint(Theme.textSecondary)

                Spacer()

                Button {
                    bluetooth.writeSettings(edited)   // validates + writes 8 bytes (§2.5)
                } label: {
                    Text("Save").font(.headline)
                        .padding(.horizontal, 20).padding(.vertical, 8)
                        .background(isValid ? Theme.accent : Theme.surfaceHi,
                                    in: Capsule())
                        .foregroundStyle(isValid ? Theme.background : Theme.textSecondary)
                }
                .disabled(!isValid)   // disable Save until valid (§6.4)
            }
        }
        .card()
    }

    private func thresholdStepper(_ label: String, value: Binding<Int>) -> some View {
        HStack {
            Text(label).foregroundStyle(Theme.textPrimary)
            Spacer()
            Text("\(value.wrappedValue)")
                .font(.headline.monospacedDigit())
                .foregroundStyle(Theme.accent)
                .frame(minWidth: 64, alignment: .trailing)
            Stepper(label, value: value, in: 0...65535, step: 10)
                .labelsHidden()
        }
    }

    // MARK: - TVOC → fan mapping (read-only reference, §2.5)

    private var fanMappingReference: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("FAN MAPPING (TVOC AUTO)")
            ForEach(edited.fanMappingRows) { row in
                HStack {
                    Text(row.condition).foregroundStyle(Theme.textSecondary)
                    Spacer()
                    Text(row.fanSpeed).foregroundStyle(Theme.textPrimary).monospacedDigit()
                }
                .font(.subheadline)
            }
        }
        .card()
    }

    // MARK: - Diagnostics (§6.4)

    private var diagnostics: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("DEVICE DIAGNOSTICS")

            InfoRow(label: "Connection", value: connectionText)
            Divider().overlay(Theme.hairline)
            HStack {
                Text("Signal").foregroundStyle(Theme.textSecondary)
                Spacer()
                if let rssi = bluetooth.liveRSSI {
                    Text("\(rssi) dBm").monospacedDigit().foregroundStyle(Theme.textPrimary)
                    SignalStrengthView(rssi: rssi)
                } else { Text("—").foregroundStyle(Theme.textSecondary) }
            }
            Divider().overlay(Theme.hairline)
            InfoRow(label: "Negotiated MTU", value: bluetooth.mtu.map { "\($0) bytes" } ?? "Unavailable")

            Divider().overlay(Theme.hairline)
            Text("SENSOR HEALTH").font(.caption.weight(.semibold)).foregroundStyle(Theme.textSecondary)
            if let status = bluetooth.latestReading?.status {
                ForEach(status.indicators) { StatusIndicatorRow(indicator: $0) }
            } else {
                Text("Awaiting a sensor reading…")
                    .font(.subheadline).foregroundStyle(Theme.textSecondary)
            }
        }
        .font(.subheadline)
        .card()
    }

    private var connectionText: String {
        switch bluetooth.phase {
        case .connected:    "Connected"
        case .discovering:  "Discovering…"
        case .connecting:   "Connecting…"
        case .disconnected: "Disconnected"
        }
    }

    // MARK: - Time-sync (opcode 0x0B SET_TIME, §6.4 / §2.4)

    private var timeSyncStub: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("DEVICE TIME")

            Button {
                bluetooth.setDeviceTime()
                timeSyncNote = "Synced to \(Date.now.formatted(date: .abbreviated, time: .shortened))."
            } label: {
                Label("Sync device clock", systemImage: "clock.arrow.2.circlepath")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Theme.surfaceHi, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .foregroundStyle(Theme.textPrimary)
            }
            .disabled(bluetooth.phase != .connected)

            if let note = timeSyncNote {
                Label(note, systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(Theme.aqiExcellent)
            }
        }
        .card()
    }

    // MARK: - Connection management (§6.4)

    private var disconnectButton: some View {
        Button(role: .destructive) {
            bluetooth.disconnect()   // returns to ScanView via phase change
        } label: {
            Label("Disconnect", systemImage: "xmark.circle.fill")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding()
                .background(Theme.aqiUnhealthy.opacity(0.16),
                            in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
                .foregroundStyle(Theme.aqiUnhealthy)
        }
    }

    // MARK: - Helpers

    private func sectionHeader(_ text: String) -> some View {
        Text(text).font(.caption.weight(.semibold)).foregroundStyle(Theme.textSecondary)
    }

    /// Populate the editor from the device's current thresholds, once.
    private func populateIfPossible() {
        guard !didPopulate, let t = bluetooth.thresholds else { return }
        lo = Int(t.lo); med = Int(t.med); hi = Int(t.hi); maxVal = Int(t.max)
        didPopulate = true
    }
}
