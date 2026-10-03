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
    /// Last log-record version the cache was written under (§2).
    private static let recordVersionKey = "historyLogRecordVersion"
    private static let batchSize = 500

    /// The record-version check runs once per launch, on the first sync.
    private var didCheckRecordVersion = false

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

        // A firmware log-record version change invalidates every cached row
        // before anything is read back (§2).
        await wipeCacheIfRecordVersionChanged(reportedBy: transport)

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

    /// Compares the device's reported log-record version against the version the
    /// cache was written under and wipes **all** rows when it differs. Runs once
    /// per launch, on the first sync (§2).
    ///
    /// Records written under a different record layout carry different semantics
    /// (v1 stored TVOC ppb and eCO₂ where v2 stores a VOC index and measured CO₂),
    /// so they are discarded rather than mixed in. A device that has not reported
    /// Device Info yet is assumed to speak this build's version — it cannot have
    /// streamed a record of any other shape through this parser.
    private func wipeCacheIfRecordVersionChanged(reportedBy transport: HistorySyncTransport) async {
        guard !didCheckRecordVersion else { return }
        didCheckRecordVersion = true

        let reported = Int(transport.deviceLogRecordVersion ?? GATT.historyRecordVersion)
        let defaults = UserDefaults.standard
        let cached = defaults.object(forKey: Self.recordVersionKey) as? Int
        guard cached != reported else { return }

        try? await dataStore.deleteAllRecords()
        defaults.set(reported, forKey: Self.recordVersionKey)
    }
}
