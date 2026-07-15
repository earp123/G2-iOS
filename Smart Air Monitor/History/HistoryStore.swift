//
//  HistoryStore.swift
//  Smart Air Monitor
//
//  Observable view model for the history feature (§4.2). Owns the selected metric
//  and range, the loaded records, sync state, and chart aggregation. Talks only to
//  the HistoryRepository protocol, so the mock/BLE swap never touches the views.
//

import Foundation
import Observation

@MainActor
@Observable
final class HistoryStore {

    enum SyncState: Equatable {
        case idle
        case syncing
        case result(HistorySyncResult)
    }

    private let repository: HistoryRepository

    var selectedMetric: HistoryMetric = .tvoc
    var selectedRange: HistoryRange = .day
    private(set) var allRecords: [HistoryRecord] = []   // newest-first
    private(set) var syncState: SyncState = .idle
    private(set) var loadError: String?

    var sourceLabel: String { repository.sourceLabel }

    init(repository: HistoryRepository) {
        self.repository = repository
    }

    func loadIfNeeded() {
        guard allRecords.isEmpty else { return }
        load()
    }

    func load() {
        do {
            allRecords = try repository.loadAll()
            loadError = nil
        } catch {
            loadError = error.localizedDescription
            allRecords = []
        }
    }

    func sync() async {
        syncState = .syncing
        let result = await repository.syncHistory()
        load()                       // reflect any new data
        syncState = .result(result)
    }

    func clearSyncResult() { syncState = .idle }

    // MARK: - Derived data

    /// Records inside the selected range, newest-first (for the list, §4.2).
    var recordsInRange: [HistoryRecord] {
        let cutoff = Date().addingTimeInterval(-selectedRange.duration)
        return allRecords.filter { $0.timestamp >= cutoff }
    }

    /// Aggregated, bucketed points for the chart. Buckets average the valid values
    /// of `selectedMetric`; buckets with only sentinels are dropped (gaps show).
    var chartPoints: [ChartPoint] {
        bucketedSeries { selectedMetric.value(from: $0) }
    }

    /// Temperature (°C) series for the Temp/Humidity overlay (§4.2).
    var temperatureSeries: [ChartPoint] {
        bucketedSeries { $0.temperatureC }
    }

    /// Humidity (%) series for the Temp/Humidity overlay (§4.2).
    var humiditySeries: [ChartPoint] {
        bucketedSeries { $0.humidityPct }
    }

    /// Buckets records in the selected range and averages each bucket's valid
    /// values from `value`. Buckets with only sentinels are dropped so gaps show.
    private func bucketedSeries(_ value: (HistoryRecord) -> Double?) -> [ChartPoint] {
        let cutoff = Date().addingTimeInterval(-selectedRange.duration)
        let bucket = selectedRange.bucket

        // Group by bucket index (ascending time for the chart's x-axis).
        var sums: [Int: (total: Double, count: Int, anchor: Date)] = [:]
        for record in allRecords where record.timestamp >= cutoff {
            guard let v = value(record) else { continue }
            let idx = Int(record.timestamp.timeIntervalSince1970 / bucket)
            let anchor = Date(timeIntervalSince1970: Double(idx) * bucket)
            if let existing = sums[idx] {
                sums[idx] = (existing.total + v, existing.count + 1, existing.anchor)
            } else {
                sums[idx] = (v, 1, anchor)
            }
        }
        return sums.values
            .map { ChartPoint(date: $0.anchor, value: $0.total / Double($0.count)) }
            .sorted { $0.date < $1.date }
    }

    var hasData: Bool { !allRecords.isEmpty }
}
