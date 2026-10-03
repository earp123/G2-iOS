//
//  ThresholdsEditor.swift
//  G2-iOS
//
//  The Settings → Air quality thresholds section (thresholds-v3 §3): every
//  edge, fan response, timer and hysteresis in the 60-byte Thresholds
//  characteristic, edited as one form and written whole on Save.
//
//  The form is loaded from the device on connect and reloaded after every Save
//  and Restore defaults, from the re-read that follows them — so it always
//  starts from what the device actually stores, and an app killed mid-edit
//  comes back to the device's values, never stale local ones. Nothing is
//  persisted locally.
//
//  Validation runs on every edit through `ThresholdsBlob.validate()` — the
//  firmware's own rules — and drives both the inline errors and the Save
//  button, so a write the firmware would reject is never attempted.
//

import SwiftUI

/// Text-field state for the editor: one string per `ThresholdsBlob.Field`, so a
/// half-typed value can sit in one cell while the rest of the form keeps
/// validating. The parsing rules live here, apart from the view, so they are
/// testable (like `DeviceNameRules`).
///
/// Integer fields accept digits only. PM fields (µg/m³) accept one decimal —
/// either separator — and round to it; their wire value is the number × 10.
struct ThresholdsForm: Equatable {
    typealias Field = ThresholdsBlob.Field

    private var texts: [Field: String] = [:]

    init() {}

    init(_ blob: ThresholdsBlob) { load(blob) }

    /// Replaces every field with the device's value.
    mutating func load(_ blob: ThresholdsBlob) {
        texts = [:]
        for field in Field.allCases { texts[field] = Self.text(forWire: blob[field], field: field) }
    }

    /// Raw text of one cell; the editor binds to this and sanitises on change.
    subscript(field: Field) -> String {
        get { texts[field] ?? "" }
        set { texts[field] = newValue }
    }

    // MARK: - Text ⇄ wire

    /// The device value as the cell shows it — PM with exactly one decimal.
    static func text(forWire value: UInt16, field: Field) -> String {
        field.isTenths ? ThresholdsBlob.tenthsText(value) : String(value)
    }

    /// What a cell may hold. Integer cells keep digits only — a typed decimal
    /// point is dropped — up to the digits the wire field can carry. PM cells
    /// keep digits and one separator (`,` becomes `.`); a second decimal digit
    /// rounds the value to one decimal, half up ("7.25" → "7.3").
    static func sanitized(_ text: String, for field: Field) -> String {
        let isDigit: (Character) -> Bool = { ("0"..."9").contains($0) }
        guard field.isTenths else {
            let maxDigits = field.wireMax > UInt16(UInt8.max) ? 5 : 3
            return String(text.filter(isDigit).prefix(maxDigits))
        }
        var whole = ""
        var fraction = ""
        var hasSeparator = false
        for character in text {
            if isDigit(character) {
                if hasSeparator { fraction.append(character) } else { whole.append(character) }
            } else if character == "." || character == ",", !hasSeparator {
                hasSeparator = true
            }
        }
        whole = String(whole.prefix(4))   // 6553.5 is the largest ×10 u16
        guard fraction.count > 1 else {
            return hasSeparator ? whole + "." + fraction : whole
        }
        let digits = Array(fraction)
        var tenths = (Int(whole) ?? 0) * 10 + (digits[0].wholeNumberValue ?? 0)
        if (digits[1].wholeNumberValue ?? 0) >= 5 { tenths += 1 }
        return "\(tenths / 10).\(tenths % 10)"
    }

    /// The wire value a cell's text stands for, before range checks; `nil` when
    /// the cell holds no number.
    static func wideWireValue(_ text: String, for field: Field) -> Int? {
        let clean = sanitized(text, for: field)
        guard field.isTenths else { return clean.isEmpty ? nil : Int(clean) }
        let parts = clean.split(separator: ".", omittingEmptySubsequences: false)
        let whole = parts.first.map(String.init) ?? ""
        let fraction = parts.count > 1 ? String(parts[1]) : ""
        guard !(whole.isEmpty && fraction.isEmpty) else { return nil }
        return (Int(whole) ?? 0) * 10 + (fraction.first?.wholeNumberValue ?? 0)
    }

    // MARK: - Per-cell problems (before any firmware rule)

    enum FieldProblem: Equatable {
        case empty
        case tooLarge
    }

    func problem(_ field: Field) -> FieldProblem? {
        guard let wide = Self.wideWireValue(self[field], for: field) else { return .empty }
        return wide > Int(field.wireMax) ? .tooLarge : nil
    }

    func value(_ field: Field) -> UInt16? {
        guard problem(field) == nil, let wide = Self.wideWireValue(self[field], for: field) else { return nil }
        return UInt16(wide)
    }

    // MARK: - The blob being edited

    /// The blob this form describes, on top of what the device reported (so the
    /// device's own version byte goes back unchanged). `nil` while any cell is
    /// empty or out of range.
    func draft(over device: ThresholdsBlob) -> ThresholdsBlob? {
        var blob = device
        for field in Field.allCases {
            guard let parsed = value(field) else { return nil }
            blob[field] = parsed
        }
        return blob
    }

    /// True when the form no longer matches the device.
    func isEdited(against device: ThresholdsBlob) -> Bool {
        draft(over: device) != device
    }

    /// Save needs every cell filled, every firmware rule passing, and something
    /// actually changed (thresholds-v3 §3 item 6).
    func canSave(against device: ThresholdsBlob) -> Bool {
        guard let draft = draft(over: device) else { return false }
        return draft.validate() == nil && draft != device
    }

    /// Inline messages for one row: its cells' input problems, then — once the
    /// whole form parses — the firmware rules that row breaks.
    func messages(for row: ThresholdsBlob.ValidationError.Row, against device: ThresholdsBlob) -> [String] {
        var messages: [String] = []
        for field in Field.allCases where field.row == row {
            switch problem(field) {
            case .empty:    messages.append("\(Self.label(field)): enter a value.")
            case .tooLarge: messages.append("\(Self.label(field)): too large.")
            case nil:       break
            }
        }
        if let draft = draft(over: device) {
            messages += draft.validationErrors().filter { $0.row == row }.map(\.message)
        }
        return messages
    }

    /// Short cell name used in an inline message under its row.
    static func label(_ field: Field) -> String {
        switch field {
        case .gasEdge(_, let i):        "C\(i + 1)"
        case .pmAttention:              "Attention"
        case .pmHazard:                 "Hazard"
        case .fanGas(let i):            "Gas class \(i + 1)"
        case .fanPM(let i):             "PM class \(i + 1)"
        case .fanDownDelay:             "Fan-down delay"
        case .ionizerRunOn:             "Ionizer run-on"
        case .hysteresis(let channel):  channel.title
        case .hysteresisPM:             "PM"
        }
    }

    /// Full cell name for VoiceOver.
    static func accessibilityName(_ field: Field) -> String {
        switch field {
        case .gasEdge(let channel, let i):  "\(channel.title) edge C\(i + 1)"
        case .pmAttention(let channel):     "\(channel.title) attention"
        case .pmHazard(let channel):        "\(channel.title) hazard"
        case .fanGas(let i):                "Fan percent for gas class \(i + 1)"
        case .fanPM(let i):                 "Fan percent for PM class \(i + 1)"
        case .fanDownDelay:                 "Fan-down delay, seconds"
        case .ionizerRunOn:                 "Ionizer run-on, minutes"
        case .hysteresis(let channel):      "\(channel.title) hysteresis"
        case .hysteresisPM:                 "PM hysteresis"
        }
    }
}

/// Settings → Air quality thresholds (thresholds-v3 §3).
struct ThresholdsEditor: View {
    @Environment(BluetoothManager.self) private var bluetooth

    @State private var form = ThresholdsForm()
    /// The device read the form was last loaded from — so returning to the tab
    /// keeps unsaved edits, while every new read (connect, Save, Restore
    /// defaults) replaces them with what the device holds.
    @State private var loadedRevision: Int?
    @State private var showRestoreConfirm = false
    @FocusState private var focusedField: ThresholdsBlob.Field?

    private typealias Field = ThresholdsBlob.Field
    private typealias Row = ThresholdsBlob.ValidationError.Row

    private var isConnected: Bool { bluetooth.phase == .connected }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spacing) {
            sectionTitle
            if let device = bluetooth.thresholds {
                gasCard(device)
                particulateCard(device)
                fanResponseCard(device)
                timingCard(device)
                hysteresisCard(device)
                actionsCard(device)
            } else {
                unavailableCard
            }
        }
        .onAppear {
            if bluetooth.thresholds == nil { bluetooth.readThresholds() }
            loadFromDevice()
        }
        .onChange(of: bluetooth.thresholdsRevision) { _, _ in loadFromDevice() }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { focusedField = nil }
            }
        }
        .confirmationDialog("Restore default thresholds?", isPresented: $showRestoreConfirm,
                            titleVisibility: .visible) {
            Button("Restore defaults", role: .destructive) {
                focusedField = nil
                bluetooth.restoreThresholdDefaults()   // 0x10, then re-read (§3)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every edge, fan response, timer and hysteresis on the monitor goes back to its "
                 + "factory value. Brightness, fan mode and the name are not affected.")
        }
    }

    // MARK: - Sections

    private var sectionTitle: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("AIR QUALITY THRESHOLDS")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.textSecondary)
            Text("Stored on the monitor and applied within a couple of seconds of saving.")
                .font(.caption2)
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(.horizontal, 4)
    }

    private func gasCard(_ device: ThresholdsBlob) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            cardHeader("GAS CLASSES",
                       note: "Class 1 at or below C1, up to class 5 above C4. Worst of the three wins.")
            columnHeaders(["C1", "C2", "C3", "C4"])
            ForEach(ThresholdsBlob.GasChannel.allCases, id: \.self) { channel in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        rowLabel(channel.title, unit: channel.unit)
                        ForEach(0..<ThresholdsBlob.gasEdgeCount, id: \.self) { i in
                            numberField(.gasEdge(channel, i), device: device)
                        }
                    }
                    inlineErrors(.gasEdges(channel), device: device)
                }
            }
        }
        .card()
    }

    private func particulateCard(_ device: ThresholdsBlob) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            cardHeader("PARTICULATE",
                       note: "µg/m³, one decimal. Good at or below Attention, hazard above Hazard.")
            columnHeaders(["Attention", "Hazard"])
            ForEach(ThresholdsBlob.PMChannel.allCases, id: \.self) { channel in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        rowLabel(channel.title, unit: "µg/m³")
                        numberField(.pmAttention(channel), device: device)
                        numberField(.pmHazard(channel), device: device)
                    }
                    inlineErrors(.pmEdges(channel), device: device)
                }
            }
        }
        .card()
    }

    private func fanResponseCard(_ device: ThresholdsBlob) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            cardHeader("FAN RESPONSE (%)",
                       note: "In Auto the fan runs at the higher of the gas-class % and the PM-class %.")
            columnHeaders(["1", "2", "3", "4", "5"])
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    rowLabel("Gas", unit: "class")
                    ForEach(0..<ThresholdsBlob.gasClassCount, id: \.self) { i in
                        numberField(.fanGas(i), device: device)
                    }
                }
                inlineErrors(.fanGas, device: device)
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    rowLabel("PM", unit: "class")
                    ForEach(0..<ThresholdsBlob.pmClassCount, id: \.self) { i in
                        numberField(.fanPM(i), device: device)
                    }
                    // Keep the PM cells under gas classes 1–3.
                    ForEach(ThresholdsBlob.pmClassCount..<ThresholdsBlob.gasClassCount, id: \.self) { _ in
                        Color.clear.frame(maxWidth: .infinity, maxHeight: 1)
                    }
                }
                inlineErrors(.fanPM, device: device)
            }
        }
        .card()
    }

    private func timingCard(_ device: ThresholdsBlob) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            cardHeader("TIMING", note: nil)
            singleValueRow(.fanDownDelay, title: "Fan-down delay", unit: "s",
                           help: "The fan holds its speed this long after the air improves. 0 = immediate.",
                           device: device)
            Divider().overlay(Theme.hairline)
            singleValueRow(.ionizerRunOn, title: "Ionizer run-on", unit: "min",
                           help: "Stays on this long after demand clears. 0 = none.",
                           device: device)
        }
        .card()
    }

    private func hysteresisCard(_ device: ThresholdsBlob) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            cardHeader("HYSTERESIS",
                       note: "The class only steps down once the value falls this far below the edge. 0 = none.")
            ForEach(ThresholdsBlob.GasChannel.allCases, id: \.self) { channel in
                singleValueRow(.hysteresis(channel), title: channel.title, unit: channel.unit,
                               help: nil, device: device)
            }
            singleValueRow(.hysteresisPM, title: "PM", unit: "µg/m³", help: nil, device: device)
        }
        .card()
    }

    private func actionsCard(_ device: ThresholdsBlob) -> some View {
        let canSave = isConnected && !bluetooth.isWritingThresholds && form.canSave(against: device)
        return VStack(alignment: .leading, spacing: 10) {
            // A device blob in a format this build does not write (§2.2 byte 0).
            inlineErrors(.version, device: device)

            HStack {
                Button("Restore defaults") { showRestoreConfirm = true }
                    .font(.subheadline)
                    .tint(Theme.textSecondary)
                    .disabled(!isConnected || bluetooth.isWritingThresholds)

                Spacer()

                Button(action: { save(over: device) }) {
                    HStack(spacing: 6) {
                        if bluetooth.isWritingThresholds { ProgressView().controlSize(.small) }
                        Text("Save").font(.headline)
                    }
                    .padding(.horizontal, 20).padding(.vertical, 8)
                    .background(canSave ? Theme.accent : Theme.surfaceHi, in: Capsule())
                    .foregroundStyle(canSave ? Theme.background : Theme.textSecondary)
                }
                .disabled(!canSave)   // only when validate() passes and something changed (§3)
            }

            Text(statusText(device))
                .font(.caption2)
                .foregroundStyle(Theme.textSecondary)
        }
        .card()
    }

    private var unavailableCard: some View {
        HStack(spacing: 10) {
            if bluetooth.unsupportedContract == nil && isConnected {
                ProgressView().tint(Theme.accent)
            }
            Text(unavailableText)
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
        }
        .card()
    }

    private var unavailableText: String {
        if bluetooth.unsupportedContract != nil {
            return "This monitor's firmware does not support adjustable thresholds — update it first."
        }
        return isConnected ? "Reading thresholds from the monitor…" : "Connect to a monitor to edit its thresholds."
    }

    private func statusText(_ device: ThresholdsBlob) -> String {
        if bluetooth.isWritingThresholds { return "Writing to the monitor…" }
        if form.isEdited(against: device) { return "Unsaved changes — the monitor still uses its stored values." }
        return "Showing the values stored on the monitor."
    }

    // MARK: - Building blocks

    private func cardHeader(_ title: String, note: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(Theme.textSecondary)
            if let note {
                Text(note).font(.caption2).foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private static let rowLabelWidth: CGFloat = 54

    private func rowLabel(_ title: String, unit: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.textPrimary)
            Text(unit).font(.caption2).foregroundStyle(Theme.textSecondary)
        }
        .frame(width: Self.rowLabelWidth, alignment: .leading)
    }

    private func columnHeaders(_ titles: [String]) -> some View {
        HStack(spacing: 6) {
            Color.clear.frame(width: Self.rowLabelWidth, height: 1)
            ForEach(titles, id: \.self) { title in
                Text(title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    /// One labelled value with its unit and optional one-line help.
    private func singleValueRow(_ field: Field, title: String, unit: String, help: String?,
                                device: ThresholdsBlob) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(title).font(.subheadline).foregroundStyle(Theme.textPrimary)
                Spacer()
                numberField(field, device: device)
                    .frame(width: 92)
                Text(unit)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 40, alignment: .leading)
            }
            if let help {
                Text(help).font(.caption2).foregroundStyle(Theme.textSecondary)
            }
            inlineErrors(field.row, device: device)
        }
    }

    /// A numeric cell. Integer cells get the number pad; PM cells the decimal
    /// pad. Input is sanitised on change, the same way the device-name editor
    /// enforces its byte budget.
    private func numberField(_ field: Field, device: ThresholdsBlob) -> some View {
        let text = Binding(get: { form[field] }, set: { form[field] = $0 })
        let flagged = form.problem(field) != nil
            || form.messages(for: field.row, against: device).isEmpty == false
        return TextField("", text: text)
            .keyboardType(field.isTenths ? .decimalPad : .numberPad)
            .focused($focusedField, equals: field)
            .multilineTextAlignment(.center)
            .font(.subheadline.monospacedDigit())
            .foregroundStyle(Theme.textPrimary)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .padding(.vertical, 8)
            .padding(.horizontal, 2)
            .frame(maxWidth: .infinity)
            .background(Theme.surfaceHi, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(flagged ? Theme.aqiPoor.opacity(0.7) : Color.clear, lineWidth: 1)
            )
            .disabled(!isConnected || bluetooth.isWritingThresholds)
            .onChange(of: form[field]) { _, newValue in
                let clean = ThresholdsForm.sanitized(newValue, for: field)
                if clean != newValue { form[field] = clean }
            }
            .accessibilityLabel(ThresholdsForm.accessibilityName(field))
    }

    @ViewBuilder
    private func inlineErrors(_ row: Row, device: ThresholdsBlob) -> some View {
        ForEach(form.messages(for: row, against: device), id: \.self) { message in
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(Theme.aqiPoor)
        }
    }

    // MARK: - Actions

    private func loadFromDevice() {
        guard let device = bluetooth.thresholds, loadedRevision != bluetooth.thresholdsRevision else { return }
        form.load(device)
        loadedRevision = bluetooth.thresholdsRevision
    }

    private func save(over device: ThresholdsBlob) {
        guard let draft = form.draft(over: device), draft.validate() == nil else { return }
        focusedField = nil
        // Validated again inside; on success the characteristic is re-read and
        // the form reloads from what the device stored (§3).
        bluetooth.writeThresholds(draft)
    }
}
