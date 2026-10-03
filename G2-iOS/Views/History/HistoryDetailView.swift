//
//  HistoryDetailView.swift
//  G2-iOS
//
//  Full breakdown of a single history record (§3): all log-record fields,
//  decoded status bits, and the gas and PM classes (thresholds-v3 §1.1). A
//  record logged before contract v3 has no PM class — its PM tile is grey.
//  Sentinel fields render as "—".
//

import SwiftUI

struct HistoryDetailView: View {
    let record: HistoryRecord

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.spacing) {
                classHeader

                VStack(alignment: .leading, spacing: 12) {
                    InfoRow(label: "Timestamp", value: record.timestamp.formatted(date: .abbreviated, time: .standard))
                    Divider().overlay(Theme.hairline)
                    InfoRow(label: "Temperature", value: record.temperatureC.map { String(format: "%.2f °C", $0) } ?? "—")
                    Divider().overlay(Theme.hairline)
                    InfoRow(label: "Humidity", value: record.humidityPct.map { String(format: "%.2f %%", $0) } ?? "—")
                    Divider().overlay(Theme.hairline)
                    InfoRow(label: "VOC index", value: record.vocIndex.map { String(format: "%.1f", $0) } ?? "—")
                    Divider().overlay(Theme.hairline)
                    InfoRow(label: "NOx index", value: record.noxIndex.map { String(format: "%.1f", $0) } ?? "—")
                    Divider().overlay(Theme.hairline)
                    InfoRow(label: "CO₂", value: record.co2Ppm.map { String(format: "%.0f ppm", $0) } ?? "—")
                    Divider().overlay(Theme.hairline)
                    InfoRow(label: "PM1.0", value: record.pm1.map { String(format: "%.1f µg/m³", $0) } ?? "—")
                    Divider().overlay(Theme.hairline)
                    InfoRow(label: "PM2.5", value: record.pm25.map { String(format: "%.1f µg/m³", $0) } ?? "—")
                    Divider().overlay(Theme.hairline)
                    InfoRow(label: "PM4.0", value: record.pm4.map { String(format: "%.1f µg/m³", $0) } ?? "—")
                    Divider().overlay(Theme.hairline)
                    InfoRow(label: "PM10", value: record.pm10.map { String(format: "%.1f µg/m³", $0) } ?? "—")
                    Divider().overlay(Theme.hairline)
                    InfoRow(label: "Sequence", value: "#\(record.sequence)")
                }
                .font(.subheadline)
                .card()

                statusCard
            }
            .padding(Theme.spacing)
        }
        .background(Theme.background)
        .navigationTitle("Record")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var classHeader: some View {
        let gas = record.aqiLevel
        let pm = record.pmLevel
        return HStack(spacing: Theme.spacing) {
            AirClassTile(
                title: "GAS",
                sources: "VOC · NOx · CO₂",
                value: gas.isValid ? "\(gas.rawValue)" : "—",
                label: record.aqClassLabel,
                color: gas.color
            )
            AirClassTile(
                title: "PARTICULATE",
                sources: "PM1 · PM2.5 · PM10",
                value: pm.isValid ? "\(pm.rawValue)" : "—",
                label: record.pmClassLabel,
                color: pm.color
            )
        }
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("DEVICE STATUS")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.textSecondary)
            ForEach(record.deviceStatus.indicators) { indicator in
                StatusIndicatorRow(indicator: indicator)
            }
        }
        .card()
    }
}

/// One decoded status-bit indicator row, reused in Settings diagnostics (§6.4).
struct StatusIndicatorRow: View {
    let indicator: StatusIndicator

    /// A set fault bit is a problem, not a satisfied check — the two read
    /// differently so "SEN66 sticky error: on" can't be mistaken for healthy.
    private var iconName: String {
        if indicator.isFault { return indicator.isOn ? "exclamationmark.triangle.fill" : "checkmark.circle" }
        return indicator.isOn ? "checkmark.circle.fill" : "xmark.circle"
    }

    private var tint: Color {
        if indicator.isFault { return indicator.isOn ? Theme.aqiUnhealthy : Theme.textSecondary }
        return indicator.isOn ? Theme.aqiExcellent : Theme.textSecondary
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: iconName)
                .foregroundStyle(tint)
            Text(indicator.label)
                .font(.subheadline)
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            Text("bit \(indicator.bit)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(Theme.textSecondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(indicator.label): \(indicator.isOn ? "on" : "off")")
    }
}
