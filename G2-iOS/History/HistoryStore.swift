//
//  HistoryStore.swift
//  G2-iOS
//
//  Observable view model for the history feature (§4.2). Owns the selected metric
//  and range plus *precomputed* chart/list state. All heavy aggregation runs on the
//  HistoryDataStore actor and results land here as small value arrays — the store
//  never holds the full record set in memory (the previous design kept every
//  record in an array and re-filtered it per render, which lagged at 90 days of
//  1/min data).
//
//  Windows are anchored to the device's newest *logged* record, not the phone's
//  wall clock, so a device RTC offset can't blank the shorter ranges.
//

import Foundation
import Observation
import SwiftData

@MainActor
@Observable
final class HistoryStore {

    enum SyncState: Equatable {
        case idle
        case syncing
        case result(HistorySyncResult)
    }

    /// The drill-down list renders at most this many rows; the header shows the
    /// true in-range total. Keeps List diffing cheap over a 130k-record cache.
    static let listLimit = 200

    private let repository: HistoryRepository
    private let dataStore: HistoryDataStore
    private let listContext: ModelContext   // main-actor context for List rows

    var selectedMetric: HistoryMetric = .tvoc {
        didSet { if oldValue != selectedMetric { refresh(chartsOnly: true) } }
    }
    var selectedRange: HistoryRange = .day {
        didSet { if oldValue != selectedRange { refresh() } }
    }

    // Precomputed presentation state (updated by refresh(), not per render).
    private(set) var chartPoints: [ChartPoint] = []
    private(set) var temperatureSeries: [ChartPoint] = []
    private(set) var humiditySeries: [ChartPoint] = []
    private(set) var listRecords: [HistoryRecord] = []
    private(set) var totalInRange = 0
    private(set) var hasData = false
    private(set) var syncState: SyncState = .idle
    /// 0…1 while a sized stream is running, nil otherwise.
    private(set) var syncProgress: Double?

    var sourceLabel: String { repository.sourceLabel }
    var activeDeviceID: String? { repository.activeDeviceID }

    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var didPrepare = false

    init(repository: HistoryRepository, dataStore: HistoryDataStore, modelContext: ModelContext) {
        self.repository = repository
        self.dataStore = dataStore
        self.listContext = modelContext
    }

    func loadIfNeeded() {
        guard !didPrepare else { return }
        didPrepare = true
        Task { @MainActor in
            await repository.prepareIfNeeded()
            refresh()
        }
    }

    func sync() async {
        syncState = .syncing
        syncProgress = nil
        let result = await repository.syncHistory { [weak self] fraction in
            self?.syncProgress = fraction
        }
        syncProgress = nil
        refresh()
        syncState = .result(result)
    }

    func clearSyncResult() { syncState = .idle }

    // MARK: - Derived-state refresh

    /// Recomputes list/count on the main context (cheap, row-limited) and chart
    /// series on the data-store actor (heavy, chunked). Cancel-replaces any
    /// in-flight refresh so rapid range/metric flips can't interleave stale state.
    func refresh(chartsOnly: Bool = false) {
        refreshTask?.cancel()
        let metric = selectedMetric
        let range = selectedRange

        refreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            guard let deviceID = self.activeDeviceID else {
                self.applyEmpty()
                return
            }

            // Anchor the window to the newest logged record (not wall clock).
            let anchor = (try? await self.dataStore.newestTimestamp(deviceID: deviceID)) ?? Date()
            let cutoff = anchor.addingTimeInterval(-range.duration)
            if Task.isCancelled { return }

            if !chartsOnly {
                self.hasData = ((try? await self.dataStore.recordCount(deviceID: deviceID, since: nil)) ?? 0) > 0
                self.totalInRange = (try? await self.dataStore.recordCount(deviceID: deviceID, since: cutoff)) ?? 0
                self.listRecords = self.fetchListRows(deviceID: deviceID, cutoff: cutoff)
            }
            if Task.isCancelled { return }

            switch metric {
            case .tempHumidity:
                let temp = (try? await self.dataStore.chartSeries(
                    deviceID: deviceID, kind: .temperature, cutoff: cutoff, bucket: range.bucket)) ?? []
                let hum = (try? await self.dataStore.chartSeries(
                    deviceID: deviceID, kind: .humidity, cutoff: cutoff, bucket: range.bucket)) ?? []
                if Task.isCancelled { return }
                self.temperatureSeries = temp
                self.humiditySeries = hum
                self.chartPoints = []
            default:
                guard let kind = metric.seriesKind else { return }
                let points = (try? await self.dataStore.chartSeries(
                    deviceID: deviceID, kind: kind, cutoff: cutoff, bucket: range.bucket)) ?? []
                if Task.isCancelled { return }
                self.chartPoints = points
                self.temperatureSeries = []
                self.humiditySeries = []
            }
        }
    }

    /// Newest-first rows for the drill-down list — a bounded main-context fetch
    /// (SwiftUI navigation needs the model objects on the main actor).
    private func fetchListRows(deviceID: String, cutoff: Date) -> [HistoryRecord] {
        var descriptor = FetchDescriptor<HistoryRecord>(
            predicate: #Predicate { $0.deviceID == deviceID && $0.timestamp >= cutoff },
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        descriptor.fetchLimit = Self.listLimit
        return (try? listContext.fetch(descriptor)) ?? []
    }

    private func applyEmpty() {
        chartPoints = []
        temperatureSeries = []
        humiditySeries = []
        listRecords = []
        totalInRange = 0
        hasData = false
    }
}
