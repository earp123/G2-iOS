//
//  HistoryRepository.swift
//  Smart Air Monitor
//
//  The history data layer abstraction (§4.1). Two implementations exist and both
//  compile: MockHistoryRepository (default) and BLEHistoryRepository (stub).
//  A single DI switch selects which one the app uses (see HistoryDataSource).
//

import Foundation
import SwiftData

/// Outcome of a `syncHistory()` call, surfaced honestly in the UI (§4.2).
enum HistorySyncResult: Equatable, Sendable {
    /// Records were (re)materialised into the store. `count` reflects total available.
    case completed(count: Int)
    /// Cannot sync because there is no active BLE connection (or dropped mid-sync).
    case notConnected
    /// Connected and sent SYNC_HISTORY, but the device streamed no records before the
    /// sync timed out (e.g. firmware without history streaming).
    case noRecords
}

/// Parsed field values from a single 16-byte geue_log_record_t. A plain Sendable
/// struct so it can cross the AsyncStream boundary without touching SwiftData models.
struct HistoryRecordFields: Sendable {
    let timestamp:    Date
    let temperatureC: Double?
    let humidityPct:  Double?
    let tvocPpb:      Int?
    let eco2Ppm:      Int?
    let aqi:          Int
    let status:       UInt8
    let sequence:     UInt16
    let pm1:          Int?   // µg/m³ (nil = sentinel); PM logged since firmware 2026-07-09
    let pm25:         Int?
    let pm10:         Int?
}

/// Events yielded by the history sync stream (§2 CMD_SYNC_HISTORY).
enum HistoryStreamEvent: Sendable {
    /// One decoded flash record.
    case record(HistoryRecordFields)
    /// End-of-sync sentinel received; `totalCount` matches the device's log size.
    case completed(totalCount: Int)
}

/// Can stream history records over BLE. BluetoothManager conforms (§4).
@MainActor
protocol HistorySyncTransport: AnyObject {
    var isConnected: Bool { get }
    /// Sends opcode 0x01 and returns a stream of events. Finishes when the end-of-sync
    /// sentinel arrives or the connection drops.
    func startHistorySync() -> AsyncStream<HistoryStreamEvent>
}

/// History data source abstraction. The views, models, and SwiftData layer depend
/// only on this — swapping mock ↔ BLE is a localized change (§4.3).
@MainActor
protocol HistoryRepository: AnyObject {
    /// Human-readable name of the active source, shown in Settings/History.
    var sourceLabel: String { get }

    /// Ensures the store is populated and returns all records, newest-first.
    func loadAll() throws -> [HistoryRecord]

    /// Triggers a sync from the backing source. See `HistorySyncResult`.
    func syncHistory() async -> HistorySyncResult
}

/// Compile-time/runtime DI switch (§4.1). Default `.mock` so the UI is fully
/// populated in development; `.ble` exercises the (stubbed) firmware path.
enum HistoryDataSource {
    case mock
    case ble
}
