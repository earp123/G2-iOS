//
//  ConditioningView.swift
//  G2-iOS
//
//  Unified conditioning control (§5): fan speed and mode plus ionizer
//  power/health monitoring.
//
//  v2 note: the mode picker **mirrors the device** (live byte 34) instead of
//  holding app-local state. Device-driven updates must not echo back as
//  commands, so a write only happens when the selection differs from the last
//  mode the device reported.
//
//  "TVOC Auto" is now **Custom** — same opcode (0x0A), but its thresholds are a
//  VOC index rather than ppb (§1.3).
//

import SwiftUI

struct ConditioningView: View {
    @Environment(BluetoothManager.self) private var bluetooth

    @State private var mode: FanMode = .auto
    /// The last mode the device reported. Guards `onChange(of: mode)` so
    /// mirroring the device never re-sends a command back to it (§5).
    @State private var lastDeviceMode: FanMode?
    @State private var sliderValue: Double = 0
    @State private var isDragging = false

    private var deviceSpeed: Int { bluetooth.latestReading?.fanSpeedPct ?? 0 }
    private var deviceMode: FanMode? { bluetooth.latestReading?.fanMode }
    private var deviceStatus: DeviceStatus? { bluetooth.latestReading?.status }

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.spacing) {
                if bluetooth.showsManualOffWarning {
                    manualOffWarning
                }
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
        .onAppear {
            syncSliderToDevice()
            adoptDeviceMode(deviceMode)
        }
        .onChange(of: deviceSpeed) { _, _ in syncSliderToDevice() }
        .onChange(of: deviceMode) { _, newDeviceMode in adoptDeviceMode(newDeviceMode) }
        .onChange(of: mode) { _, newMode in
            // Only a user-driven change writes; a change we just adopted from the
            // device matches `lastDeviceMode` and is ignored (§5).
            guard newMode != lastDeviceMode else { return }
            applyMode(newMode)
        }
    }

    // MARK: - Manual 0 % warning (§5)
    //
    // Firmware restores Manual 0 % exactly as saved, by design — the fan stays
    // off across the next ignition cycle and the PM floor is bypassed. This is
    // the app-side half of that decision: say so, persistently.

    private var manualOffWarning: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Fan is off and will stay off", systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.aqiModerate)
            Text("Fan is set to Manual / Off and will stay off at the next start. "
                 + "Switch to Auto or Custom to restore automatic control.")
                .font(.footnote)
                .foregroundStyle(Theme.textPrimary)
            HStack(spacing: 10) {
                Button("Switch to Auto") { mode = .auto }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                Button("Switch to Custom") { mode = .custom }
                    .buttonStyle(.bordered)
                    .tint(Theme.accent)
            }
            .font(.subheadline.weight(.semibold))
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.spacing)
        .background(Theme.aqiModerate.opacity(0.14),
                    in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
                .strokeBorder(Theme.aqiModerate.opacity(0.45), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
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

    // MARK: - Fan speed (device is source of truth, §5)

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

    // MARK: - Mode — mirrors live byte 34 (§5)

    private var modePicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("MODE").font(.caption.weight(.semibold)).foregroundStyle(Theme.textSecondary)
                Spacer()
                if deviceMode == nil {
                    Text("Awaiting device…")
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            Picker("Mode", selection: $mode) {
                ForEach(FanMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
        }
        .card()
    }

    // MARK: - Presets (§5 — 25/50/75/100%)

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

    // MARK: - Manual slider (§5 — 0x02, debounced on release)

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
            Label(mode.note, systemImage: "wand.and.stars")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
            Text(mode == .auto
                 ? "The monitor adjusts the fan automatically from its air-quality class."
                 : "The monitor adjusts the fan using the VOC index thresholds. Edit them in Settings.")
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

    /// Mirrors the device's reported mode into the picker. `lastDeviceMode` is
    /// updated **before** the selection so `onChange(of: mode)` recognises the
    /// change as device-driven and stays silent (§5).
    private func adoptDeviceMode(_ newDeviceMode: FanMode?) {
        guard let newDeviceMode else { return }
        lastDeviceMode = newDeviceMode
        if mode != newDeviceMode { mode = newDeviceMode }
    }

    private func applyMode(_ newMode: FanMode) {
        switch newMode {
        case .auto:   bluetooth.setFanAuto()
        case .custom: bluetooth.setFanCustom()
        case .manual:
            // Manual has no mode opcode — the device enters it by being given a
            // speed. Send the one already on screen so nothing jumps (§5).
            bluetooth.setFanManual(percent: Int(sliderValue))
        }
    }
}
