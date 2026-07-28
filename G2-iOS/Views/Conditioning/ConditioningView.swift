//
//  ConditioningView.swift
//  G2-iOS
//
//  Unified conditioning control (§6.2): combines fan speed control with ionizer
//  power/health monitoring. Fan control includes Auto, TVOC Auto, and Manual modes
//  with presets and debounced slider. Ionizer state (off/healthy/faulted) displayed
//  as read-only status.
//

import SwiftUI

struct ConditioningView: View {
    @Environment(BluetoothManager.self) private var bluetooth

    @State private var mode: FanMode = .manual
    @State private var sliderValue: Double = 0
    @State private var isDragging = false

    private var deviceSpeed: Int { bluetooth.latestReading?.fanSpeedPct ?? 0 }
    private var deviceStatus: DeviceStatus? { bluetooth.latestReading?.status }

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.spacing) {
                ionizeHealthCard
                currentSpeedCard
                modePicker
                if mode == .manual {
                    presetsCard
                    sliderCard
                } else {
                    autoModeNote
                }
                refreshButton
            }
            .padding(Theme.spacing)
        }
        .onAppear { syncSliderToDevice() }
        .onChange(of: deviceSpeed) { _, _ in syncSliderToDevice() }
        .onChange(of: mode) { _, newMode in applyMode(newMode) }
    }

    // MARK: - Ionizer health status

    private var ionizeHealthCard: some View {
        VStack(spacing: 8) {
            HStack {
                Text("IONIZER")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                ionizerStateLabel
            }
            Divider()
                .opacity(0.5)
            Text(ionizerStatusText)
                .font(.subheadline)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(ionizerStatusColor.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
    }

    @ViewBuilder
    private var ionizerStateLabel: some View {
        if let status = deviceStatus {
            switch status.ionizerState {
            case .off:
                Label("Off", systemImage: "power.off")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.textSecondary)
            case .healthy:
                Label("Healthy", systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.green)
            case .faulted:
                Label("Faulted", systemImage: "exclamationmark.circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
            }
        } else {
            Label("—", systemImage: "questionmark.circle")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.textSecondary)
        }
    }

    private var ionizerStatusText: String {
        guard let status = deviceStatus else {
            return "Awaiting reading…"
        }
        switch status.ionizerState {
        case .off:
            return "Ionizer is powered off"
        case .healthy:
            return "Ionizer is operating normally"
        case .faulted:
            return "Ionizer has a fault — check device"
        }
    }

    private var ionizerStatusColor: Color {
        guard let status = deviceStatus else {
            return Theme.textSecondary
        }
        switch status.ionizerState {
        case .off:
            return Theme.textSecondary
        case .healthy:
            return .green
        case .faulted:
            return .orange
        }
    }

    // MARK: - Fan speed (device is source of truth, §6.2)

    private var currentSpeedCard: some View {
        VStack(spacing: 4) {
            Text("FAN SPEED (DEVICE)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.textSecondary)
            Text("\(deviceSpeed)%")
                .font(.system(size: 64, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.accent)
                .contentTransition(.numericText())
            Text(bluetooth.latestReading == nil ? "Awaiting reading…" : "Reported by the monitor")
                .font(.caption2)
                .foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
        .background(Theme.accent.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
    }

    // MARK: - Mode (§6.2)

    private var modePicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("MODE").font(.caption.weight(.semibold)).foregroundStyle(Theme.textSecondary)
            Picker("Mode", selection: $mode) {
                ForEach(FanMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
        }
        .card()
    }

    // MARK: - Presets (§6.2 — 25/50/75/100%)

    private var presetsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("PRESETS").font(.caption.weight(.semibold)).foregroundStyle(Theme.textSecondary)
            HStack(spacing: 10) {
                ForEach(FanPreset.allCases) { preset in
                    Button {
                        bluetooth.setFanPreset(preset)
                        sliderValue = Double(preset.percent)
                    } label: {
                        VStack(spacing: 4) {
                            Text(preset.title).font(.subheadline.weight(.semibold))
                            Text("\(preset.percent)%").font(.caption2).foregroundStyle(Theme.textSecondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Theme.surfaceHi, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .foregroundStyle(Theme.textPrimary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(preset.title), \(preset.percent) percent")
                }
            }
        }
        .card()
    }

    // MARK: - Manual slider (§6.2 — 0x02, debounced on release)

    private var sliderCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("MANUAL").font(.caption.weight(.semibold)).foregroundStyle(Theme.textSecondary)
                Spacer()
                Text("\(Int(sliderValue))%")
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(Theme.accent)
            }
            Slider(value: $sliderValue, in: 0...100, step: 1) { editing in
                isDragging = editing
                if !editing {
                    bluetooth.setFanManual(percent: Int(sliderValue))
                }
            }
            .tint(Theme.accent)
            Text("Drag to set an exact speed; the value is sent when you release.")
                .font(.caption2)
                .foregroundStyle(Theme.textSecondary)
        }
        .card()
    }

    // MARK: - Auto modes

    private var autoModeNote: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(mode == .auto ? "AQI-driven auto" : "TVOC-setpoint auto",
                  systemImage: "wand.and.stars")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
            Text(mode == .auto
                 ? "The monitor adjusts the fan automatically based on the AQI reading."
                 : "The monitor adjusts the fan using the TVOC thresholds. Edit them in Settings.")
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
        }
        .card()
    }

    private var refreshButton: some View {
        Button {
            bluetooth.refreshNow()
        } label: {
            Label("Refresh now", systemImage: "arrow.clockwise")
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .foregroundStyle(Theme.accent)
        }
    }

    // MARK: - Helpers

    private func syncSliderToDevice() {
        guard !isDragging else { return }
        sliderValue = Double(deviceSpeed)
    }

    private func applyMode(_ newMode: FanMode) {
        switch newMode {
        case .auto:     bluetooth.setFanAuto()
        case .tvocAuto: bluetooth.setFanTVOCAuto()
        case .manual:   break
        }
    }
}
