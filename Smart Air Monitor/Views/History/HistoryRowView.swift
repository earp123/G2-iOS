//
//  HistoryRowView.swift
//  Smart Air Monitor
//
//  Compact summary row for one history record (§4.2): timestamp, key values, and
//  an AQI color dot. Sentinel fields render as "—".
//

import SwiftUI

struct HistoryRowView: View {
    let record: HistoryRecord

    var body: some View {
        HStack(spacing: Theme.spacing) {
            Circle()
                .fill(record.aqiLevel.color)
                .frame(width: 10, height: 10)
                .accessibilityLabel("AQI \(record.aqiLevel.label)")

            VStack(alignment: .leading, spacing: 2) {
                Text(record.timestamp, format: .dateTime.month().day().hour().minute())
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.textPrimary)
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private var summary: String {
        let temp = record.temperatureC.map { String(format: "%.1f°C", $0) } ?? "—"
        let tvoc = record.tvocPpb.map { "\($0) ppb" } ?? "—"
        return "\(temp) · TVOC \(tvoc)"
    }
}
