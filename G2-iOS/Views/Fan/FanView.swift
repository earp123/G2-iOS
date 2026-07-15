//
//  FanView.swift
//  G2-iOS
//
//  Full fan-control surface (§6.2). Every opcode is wired: Auto (0x03), TVOC Auto
//  (0x0A), Off/Low/Med/High/Max (0x04–0x08), manual slider (0x02, debounced),
//  and Refresh (0x09). The device's reported speed (byte 23) is the source of truth
//  and is reflected back into the slider whenever the user isn't dragging.
//

import SwiftUI

struct FanView: View {
    @Environment(BluetoothManager.self) private var bluetooth

    @State private var mode: FanMode = .manual
    @State private var sliderValue: Double = 0
    @State private var isDragging = false

    private var deviceSpeed: Int { bluetooth.latestReading?.fanSpeedPct ?? 0 }

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.spacing) {
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

    // MARK: - Current speed (device is source of truth, §6.2)

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
                    // Send only on release to avoid flooding the link (§6.2).
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
            bluetooth.refreshNow()   // 0x09 GET_STATUS (§6.2)
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
        case .manual:   break   // user drives via presets/slider
        }
    }
}
