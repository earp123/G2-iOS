//
//  BLEHistoryRepository.swift
//  Smart Air Monitor
//
//  BLE history source. Sends CMD_SYNC_HISTORY (0x01) and collects the resulting
//  stream of 16-byte flash records that the device sends back as notifications on
//  the Sensor Data characteristic (demuxed by BluetoothManager on payload[0] == 0xA5).
//
//  Each HistoryStreamEvent.record carries a HistoryRecordFields value, which this
//  class converts to a @Model HistoryRecord and inserts into the SwiftData context.
//  Records are persisted on receipt of the end-of-sync sentinel or when the stream
//  ends (e.g. disconnected mid-sync — partial records are kept).
//

import Foundation
import SwiftData

@MainActor
final class BLEHistoryRepository: HistoryRepository {

    let sourceLabel = "Device (BLE)"

    private let context: ModelContext
    weak var transport: HistorySyncTransport?

    init(context: ModelContext, transport: HistorySyncTransport? = nil) {
        self.context = context
        self.transport = transport
    }

    func loadAll() throws -> [HistoryRecord] {
        let descriptor = FetchDescriptor<HistoryRecord>(
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        return try context.fetch(descriptor)
    }

    func syncHistory() async -> HistorySyncResult {
        guard let transport, transport.isConnected else { return .notConnected }

        // Delete stale records before streaming fresh ones.
        if let existing = try? context.fetch(FetchDescriptor<HistoryRecord>()) {
            existing.forEach { context.delete($0) }
        }

        var insertedCount = 0
        for await event in transport.startHistorySync() {
            switch event {
            case .record(let fields):
                let record = HistoryRecord(
                    timestamp:    fields.timestamp,
                    temperatureC: fields.temperatureC,
                    humidityPct:  fields.humidityPct,
                    tvocPpb:      fields.tvocPpb,
                    eco2Ppm:      fields.eco2Ppm,
                    aqi:          fields.aqi,
                    status:       fields.status,
                    sequence:     fields.sequence
                )
                context.insert(record)
                insertedCount += 1
            case .completed(let totalCount):
                try? context.save()
                return .completed(count: totalCount)
            }
        }
        // Stream ended before sentinel — connection dropped mid-sync.
        if insertedCount > 0 { try? context.save() }
        return .notConnected
    }
}
