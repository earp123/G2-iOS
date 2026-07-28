//
//  ConditioningView.swift
//  G2-iOS
//
//  Combined air conditioning controls and monitoring: fan speed and ionizer
//  health. Displays live fan speed and ionizer power state for read-only
//  monitoring; fan speed is controlled via modes and presets (§6.2, read-only
//  ionizer per §6.3).
//

import SwiftUI

struct ConditioningView: View {
    @Environment(BluetoothManager.self) private var bluetooth

    @State private var mode: FanMode = .manual
    @State private var sliderValue: Double = 0
    @State private var isDragging = false

    private var deviceSpeed: Int { bluetooth.latestReading?.fanSpeedPct ?? 0 }
    private var ionizeStatus: DeviceStatus? { bluetooth.latestReading?.status }

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.spacing) {
                currentSpeedCard
                ionizeHealthCard
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

    // MARK: - Current fan speed (device is source of truth)

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

    // MARK: - Ionizer health status

    private var ionizeHealthCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("IONIZER").font(.caption.weight(.semibold)).foregroundStyle(Theme.textSecondary)

            if let status = ionizeStatus {
                HStack(spacing: 12) {
                    Image(systemName: status.ionizeIsHealthy ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(status.ionizeIsHealthy ? Color.green : Color.orange)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(status.ionizeIsHealthy ? "Healthy" : "Check Status")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.textPrimary)
                        Text(status.ionizeIsHealthy ? "Operating normally" : "Ionizer may need attention")
                            .font(.caption2)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    Spacer()
                }
                .padding(.vertical, 12)
                .padding(.horizontal, 12)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else {
                Text("Awaiting status…")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 12)
                    .padding(.horizontal, 12)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
        .card()
    }

    // MARK: - Mode picker

    private var modePicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("FAN MODE").font(.caption.weight(.semibold)).foregroundStyle(Theme.textSecondary)
            Picker("Mode", selection: $mode) {
                ForEach(FanMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
        }
        .card()
    }

    // MARK: - Presets

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

    // MARK: - Manual slider

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
