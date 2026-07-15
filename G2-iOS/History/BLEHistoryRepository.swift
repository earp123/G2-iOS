//
//  BLEHistoryRepository.swift
//  G2-iOS
//
//  BLE history source (BLE_HISTORY_PROTOCOL.md). Owns sync POLICY; the actual
//  persistence (batched inserts, timestamp dedupe, 90-day prune) runs on the
//  HistoryDataStore actor off the main thread.
//
//  Sync strategy:
//   • First sync for a device (empty cache) → full dump (opcode 0x01).
//   • Cache stale beyond the 90-day retention → full dump after clearing.
//   • Otherwise → incremental (opcode 0x0C): request the newest N records where
//     N = minutes-behind + a safety margin (records are ~1/min but gaps happen),
//     then dedupe by timestamp against the cache.
//  Records with unanchored timestamps (RTC read failed at log time) are skipped
//  by the data store. After a completed sync the cache is pruned to the trailing
//  90 days — the app never keeps more than ~3 MB per device.
//

import Foundation

@MainActor
final class BLEHistoryRepository: HistoryRepository {

    private let dataStore: HistoryDataStore
    /// Used to write sync opcodes; weak to avoid retaining the BLE manager.
    weak var transport: HistorySyncTransport?

    /// Extra records requested beyond minutes-behind, absorbing clock skew and
    /// uneven logging cadence (protocol doc: "add a small safety margin").
    private static let syncMarginRecords: UInt32 = 30
    private static let lastDeviceKey = "lastHistoryDeviceID"
    private static let batchSize = 500

    init(dataStore: HistoryDataStore, transport: HistorySyncTransport? = nil) {
        self.dataStore = dataStore
        self.transport = transport
    }

    var sourceLabel: String {
        if let id = activeDeviceID { return "Device \(id) (BLE)" }
        return "Device (BLE)"
    }

    /// Connected device wins; otherwise the most recently synced one, so History
    /// still shows cached data after a disconnect.
    var activeDeviceID: String? {
        transport?.connectedDeviceID ?? UserDefaults.standard.string(forKey: Self.lastDeviceKey)
    }

    func prepareIfNeeded() async {}   // nothing to seed — data arrives via sync

    func syncHistory(onProgress: @escaping @MainActor (Double) -> Void) async -> HistorySyncResult {
        guard let transport, transport.isConnected, let deviceID = transport.connectedDeviceID else {
            return .notConnected
        }

        // Pick full vs incremental from the device's cached high-water mark.
        let newest = try? await dataStore.newestTimestamp(deviceID: deviceID)
        let mode: HistorySyncMode
        var dedupe = true
        if let newest, Date().timeIntervalSince(newest) < HistoryDataStore.retention {
            let minutesBehind = max(0, Date().timeIntervalSince(newest) / 60)
            mode = .recent(count: UInt32(minutesBehind.rounded(.up)) + Self.syncMarginRecords)
        } else {
            // Empty or stale-beyond-retention cache: restart clean with a full dump.
            try? await dataStore.deleteRecords(deviceID: deviceID)
            mode = .full
            dedupe = false   // nothing left to collide with — skip the per-batch query
        }

        var batch: [HistoryRecordFields] = []
        batch.reserveCapacity(Self.batchSize)
        var received = 0
        var sawEndOfSync = false
        var lastReportedPercent = -1

        for await event in transport.startHistorySync(mode: mode) {
            switch event {
            case .record(let fields, let index, let total):
                batch.append(fields)
                received += 1
                if batch.count >= Self.batchSize {
                    _ = try? await dataStore.insertBatch(batch, deviceID: deviceID, dedupe: dedupe)
                    batch.removeAll(keepingCapacity: true)
                }
                // u24 index/total are sync-relative and reliable — throttle to 1% steps.
                if total > 0 {
                    let percent = ((index + 1) * 100) / total
                    if percent != lastReportedPercent {
                        lastReportedPercent = percent
                        onProgress(Double(index + 1) / Double(total))
                    }
                }
            case .endOfSync:
                sawEndOfSync = true
            }
        }
        if !batch.isEmpty {
            _ = try? await dataStore.insertBatch(batch, deviceID: deviceID, dedupe: dedupe)
        }

        // Connected, sent the command, nothing arrived before the timeout.
        if received == 0 && !sawEndOfSync { return .noRecords }

        // Keep only the trailing 90 days, then report the true cached count.
        if sawEndOfSync {
            _ = try? await dataStore.pruneToRetention(deviceID: deviceID)
        }
        UserDefaults.standard.set(deviceID, forKey: Self.lastDeviceKey)
        let count = (try? await dataStore.recordCount(deviceID: deviceID, since: nil)) ?? received
        return .completed(count: count)
    }
}
