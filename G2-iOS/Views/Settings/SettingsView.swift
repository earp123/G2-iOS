//
//  SettingsView.swift
//  G2-iOS
//
//  VOC-index threshold editor, LED brightness, device name, diagnostics,
//  maintenance commands, time-sync and connection management (§6).
//
//  Everything that writes settings goes through the full 12-byte payload (§1.3),
//  so editing one field never clobbers another. Thresholds are validated
//  strictly-increasing and in-range client-side; the editor is pre-populated from
//  a READ of the Settings characteristic.
//

import SwiftUI

struct SettingsView: View {
    @Environment(BluetoothManager.self) private var bluetooth

    // Threshold editor state (VOC index), pre-populated from the device READ.
    @State private var lo = Int(VOCThresholds.defaults.lo)
    @State private var med = Int(VOCThresholds.defaults.med)
    @State private var hi = Int(VOCThresholds.defaults.hi)
    @State private var maxVal = Int(VOCThresholds.defaults.max)
    @State private var didPopulateThresholds = false

    // LED brightness editor state (§6).
    @State private var brightness = Double(GATT.ledBrightnessDefault)
    @State private var isDraggingBrightness = false
    @State private var didPopulateBrightness = false

    // Device name editor state (§6).
    @State private var nameDraft = ""

    @State private var timeSyncNote: String?
    @State private var showCO2RecalConfirm = false

    private var edited: VOCThresholds {
        VOCThresholds(lo: UInt16(lo), med: UInt16(med), hi: UInt16(hi), max: UInt16(maxVal))
    }
    private var isMonotonic: Bool { edited.isMonotonic }
    private var isInRange: Bool { edited.isInRange }
    private var isValid: Bool { edited.isValid }
    private var isConnected: Bool { bluetooth.phase == .connected }

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.spacing) {
                deviceNameCard
                thresholdEditor
                fanMappingReference
                brightnessCard
                diagnostics
                maintenanceCard
                timeSyncStub
                disconnectButton
            }
            .padding(Theme.spacing)
        }
        .background(Theme.background)
        .onAppear {
            bluetooth.readSettings()
            bluetooth.readDeviceName()
            bluetooth.readDeviceInfo()
            populateFromSettings()
        }
        .onChange(of: bluetooth.settings) { _, _ in populateFromSettings() }
        .alert("Calibrate CO₂ outdoors?", isPresented: $showCO2RecalConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Calibrate") { bluetooth.sendCO2Recalibration() }
        } message: {
            Text("The monitor must have been outdoors in fresh air for at least 3 minutes. "
                 + "This sets the CO₂ reference to \(GATT.co2RecalibrationReferencePpm) ppm. "
                 + "Calibrating indoors will make every later reading wrong.")
        }
    }

    // MARK: - Device name (§6 / §1.4)

    private var deviceNameCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("DEVICE NAME")
            InfoRow(label: "Current", value: bluetooth.deviceName ?? "—")
            Divider().overlay(Theme.hairline)
            DeviceNameEditor(
                name: $nameDraft,
                placeholder: bluetooth.deviceName ?? "Monitor name",
                saveTitle: "Save name"
            )
        }
        .card()
    }

    // MARK: - VOC index threshold editor (§6 / §1.3)

    private var thresholdEditor: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader("VOC INDEX THRESHOLDS")

            thresholdStepper("Low",    value: $lo)
            thresholdStepper("Medium", value: $med)
            thresholdStepper("High",   value: $hi)
            thresholdStepper("Max",    value: $maxVal)

            if !isMonotonic {
                Label("Values must be strictly increasing: low < medium < high < max.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(Theme.aqiPoor)
            }
            if !isInRange {
                Label("The VOC index scale runs \(GATT.vocIndexMin)–\(GATT.vocIndexMax).",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(Theme.aqiPoor)
            }

            HStack {
                Button("Reset to defaults") {
                    let d = VOCThresholds.defaults
                    lo = Int(d.lo); med = Int(d.med); hi = Int(d.hi); maxVal = Int(d.max)
                }
                .font(.subheadline)
                .tint(Theme.textSecondary)

                Spacer()

                Button {
                    // Writes the full 12-byte payload, preserving brightness and
                    // the fan fields (§1.3).
                    bluetooth.writeThresholds(edited)
                } label: {
                    Text("Save").font(.headline)
                        .padding(.horizontal, 20).padding(.vertical, 8)
                        .background(isValid && isConnected ? Theme.accent : Theme.surfaceHi, in: Capsule())
                        .foregroundStyle(isValid && isConnected ? Theme.background : Theme.textSecondary)
                }
                .disabled(!isValid || !isConnected)   // disable Save until valid (§6)
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
            // Range and step per §6: 1–500, step 10.
            Stepper(label, value: value, in: VOCThresholds.validRange, step: 10)
                .labelsHidden()
        }
    }

    // MARK: - VOC index → fan mapping (read-only reference, §6)

    private var fanMappingReference: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("FAN MAPPING (CUSTOM)")
            ForEach(edited.fanMappingRows) { row in
                HStack {
                    Text("VOC index \(row.condition)").foregroundStyle(Theme.textSecondary)
                    Spacer()
                    Text(row.fanSpeed).foregroundStyle(Theme.textPrimary).monospacedDigit()
                }
                .font(.subheadline)
            }
        }
        .card()
    }

    // MARK: - LED brightness (§6)

    private var brightnessCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                sectionHeader("LED BRIGHTNESS")
                Spacer()
                Text("\(Int(brightness))%")
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(Theme.accent)
            }
            Slider(
                value: $brightness,
                in: Double(GATT.ledBrightnessMin)...Double(GATT.ledBrightnessMax),
                step: 1
            ) { editing in
                isDraggingBrightness = editing
                // Debounced like the fan slider: one 12-byte write on release (§6).
                if !editing { bluetooth.writeLEDBrightness(UInt8(brightness)) }
            }
            .tint(Theme.accent)
            .disabled(!isConnected)
            Text("Sets the indicator LED brightness, \(GATT.ledBrightnessMin)–\(GATT.ledBrightnessMax)%. "
                 + "Saved on the monitor and used at the next start.")
                .font(.caption2)
                .foregroundStyle(Theme.textSecondary)
        }
        .card()
    }

    // MARK: - Diagnostics (§6)

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
            HStack {
                Text("Negotiated MTU").foregroundStyle(Theme.textSecondary)
                Spacer()
                Text(bluetooth.mtu.map { "\($0) bytes" } ?? "Unavailable")
                    .monospacedDigit()
                    .foregroundStyle(bluetooth.mtuIsTooSmall ? Theme.aqiUnhealthy : Theme.textPrimary)
                if bluetooth.mtuIsTooSmall {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.aqiUnhealthy)
                }
            }
            if bluetooth.mtuIsTooSmall {
                // The 52-byte live packet needs ATT MTU >= 55 (notes §8).
                Text("Below the \(BluetoothManager.minimumUsableMTU) bytes a 52-byte sensor packet needs — "
                     + "notifications may arrive truncated.")
                    .font(.caption)
                    .foregroundStyle(Theme.aqiUnhealthy)
            }

            deviceInfoRows

            Divider().overlay(Theme.hairline)
            Text("DEVICE STATUS").font(.caption.weight(.semibold)).foregroundStyle(Theme.textSecondary)
            if let status = bluetooth.latestReading?.status {
                ForEach(status.indicators) { StatusIndicatorRow(indicator: $0) }
            } else {
                Text("Awaiting a sensor reading…")
                    .font(.subheadline).foregroundStyle(Theme.textSecondary)
            }

            Divider().overlay(Theme.hairline)
            sen66StatusRows
        }
        .font(.subheadline)
        .card()
    }

    @ViewBuilder
    private var deviceInfoRows: some View {
        Divider().overlay(Theme.hairline)
        if let info = bluetooth.deviceInfo {
            InfoRow(label: "SEN66 serial", value: info.serialText)
            Divider().overlay(Theme.hairline)
            InfoRow(label: "SEN66 firmware", value: info.firmwareVersionText)
            Divider().overlay(Theme.hairline)
            HStack {
                Text("Contract version").foregroundStyle(Theme.textSecondary)
                Spacer()
                Text("\(info.contractVersion)")
                    .monospacedDigit()
                    .foregroundStyle(info.isContractSupported ? Theme.textPrimary : Theme.aqiUnhealthy)
                if !info.isContractSupported {
                    Image(systemName: "xmark.octagon.fill").foregroundStyle(Theme.aqiUnhealthy)
                }
            }
            if !info.isContractSupported {
                // Reported, never worked around (§9.3).
                Text("This monitor reports contract v\(info.contractVersion); this app implements "
                     + "v\(GATT.contractVersion). Readings may be wrong or absent — report this rather "
                     + "than relying on the values shown.")
                    .font(.caption)
                    .foregroundStyle(Theme.aqiUnhealthy)
            }
            Divider().overlay(Theme.hairline)
            InfoRow(label: "Log record version", value: "\(info.logRecordVersion)")
        } else {
            InfoRow(label: "Device info", value: "Unavailable")
        }
    }

    @ViewBuilder
    private var sen66StatusRows: some View {
        Text("SEN66 STATUS FLAGS").font(.caption.weight(.semibold)).foregroundStyle(Theme.textSecondary)
        if let sen66 = bluetooth.latestReading?.sen66Status {
            HStack {
                Text("Register").foregroundStyle(Theme.textSecondary)
                Spacer()
                Text(sen66.hexDescription).monospacedDigit().foregroundStyle(Theme.textPrimary)
            }
            if sen66.isClean {
                Label("No faults reported", systemImage: "checkmark.circle.fill")
                    .font(.subheadline)
                    .foregroundStyle(Theme.aqiExcellent)
            } else {
                ForEach(sen66.activeIndicators) { indicator in
                    SEN66StatusRow(indicator: indicator, isWarningOnly: indicator.bit == 21)
                }
            }
        } else {
            Text("Awaiting a sensor reading…")
                .font(.subheadline).foregroundStyle(Theme.textSecondary)
        }
    }

    private var connectionText: String {
        switch bluetooth.phase {
        case .connected:    "Connected"
        case .discovering:  "Discovering…"
        case .connecting:   "Connecting…"
        case .disconnected: "Disconnected"
        }
    }

    // MARK: - Maintenance (§6 / §1.6)

    private var maintenanceCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("SENSOR MAINTENANCE")

            // Firmware ignores 0x0D while the sensor is warming, and cleaning
            // re-arms the warming bit afterwards (notes §4).
            maintenanceButton(
                title: "Clean sensor fan",
                icon: "fan.fill",
                note: bluetooth.sensorIsWarming
                    ? "Unavailable while the sensor is warming up."
                    : "Runs the SEN66 fan-cleaning cycle — about 12 s. PM readings pause and the "
                    + "sensor warms up again afterwards.",
                isEnabled: !bluetooth.sensorIsWarming
            ) { bluetooth.sendFanCleaning() }

            Divider().overlay(Theme.hairline)

            maintenanceButton(
                title: "Clear sensor errors",
                icon: "arrow.counterclockwise.circle",
                note: "Clears latched error flags in the SEN66 device status register."
            ) { bluetooth.sendClearSensorErrors() }

            Divider().overlay(Theme.hairline)

            maintenanceButton(
                title: "Calibrate CO₂ outdoors",
                icon: "carbon.dioxide.cloud.fill",
                note: "Sets the CO₂ reference to \(GATT.co2RecalibrationReferencePpm) ppm. "
                    + "Only valid after at least 3 minutes outdoors."
            ) { showCO2RecalConfirm = true }
        }
        .card()
    }

    private func maintenanceButton(
        title: String, icon: String, note: String,
        isEnabled: Bool = true, action: @escaping () -> Void
    ) -> some View {
        let enabled = isConnected && isEnabled
        return VStack(alignment: .leading, spacing: 6) {
            Button(action: action) {
                Label(title, systemImage: icon)
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 10).padding(.horizontal, 12)
                    .background(Theme.surfaceHi, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .foregroundStyle(enabled ? Theme.textPrimary : Theme.textSecondary)
            }
            .disabled(!enabled)
            Text(note)
                .font(.caption2)
                .foregroundStyle(Theme.textSecondary)
        }
    }

    // MARK: - Time-sync (opcode 0x0B SET_TIME, §6 / §1.6)

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
            .disabled(!isConnected)

            if let note = timeSyncNote {
                Label(note, systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(Theme.aqiExcellent)
            }
        }
        .card()
    }

    // MARK: - Connection management (§6)

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

    /// Populates the editors from the device's current settings, once each. The
    /// brightness slider is not overwritten mid-drag.
    private func populateFromSettings() {
        guard let settings = bluetooth.settings else { return }
        if !didPopulateThresholds {
            let t = settings.thresholds
            lo = Int(t.lo); med = Int(t.med); hi = Int(t.hi); maxVal = Int(t.max)
            didPopulateThresholds = true
        }
        if !didPopulateBrightness, !isDraggingBrightness {
            brightness = Double(settings.ledBrightnessPct)
            didPopulateBrightness = true
        }
    }
}
