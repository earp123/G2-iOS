//
//  HistoryDetailView.swift
//  Smart Air Monitor
//
//  Full breakdown of a single history record (§4.2): all fields, decoded status
//  bits, and the AQI label. Sentinel fields render as "—".
//

import SwiftUI

struct HistoryDetailView: View {
    let record: HistoryRecord

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.spacing) {
                aqiHeader

                VStack(alignment: .leading, spacing: 12) {
                    InfoRow(label: "Timestamp", value: record.timestamp.formatted(date: .abbreviated, time: .standard))
                    Divider().overlay(Theme.hairline)
                    InfoRow(label: "Temperature", value: record.temperatureC.map { String(format: "%.2f °C", $0) } ?? "—")
                    Divider().overlay(Theme.hairline)
                    InfoRow(label: "Humidity", value: record.humidityPct.map { String(format: "%.2f %%", $0) } ?? "—")
                    Divider().overlay(Theme.hairline)
                    InfoRow(label: "TVOC", value: record.tvocPpb.map { "\($0) ppb" } ?? "—")
                    Divider().overlay(Theme.hairline)
                    InfoRow(label: "eCO₂", value: record.eco2Ppm.map { "\($0) ppm" } ?? "—")
                    Divider().overlay(Theme.hairline)
                    InfoRow(label: "PM1.0", value: record.pm1.map { "\($0) µg/m³" } ?? "—")
                    Divider().overlay(Theme.hairline)
                    InfoRow(label: "PM2.5", value: record.pm25.map { "\($0) µg/m³" } ?? "—")
                    Divider().overlay(Theme.hairline)
                    InfoRow(label: "PM10", value: record.pm10.map { "\($0) µg/m³" } ?? "—")
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

    private var aqiHeader: some View {
        VStack(spacing: 6) {
            Text(record.aqiLevel.isValid ? "\(record.aqi)" : "—")
                .font(.system(size: 56, weight: .bold, design: .rounded))
                .foregroundStyle(record.aqiLevel.color)
            Text(record.aqiLevel.label)
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
        .background(record.aqiLevel.color.opacity(0.14),
                    in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("SENSOR STATUS")
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
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: indicator.isOn ? "checkmark.circle.fill" : "xmark.circle")
                .foregroundStyle(indicator.isOn ? Theme.aqiExcellent : Theme.textSecondary)
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
