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
            HStack {
                Text(history.selectedMetric.title)
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                Text(history.selectedMetric.unit)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
            }

            if !history.selectedMetric.isLogged {
                notLoggedPlaceholder
            } else if history.chartPoints.isEmpty {
                chartPlaceholder("No data in this range.")
            } else {
                chart
            }
        }
        .card()
    }

    @ViewBuilder
    private var chart: some View {
        let base = Chart(history.chartPoints) { point in
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

        // AQI uses a fixed 0–5 scale; other metrics auto-scale.
        if history.selectedMetric == .aqi {
            base.chartYScale(domain: 0.0...5.0)
        } else {
            base
        }
    }

    private var notLoggedPlaceholder: some View {
        chartPlaceholder("PM is not logged in the 16-byte flash record, so there’s nothing to chart here.")
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
        }
    }

    private func icon(for result: HistorySyncResult) -> String {
        switch result {
        case .completed:    "checkmark.circle.fill"
        case .notConnected: "wifi.slash"
        }
    }

    private func tint(for result: HistorySyncResult) -> Color {
        switch result {
        case .completed:    Theme.aqiExcellent
        case .notConnected: Theme.aqiPoor
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
