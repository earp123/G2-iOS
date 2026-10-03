//
//  HistoryRowView.swift
//  G2-iOS
//
//  Compact summary row for one history record (§4.2): timestamp, key values, and
//  two class dots — gas and PM, coloured like the device's two LEDs
//  (thresholds-v3 §1.1). A record logged before contract v3 has no PM class and
//  shows a grey PM dot. Sentinel fields render as "—".
//

import SwiftUI

struct HistoryRowView: View {
    let record: HistoryRecord

    var body: some View {
        HStack(spacing: Theme.spacing) {
            VStack(spacing: 4) {
                Circle()
                    .fill(record.aqiLevel.color)
                    .frame(width: 10, height: 10)
                Circle()
                    .fill(record.pmLevel.color)
                    .frame(width: 10, height: 10)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Gas \(record.aqClassLabel), particulate \(record.pmClassLabel)")

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
        let voc = record.vocIndex.map { String(format: "%.0f", $0) } ?? "—"
        let co2 = record.co2Ppm.map { String(format: "%.0f ppm", $0) } ?? "—"
        return "\(temp) · VOC \(voc) · CO₂ \(co2)"
    }
}
