//
//  MockHistoryRepository.swift
//  Smart Air Monitor
//
//  Default history source (§4.1). Generates ~60 days of believable, minute-shaped
//  data and persists it with SwiftData so history survives relaunch.
//
//  Sampling: the firmware logs ~1 record/minute. To keep first-launch generation,
//  persistence, and charting fast while staying believable, the mock samples at
//  15-minute resolution → 60 d × 24 h × 4 = 5,760 records. To go finer, change
//  `sampleInterval` below (the rest of the pipeline is resolution-agnostic).
//

import Foundation
import SwiftData

@MainActor
final class MockHistoryRepository: HistoryRepository {

    let sourceLabel = "Mock (synthetic)"

    private let context: ModelContext
    private let dayCount = 60
    private let sampleInterval: TimeInterval = 15 * 60   // 15 minutes

    init(context: ModelContext) {
        self.context = context
    }

    func loadAll() throws -> [HistoryRecord] {
        let existing = try fetchAll()
        if existing.isEmpty {
            try generate()
            return try fetchAll()
        }
        return existing
    }

    /// In mock mode a "sync" regenerates fresh synthetic data (honest: this is
    /// simulated, not a real transfer). Returns the resulting record count.
    func syncHistory() async -> HistorySyncResult {
        // A brief, real delay so the UI's syncing state is visible — but we never
        // imply that records moved off a real device.
        try? await Task.sleep(for: .milliseconds(700))
        do {
            try deleteAll()
            try generate()
            let count = try fetchAll().count
            return .completed(count: count)
        } catch {
            return .completed(count: (try? fetchAll().count) ?? 0)
        }
    }

    // MARK: - Persistence

    private func fetchAll() throws -> [HistoryRecord] {
        let descriptor = FetchDescriptor<HistoryRecord>(
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]   // newest-first (§4.2)
        )
        return try context.fetch(descriptor)
    }

    private func deleteAll() throws {
        try context.delete(model: HistoryRecord.self)
        try context.save()
    }

    // MARK: - Synthetic data generation

    private func generate() throws {
        let now = Date()
        let start = now.addingTimeInterval(-Double(dayCount) * 86_400)
        let totalSamples = Int(Double(dayCount) * 86_400 / sampleInterval)
        let calendar = Calendar.current

        var sequence: UInt16 = 0
        for i in 0..<totalSamples {
            let t = start.addingTimeInterval(Double(i) * sampleInterval)

            // Time-of-day phase (0…1) for diurnal variation.
            let hour = Double(calendar.component(.hour, from: t))
                + Double(calendar.component(.minute, from: t)) / 60.0
            let dayPhase = sin((hour - 9.0) / 24.0 * 2.0 * .pi)   // peak ~ mid-afternoon

            // Temperature: ~19 °C at night → ~25 °C afternoon, plus jitter.
            let temp = 22.0 + dayPhase * 3.0 + Double.random(in: -0.4...0.4)

            // Humidity inversely tracks temperature.
            let humidity = 48.0 - dayPhase * 8.0 + Double.random(in: -2.0...2.0)

            // TVOC baseline with occasional cooking/cleaning spikes.
            var tvoc = 110.0 + dayPhase * 30.0 + Double.random(in: -20...20)
            if Double.random(in: 0...1) < 0.015 { tvoc += Double.random(in: 400...900) }
            tvoc = max(0, tvoc)

            // eCO2 loosely correlated with TVOC and occupancy.
            let eco2 = 420.0 + (tvoc - 110.0) * 0.5 + dayPhase * 120.0 + Double.random(in: -30...30)

            let aqi = aqiFor(tvoc: tvoc)
            // Mostly all-healthy (0x1F); occasionally a sensor read blip clears a bit.
            let status: UInt8 = Double.random(in: 0...1) < 0.02 ? 0x1D : 0x1F

            // Particulate matter: low baselines that rise with the day and spike
            // alongside cooking/cleaning TVOC events. PM10 > PM2.5 > PM1.0.
            let pmSpike = (tvoc > 400) ? Double.random(in: 20...60) : 0
            let pm1  = max(0, 5.0  + dayPhase * 4.0 + pmSpike * 0.5 + Double.random(in: -2...2))
            let pm25 = max(0, 9.0  + dayPhase * 6.0 + pmSpike       + Double.random(in: -3...3))
            let pm10 = max(0, 14.0 + dayPhase * 8.0 + pmSpike * 1.4 + Double.random(in: -4...4))

            // ~3% of samples carry an invalid sentinel on some field (§4.1 gaps).
            let gap = Double.random(in: 0...1) < 0.03

            let record = HistoryRecord(
                timestamp: t,
                temperatureC: gap && Bool.random() ? nil : round(temp * 10) / 10,
                humidityPct:  gap && Bool.random() ? nil : round(humidity * 10) / 10,
                tvocPpb:      gap ? nil : Int(tvoc.rounded()),
                eco2Ppm:      gap && Bool.random() ? nil : Int(eco2.rounded()),
                aqi:          gap ? 0 : aqi,
                status:       status,
                sequence:     sequence,
                pm1:          gap && Bool.random() ? nil : Int(pm1.rounded()),
                pm25:         gap ? nil : Int(pm25.rounded()),
                pm10:         gap && Bool.random() ? nil : Int(pm10.rounded())
            )
            context.insert(record)
            sequence = sequence &+ 1   // wraps at 65535, like the firmware counter
        }
        try context.save()
    }

    /// Rough UBA bucketing of TVOC for the synthetic AQI series.
    private func aqiFor(tvoc: Double) -> Int {
        switch tvoc {
        case ..<150:  2   // good
        case ..<350:  3   // moderate
        case ..<650:  4   // poor
        default:      5   // unhealthy
        }
    }
}
