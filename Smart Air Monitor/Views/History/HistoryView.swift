//
//  HistoryView.swift
//  Smart Air Monitor
//
//  The priority feature (§4/§6.3): Swift Charts time-series + drill-down list over
//  the stubbed-but-real-shaped history layer. Metric picker, 24h/7d/30d/60d range,
//  and an honest sync affordance (no fake transfer progress, §4.2/§9).
//

import SwiftUI
import Charts

struct HistoryView: View {
    @Environment(HistoryStore.self) private var history
    @Environment(BluetoothManager.self) private var bluetooth

    var body: some View {
        @Bindable var history = history

        Group {
            if !history.hasData {
                emptyState
            } else {
                List {
                    Section {
                        controls(history: history)
                        chartCard
                        syncStatusRow
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 6, leading: Theme.spacing, bottom: 6, trailing: Theme.spacing))

                    Section {
                        ForEach(history.recordsInRange) { record in
                            NavigationLink(value: record) { HistoryRowView(record: record) }
                                .listRowBackground(Theme.surface)
                        }
                    } header: {
                        Text("\(history.recordsInRange.count) records · newest first")
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
                .refreshable { await history.sync() }
                .navigationDestination(for: HistoryRecord.self) { HistoryDetailView(record: $0) }
            }
        }
        .background(Theme.background)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    Task { await history.sync() }
                } label: {
                    if case .syncing = history.syncState {
                        ProgressView()
                    } else {
                        Image(systemName: "arrow.triangle.2.circlepath")
                    }
                }
                .disabled(history.syncState == .syncing)
                .accessibilityLabel("Sync history from device")
            }
        }
        .task { history.loadIfNeeded() }
    }

    // MARK: - Controls

    private func controls(history: HistoryStore) -> some View {
        VStack(spacing: 10) {
            Picker("Range", selection: Binding(
                get: { history.selectedRange },
                set: { history.selectedRange = $0 })
            ) {
                ForEach(HistoryRange.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)

            Picker("Metric", selection: Binding(
                get: { history.selectedMetric },
                set: { history.selectedMetric = $0 })
            ) {
                ForEach(HistoryMetric.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
        }
    }

    // MARK: - Chart

    private var chartCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            chartHeader

            if history.selectedMetric.isOverlay {
                if history.temperatureSeries.isEmpty && history.humiditySeries.isEmpty {
                    chartPlaceholder("No data in this range.")
                } else {
                    tempHumidityChart
                }
            } else if history.chartPoints.isEmpty {
                chartPlaceholder("No data in this range.")
            } else {
                chart
            }
        }
        .card()
    }

    @ViewBuilder
    private var chartHeader: some View {
        if history.selectedMetric.isOverlay {
            HStack(spacing: 16) {
                legendChip("Temperature", unit: "°C", color: Theme.accentWarm)
                legendChip("Humidity", unit: "%", color: Theme.accentCool)
                Spacer(minLength: 0)
            }
        } else {
            HStack {
                Text(history.selectedMetric.title)
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                Text(history.selectedMetric.unit)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
            }
        }
    }

    private func legendChip(_ title: String, unit: String, color: Color) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 1.5).fill(color).frame(width: 16, height: 3)
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.textPrimary)
            Text(unit).font(.caption2).foregroundStyle(Theme.textSecondary)
        }
    }

    // Single-series chart (TVOC, eCO₂, PM1.0/2.5/10).
    private var chart: some View {
        Chart(history.chartPoints) { point in
            LineMark(
                x: .value("Time", point.date),
                y: .value(history.selectedMetric.title, point.value)
            )
            .interpolationMethod(.catmullRom)
            .foregroundStyle(history.selectedMetric.tint)

            AreaMark(
                x: .value("Time", point.date),
                y: .value(history.selectedMetric.title, point.value)
            )
            .interpolationMethod(.catmullRom)
            .foregroundStyle(history.selectedMetric.tint.opacity(0.15).gradient)
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine().foregroundStyle(Theme.hairline)
                AxisValueLabel().foregroundStyle(Theme.textSecondary)
            }
        }
        .chartYAxis {
            AxisMarks { _ in
                AxisGridLine().foregroundStyle(Theme.hairline)
                AxisValueLabel().foregroundStyle(Theme.textSecondary)
            }
        }
        .frame(height: 200)
    }

    // Dual-axis overlay: temperature (left, °C) + humidity (right, %). Humidity is
    // mapped into the temperature domain so both lines fill the plot; the trailing
    // axis labels are inverse-mapped back to %.
    private var tempHumidityChart: some View {
        let temp = history.temperatureSeries
        let hum = history.humiditySeries
        let tDomain = Self.niceDomain(temp, step: 2, fallback: 16...28)
        let hDomain = Self.niceDomain(hum, step: 10, fallback: 30...70)

        // Map a humidity value to its position on the temperature scale, and back.
        func toTemp(_ h: Double) -> Double {
            let f = (h - hDomain.lowerBound) / (hDomain.upperBound - hDomain.lowerBound)
            return tDomain.lowerBound + f * (tDomain.upperBound - tDomain.lowerBound)
        }
        func toHumidity(_ t: Double) -> Double {
            let f = (t - tDomain.lowerBound) / (tDomain.upperBound - tDomain.lowerBound)
            return hDomain.lowerBound + f * (hDomain.upperBound - hDomain.lowerBound)
        }
        let humidityTicks = Array(stride(from: hDomain.lowerBound, through: hDomain.upperBound, by: 10))

        return Chart {
            ForEach(temp) { point in
                LineMark(
                    x: .value("Time", point.date),
                    y: .value("Temperature", point.value),
                    series: .value("Series", "Temperature")
                )
                .interpolationMethod(.catmullRom)
                .foregroundStyle(Theme.accentWarm)
            }
            ForEach(hum) { point in
                LineMark(
                    x: .value("Time", point.date),
                    y: .value("Humidity", toTemp(point.value)),
                    series: .value("Series", "Humidity")
                )
                .interpolationMethod(.catmullRom)
                .foregroundStyle(Theme.accentCool)
            }
        }
        .chartYScale(domain: tDomain)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine().foregroundStyle(Theme.hairline)
                AxisValueLabel().foregroundStyle(Theme.textSecondary)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine().foregroundStyle(Theme.hairline)
                AxisValueLabel {
                    if let t = value.as(Double.self) {
                        Text("\(Int(t.rounded()))").foregroundStyle(Theme.accentWarm)
                    }
                }
            }
            AxisMarks(position: .trailing, values: humidityTicks.map(toTemp)) { value in
                AxisValueLabel {
                    if let mapped = value.as(Double.self) {
                        Text("\(Int(toHumidity(mapped).rounded()))").foregroundStyle(Theme.accentCool)
                    }
                }
            }
        }
        .frame(height: 200)
    }

    /// Rounds a series' min/max out to the nearest `step` for clean axis bounds.
    private static func niceDomain(_ points: [ChartPoint], step: Double, fallback: ClosedRange<Double>) -> ClosedRange<Double> {
        let values = points.map(\.value)
        guard let lo = values.min(), let hi = values.max() else { return fallback }
        let low = (lo / step).rounded(.down) * step
        let high = (hi / step).rounded(.up) * step
        return low < high ? low...high : low...(low + step)
    }

    private func chartPlaceholder(_ text: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "chart.line.downtrend.xyaxis")
                .font(.title)
                .foregroundStyle(Theme.textSecondary)
            Text(text)
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 200)
    }

    // MARK: - Sync status (honest, §4.2)

    @ViewBuilder
    private var syncStatusRow: some View {
        if case let .result(result) = history.syncState {
            HStack(spacing: 8) {
                Image(systemName: icon(for: result)).foregroundStyle(tint(for: result))
                Text(message(for: result))
                    .font(.caption)
                    .foregroundStyle(Theme.textPrimary)
                Spacer(minLength: 0)
            }
            .padding(10)
            .background(Theme.surfaceHi, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        } else {
            HStack {
                Image(systemName: "externaldrive.badge.timemachine").foregroundStyle(Theme.textSecondary)
                Text("Source: \(history.sourceLabel). Pull to refresh or use Sync.")
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 2)
        }
    }

    private func message(for result: HistorySyncResult) -> String {
        switch result {
        case .completed(let count): "Synced — \(count) records available."
        case .notConnected:         "Connect to a monitor to sync history."
        case .noRecords:            "The device returned no history. If it should have logs, check that this firmware implements SYNC_HISTORY."
        }
    }

    private func icon(for result: HistorySyncResult) -> String {
        switch result {
        case .completed:    "checkmark.circle.fill"
        case .notConnected: "wifi.slash"
        case .noRecords:    "tray"
        }
    }

    private func tint(for result: HistorySyncResult) -> Color {
        switch result {
        case .completed:    Theme.aqiExcellent
        case .notConnected: Theme.aqiPoor
        case .noRecords:    Theme.aqiModerate
        }
    }

    // MARK: - Empty state (§4.2)

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No history yet", systemImage: "clock.arrow.circlepath")
        } description: {
            Text("Records will appear here once they’ve been logged or synced.\nSource: \(history.sourceLabel).")
        } actions: {
            Button {
                Task { await history.sync() }
            } label: {
                Label("Sync from device", systemImage: "arrow.triangle.2.circlepath")
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
        }
        .foregroundStyle(Theme.textPrimary)
    }
}
