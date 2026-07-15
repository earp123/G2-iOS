//
//  HistoryDataStore.swift
//  G2-iOS
//
//  Background persistence engine for history records. All heavy SwiftData work —
//  batch inserts during a sync, timestamp dedupe, the 90-day rolling prune, and
//  chart aggregation over up to ~130k rows — runs on this actor's executor, off
//  the main thread, so the UI stays smooth (the earlier design loaded every record
//  into an array on the main actor and re-filtered it per render).
//
//  Records are scoped per device (`HistoryRecord.deviceID`, the last two bytes of
//  the peripheral's Bluetooth identifier) so one app can cache multiple monitors.
//  Only Sendable value types (HistoryRecordFields, ChartPoint, Date, Int) cross
//  the actor boundary — SwiftData models never leave it.
//

import Foundation
import SwiftData

/// One plottable series, extracted per record on the actor. `nonisolated` so the
/// extractor can run on the HistoryDataStore executor (the project defaults new
/// types to MainActor isolation).
nonisolated enum HistorySeriesKind: Sendable {
    case temperature, humidity, tvoc, eco2, pm1, pm25, pm10

    func value(from record: HistoryRecord) -> Double? {
        switch self {
        case .temperature: record.temperatureC
        case .humidity:    record.humidityPct
        case .tvoc:        record.tvocPpb.map(Double.init)
        case .eco2:        record.eco2Ppm.map(Double.init)
        case .pm1:         record.pm1.map(Double.init)
        case .pm25:        record.pm25.map(Double.init)
        case .pm10:        record.pm10.map(Double.init)
        }
    }
}

@ModelActor
actor HistoryDataStore {

    /// Records older than this (relative to the device's newest record) are pruned
    /// after every sync — the app only ever keeps the trailing 90 days (< 3 MB).
    static let retention: TimeInterval = 90 * 86_400

    /// Timestamps below this are "unanchored": the firmware logs seconds-since-boot
    /// when the RTC read fails at log time (BLE_HISTORY_PROTOCOL.md caveat). Such
    /// records can't be placed on the time axis and are skipped during caching.
    static let plausibleEpochFloor = Date(timeIntervalSince1970: 1_577_836_800) // 2020-01-01Z

    private static let fetchChunk = 4_000

    // MARK: - Writes

    /// Inserts a batch, skipping records whose timestamp is unanchored or already
    /// cached for this device (dedupe by timestamp within the batch's own time
    /// window — a small indexed query, so memory stays bounded on 130k-row dumps).
    /// Returns the number actually inserted.
    @discardableResult
    func insertBatch(_ batch: [HistoryRecordFields], deviceID: String, dedupe: Bool) throws -> Int {
        let plausible = batch.filter { $0.timestamp >= Self.plausibleEpochFloor }
        guard let minTs = plausible.map(\.timestamp).min(),
              let maxTs = plausible.map(\.timestamp).max() else { return 0 }

        var existing: Set<Date> = []
        if dedupe {
            let descriptor = FetchDescriptor<HistoryRecord>(
                predicate: #Predicate { $0.deviceID == deviceID && $0.timestamp >= minTs && $0.timestamp <= maxTs }
            )
            existing = Set(try modelContext.fetch(descriptor).map(\.timestamp))
        }

        var inserted = 0
        for fields in plausible where !existing.contains(fields.timestamp) {
            modelContext.insert(HistoryRecord(fields: fields, deviceID: deviceID))
            existing.insert(fields.timestamp)   // also guards duplicates within the batch
            inserted += 1
        }
        if inserted > 0 { try modelContext.save() }
        return inserted
    }

    /// Deletes every cached record for a device (full-dump restart / cache recovery).
    func deleteRecords(deviceID: String) throws {
        try modelContext.delete(model: HistoryRecord.self,
                                where: #Predicate { $0.deviceID == deviceID })
        try modelContext.save()
    }

    /// Rolling-window prune: drops records older than `retention` behind the
    /// device's newest record. Returns the number of rows removed.
    @discardableResult
    func pruneToRetention(deviceID: String) throws -> Int {
        guard let newest = try newestTimestamp(deviceID: deviceID) else { return 0 }
        let cutoff = newest.addingTimeInterval(-Self.retention)
        let before = try recordCount(deviceID: deviceID, since: nil)
        try modelContext.delete(model: HistoryRecord.self,
                                where: #Predicate { $0.deviceID == deviceID && $0.timestamp < cutoff })
        try modelContext.save()
        return before - (try recordCount(deviceID: deviceID, since: nil))
    }

    // MARK: - Reads

    /// Newest plausible (RTC-anchored) record timestamp for a device.
    func newestTimestamp(deviceID: String) throws -> Date? {
        let floor = Self.plausibleEpochFloor
        var descriptor = FetchDescriptor<HistoryRecord>(
            predicate: #Predicate { $0.deviceID == deviceID && $0.timestamp >= floor },
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first?.timestamp
    }

    func recordCount(deviceID: String, since cutoff: Date?) throws -> Int {
        let descriptor: FetchDescriptor<HistoryRecord>
        if let cutoff {
            descriptor = FetchDescriptor(predicate: #Predicate { $0.deviceID == deviceID && $0.timestamp >= cutoff })
        } else {
            descriptor = FetchDescriptor(predicate: #Predicate { $0.deviceID == deviceID })
        }
        return try modelContext.fetchCount(descriptor)
    }

    /// Bucketed, averaged chart series for one metric over [cutoff, ∞), fetched in
    /// chunks so peak memory stays flat even over a full 90-day cache. Buckets with
    /// only sentinel values are dropped, so charts show gaps rather than zeros.
    func chartSeries(deviceID: String, kind: HistorySeriesKind,
                     cutoff: Date, bucket: TimeInterval) throws -> [ChartPoint] {
        var sums: [Int: (total: Double, count: Int, anchor: Date)] = [:]

        var descriptor = FetchDescriptor<HistoryRecord>(
            predicate: #Predicate { $0.deviceID == deviceID && $0.timestamp >= cutoff },
            sortBy: [SortDescriptor(\.timestamp, order: .forward)]
        )
        descriptor.fetchLimit = Self.fetchChunk

        var offset = 0
        while true {
            descriptor.fetchOffset = offset
            let chunk = try modelContext.fetch(descriptor)
            for record in chunk {
                guard let v = kind.value(from: record) else { continue }
                let idx = Int(record.timestamp.timeIntervalSince1970 / bucket)
                if let existing = sums[idx] {
                    sums[idx] = (existing.total + v, existing.count + 1, existing.anchor)
                } else {
                    sums[idx] = (v, 1, Date(timeIntervalSince1970: Double(idx) * bucket))
                }
            }
            if chunk.count < Self.fetchChunk { break }
            offset += chunk.count
        }

        return sums.values
            .map { ChartPoint(date: $0.anchor, value: $0.total / Double($0.count)) }
            .sorted { $0.date < $1.date }
    }
}
