//
//  DeviceNameEditor.swift
//  G2-iOS
//
//  Editing UI for the Device Name characteristic (§1.4 / §6), shared by the
//  Settings tab and the one-time naming sheet.
//
//  The device's limit is **20 UTF-8 bytes, not 20 characters** — an emoji costs
//  four and an accented letter two — so the editor counts bytes, truncates on
//  bytes, and shows the byte budget. A write the firmware would reject with
//  BLE_ATT_ERR_INVALID_ATTR_VALUE_LEN is never sent.
//

import SwiftUI

/// The wire rules for a device name, applied in the editor so an invalid name
/// can't be typed rather than being rejected after the round trip (§1.4).
enum DeviceNameRules {

    /// UTF-8 byte count — the unit the firmware's length check uses.
    static func byteCount(_ name: String) -> Int { name.utf8.count }

    /// True when `name` is something the device will accept: non-empty after
    /// trimming, no NUL, and within the byte budget.
    static func isValid(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty
            && !trimmed.contains("\0")
            && byteCount(trimmed) <= GATT.deviceNameMaxBytes
    }

    /// Truncates on a **character** boundary such that the UTF-8 encoding fits
    /// the budget — never splits a multi-byte scalar or a grapheme cluster.
    static func truncated(_ name: String, limit: Int = GATT.deviceNameMaxBytes) -> String {
        guard byteCount(name) > limit else { return name }
        var result = ""
        var used = 0
        for character in name {
            let width = String(character).utf8.count
            if used + width > limit { break }
            result.append(character)
            used += width
        }
        return result
    }
}

/// Text field + byte budget + Save, bound to the Device Name characteristic.
struct DeviceNameEditor: View {
    @Environment(BluetoothManager.self) private var bluetooth

    @Binding var name: String
    /// Shown greyed in the field when `name` is empty — the unit's current name.
    var placeholder: String
    var saveTitle: String = "Save name"
    /// Called after a successful write, so a host sheet can dismiss itself.
    var onSaved: () -> Void = {}

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var byteCount: Int { DeviceNameRules.byteCount(trimmed) }
    private var isValid: Bool { DeviceNameRules.isValid(name) }
    private var isConnected: Bool { bluetooth.phase == .connected }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField(placeholder, text: $name)
                .textFieldStyle(.plain)
                .font(.body)
                .foregroundStyle(Theme.textPrimary)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .onSubmit(save)
                .padding(12)
                .background(Theme.surfaceHi, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                // Enforce the budget as the user types, on byte count (§1.4).
                .onChange(of: name) { _, newValue in
                    let clamped = DeviceNameRules.truncated(newValue)
                    if clamped != newValue { name = clamped }
                }

            HStack {
                Text("\(byteCount)/\(GATT.deviceNameMaxBytes) bytes")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(byteCount >= GATT.deviceNameMaxBytes ? Theme.aqiModerate : Theme.textSecondary)
                Spacer()
                Button(saveTitle, action: save)
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 16).padding(.vertical, 7)
                    .background(isValid && isConnected ? Theme.accent : Theme.surfaceHi, in: Capsule())
                    .foregroundStyle(isValid && isConnected ? Theme.background : Theme.textSecondary)
                    .disabled(!isValid || !isConnected)
            }

            Text("Up to \(GATT.deviceNameMaxBytes) bytes of text — accented characters and emoji use more than one byte each. "
                 + "The new name appears in the scan list after the monitor next advertises.")
                .font(.caption2)
                .foregroundStyle(Theme.textSecondary)
        }
    }

    private func save() {
        guard isValid, isConnected else { return }
        if bluetooth.writeDeviceName(trimmed) { onSaved() }
    }
}

/// One-time naming prompt shown on connect for a unit still carrying its factory
/// default name (§6). Skippable, and never shown twice for the same peripheral.
struct DeviceNamingSheet: View {
    @Environment(BluetoothManager.self) private var bluetooth
    @Environment(\.dismiss) private var dismiss

    /// Starts empty rather than pre-filled: the factory default name can itself
    /// exceed the 20-byte write budget, so it is shown as context, not as a
    /// starting value to edit.
    @State private var name = ""

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.spacing) {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Name this monitor", systemImage: "tag.fill")
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(Theme.textPrimary)
                            Text("This monitor is still using its default name"
                                 + (bluetooth.deviceName.map { " (“\($0)”)" } ?? "")
                                 + ". Give it a name so you can tell it apart in the scan list.")
                                .font(.subheadline)
                                .foregroundStyle(Theme.textSecondary)
                        }

                        DeviceNameEditor(
                            name: $name,
                            placeholder: "e.g. Bay 3 Truck",
                            saveTitle: "Save name",
                            onSaved: { dismiss() }
                        )
                        .card()
                    }
                    .padding(Theme.spacing)
                }
            }
            .navigationTitle("Name monitor")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Skip") { dismiss() }
                        .tint(Theme.textSecondary)
                }
            }
        }
    }
}

/// Tracks which peripherals have already been offered the naming prompt, so it
/// is genuinely one-time per unit (§6).
enum DeviceNamingPrompt {
    private static let key = "deviceNamingPromptSeen"

    static func hasPrompted(_ id: UUID) -> Bool {
        seen().contains(id.uuidString)
    }

    static func markPrompted(_ id: UUID) {
        var ids = seen()
        ids.insert(id.uuidString)
        UserDefaults.standard.set(Array(ids), forKey: key)
    }

    private static func seen() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
    }
}
