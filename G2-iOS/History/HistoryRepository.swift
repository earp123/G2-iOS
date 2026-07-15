//
//  HistoryRepository.swift
//  G2-iOS
//
//  The history data layer abstraction (§4.1). Two implementations exist and both
//  compile: MockHistoryRepository and BLEHistoryRepository, selected by a single
//  DI switch (see HistoryDataSource). Heavy reads/writes go through the shared
//  HistoryDataStore actor; repositories own sync/generation policy only.
//

import Foundation

/// Outcome of a `syncHistory()` call, surfaced honestly in the UI (§4.2).
enum HistorySyncResult: Equatable, Sendable {
    /// Records were synced into the cache. `count` is the device's cached total.
    case completed(count: Int)
    /// Cannot sync because there is no active BLE connection (or dropped mid-sync).
    case notConnected
    /// Connected and sent the sync command, but the device streamed no records
    /// before the timeout (e.g. firmware without history streaming).
    case noRecords
}

/// Parsed field values from a single 22-byte geue_log_record_t. A plain Sendable
/// struct so it can cross the AsyncStream and actor boundaries without touching
/// SwiftData models.
struct HistoryRecordFields: Sendable {
    let timestamp:    Date
    let temperatureC: Double?
    let humidityPct:  Double?
    let tvocPpb:      Int?
    let eco2Ppm:      Int?
    let aqi:          Int
    let status:       UInt8
    let sequence:     UInt16
    let pm1:          Int?   // µg/m³ (nil = sentinel)
    let pm25:         Int?
    let pm10:         Int?
}

/// How much history to request from the device (BLE_HISTORY_PROTOCOL.md).
enum HistorySyncMode: Sendable {
    /// Opcode 0x01 — stream everything, oldest first. First run / cache recovery.
    case full
    /// Opcode 0x0C + u32 count — stream the newest `count` records,
    /// oldest-of-the-window first. count 0 → sentinel-only handshake.
    case recent(count: UInt32)
}

/// Events yielded by the history sync stream.
enum HistoryStreamEvent: Sendable {
    /// One decoded record, in arrival order, with its u24 position for progress.
    case record(HistoryRecordFields, index: Int, total: Int)
    /// End-of-sync sentinel (all-zero record) received — the stream is complete.
    case endOfSync
}

/// Can stream history records over BLE. BluetoothManager conforms (§4).
@MainActor
protocol HistorySyncTransport: AnyObject {
    var isConnected: Bool { get }
    /// Short ID of the connected device (last two bytes of its Bluetooth identifier).
    var connectedDeviceID: String? { get }
    /// Sends the sync command and returns a stream of events. Finishes on the
    /// end-of-sync sentinel, on link loss, or on the inactivity timeout.
    func startHistorySync(mode: HistorySyncMode) -> AsyncStream<HistoryStreamEvent>
}

/// History data source abstraction. Owns sync policy; the store reads chart/list
/// data through HistoryDataStore directly, so swapping mock ↔ BLE stays localized.
@MainActor
protocol HistoryRepository: AnyObject {
    /// Human-readable name of the active source, shown in Settings/History.
    var sourceLabel: String { get }

    /// Short ID of the device whose records the UI should show (connected device,
    /// else the most recently synced one). nil = nothing to show yet.
    var activeDeviceID: String? { get }

    /// One-time preparation (e.g. the mock seeds its synthetic dataset).
    func prepareIfNeeded() async

    /// Triggers a sync from the backing source. `onProgress` receives a 0…1
    /// fraction when the stream size is known. See `HistorySyncResult`.
    func syncHistory(onProgress: @escaping @MainActor (Double) -> Void) async -> HistorySyncResult
}

/// Compile-time/runtime DI switch (§4.1): `.ble` on device, `.mock` in the
/// Simulator (see G2_iOSApp).
enum HistoryDataSource {
    case mock
    case ble
}
