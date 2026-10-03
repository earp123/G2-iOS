//
//  MockHistoryRepository.swift
//  G2-iOS
//
//  Synthetic history source (§4.1) for hardware-free development. Generates ~60
//  days of believable, minute-shaped data under the device ID "MOCK" and persists
//  it through the HistoryDataStore actor (off the main thread), so first launch
//  and re-syncs don't hitch the UI.
//
//  Sampling: the firmware logs ~1 record/minute. To keep generation, persistence,
//  and charting fast while staying believable, the mock samples at 15-minute
//  resolution → 60 d × 24 h × 4 = 5,760 records. Change `sampleInterval` to go
//  finer — the rest of the pipeline is resolution-agnostic.
//

import Foundation

@MainActor
final class MockHistoryRepository: HistoryRepository {

    let sourceLabel = "Mock (synthetic)"
    var activeDeviceID: String? { Self.deviceID }

    private static let deviceID = "MOCK"
    private let dataStore: HistoryDataStore
    private let dayCount = 60
    private let sampleInterval: TimeInterval = 15 * 60   // 15 minutes

    init(dataStore: HistoryDataStore) {
        self.dataStore = dataStore
    }

    /// Seeds the synthetic dataset on first launch (empty cache only).
    func prepareIfNeeded() async {
        let count = (try? await dataStore.recordCount(deviceID: Self.deviceID, since: nil)) ?? 0
        if count == 0 { await generate() }
    }

    /// In mock mode a "sync" regenerates fresh synthetic data (honest: this is
    /// simulated, not a real transfer). Returns the resulting record count.
    func syncHistory(onProgress: @escaping @MainActor (Double) -> Void) async -> HistorySyncResult {
        // A brief, real delay so the UI's syncing state is visible — but we never
        // imply that records moved off a real device.
        try? await Task.sleep(for: .milliseconds(700))
        try? await dataStore.deleteRecords(deviceID: Self.deviceID)
        await generate(onProgress: onProgress)
        let count = (try? await dataStore.recordCount(deviceID: Self.deviceID, since: nil)) ?? 0
        return .completed(count: count)
    }

    // MARK: - Synthetic data generation

    private func generate(onProgress: (@MainActor (Double) -> Void)? = nil) async {
        let now = Date()
        let start = now.addingTimeInterval(-Double(dayCount) * 86_400)
        let totalSamples = Int(Double(dayCount) * 86_400 / sampleInterval)
        let calendar = Calendar.current

        var batch: [HistoryRecordFields] = []
        batch.reserveCapacity(1_000)
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

            // VOC index baseline with occasional cooking/cleaning spikes. The
            // SEN66 reports a 1–500 index, not a ppb concentration (§1.1).
            var vocIndex = 95.0 + dayPhase * 25.0 + Double.random(in: -15...15)
            if Double.random(in: 0...1) < 0.015 { vocIndex += Double.random(in: 150...320) }
            vocIndex = min(500, max(1, vocIndex))

            // NOx index sits low indoors and lifts with combustion-ish events.
            var noxIndex = 6.0 + dayPhase * 3.0 + Double.random(in: -3...4)
            if vocIndex > 250 { noxIndex += Double.random(in: 20...90) }
            noxIndex = min(500, max(1, noxIndex))

            // Measured CO2, loosely tracking occupancy.
            let co2 = 430.0 + (vocIndex - 95.0) * 1.6 + dayPhase * 140.0 + Double.random(in: -25...25)

            // Particulate matter: low baselines that rise with the day and spike
            // alongside cooking/cleaning events. PM10 > PM4 > PM2.5 > PM1.0.
            let pmSpike = (vocIndex > 250) ? Double.random(in: 20...60) : 0
            let pm1  = max(0, 5.0  + dayPhase * 4.0 + pmSpike * 0.5 + Double.random(in: -2...2))
            let pm25 = max(0, 9.0  + dayPhase * 6.0 + pmSpike       + Double.random(in: -3...3))
            let pm4  = max(0, 11.5 + dayPhase * 7.0 + pmSpike * 1.2 + Double.random(in: -3...3))
            let pm10 = max(0, 14.0 + dayPhase * 8.0 + pmSpike * 1.4 + Double.random(in: -4...4))

            let classes = AirClasses(
                gas: gasClassFor(vocIndex: vocIndex, noxIndex: noxIndex, co2: co2),
                pm: pmClassFor(pm1: pm1, pm25: pm25, pm10: pm10))
            // Bit 0 SEN66 present · bit 1 fresh · bit 3 CAN online (0x0B), with an
            // occasional sticky-error blip (bit 4). Bit 6 ionizer powered; bit 5
            // ionizer fault ~5% of the time (§1.1).
            let sensorBits: UInt8 = Double.random(in: 0...1) < 0.02 ? 0x1B : 0x0B
            let ionizerPower: UInt8 = 0x40
            let ionizerFault: UInt8 = Double.random(in: 0...1) < 0.05 ? 0x20 : 0x00
            let status: UInt8 = sensorBits | ionizerPower | ionizerFault

            // ~3% of samples carry an invalid sentinel on some field (§3 gaps).
            let gap = Double.random(in: 0...1) < 0.03

            batch.append(HistoryRecordFields(
                timestamp:    t,
                temperatureC: gap && Bool.random() ? nil : round(temp * 100) / 100,
                humidityPct:  gap && Bool.random() ? nil : round(humidity * 100) / 100,
                vocIndex:     gap ? nil : round(vocIndex * 10) / 10,
                noxIndex:     gap && Bool.random() ? nil : round(noxIndex * 10) / 10,
                co2Ppm:       gap && Bool.random() ? nil : co2.rounded(),
                pm1:          gap && Bool.random() ? nil : round(pm1 * 10) / 10,
                pm25:         gap ? nil : round(pm25 * 10) / 10,
                pm4:          gap && Bool.random() ? nil : round(pm4 * 10) / 10,
                pm10:         gap && Bool.random() ? nil : round(pm10 * 10) / 10,
                classes:      gap ? .unknown : classes,
                status:       status,
                sequence:     sequence
            ))
            sequence = sequence &+ 1   // wraps at 65535, like the firmware counter

            if batch.count >= 1_000 {
                _ = try? await dataStore.insertBatch(batch, deviceID: Self.deviceID, dedupe: false)
                batch.removeAll(keepingCapacity: true)
                onProgress?(Double(i + 1) / Double(totalSamples))
            }
        }
        if !batch.isEmpty {
            _ = try? await dataStore.insertBatch(batch, deviceID: Self.deviceID, dedupe: false)
        }
    }

    /// Stands in for the firmware's worst-of-three gas class, using the
    /// thresholds-v3 default edges, so the synthetic series looks believable. Like
    /// firmware, VOC and NOx are compared as whole index values. The real edges
    /// are user-editable on the device; nothing outside this mock derives a class
    /// from raw values.
    private func gasClassFor(vocIndex: Double, noxIndex: Double, co2: Double) -> UInt8 {
        func vocBand(_ v: Double) -> Int {
            switch v {
            case ...100: 1
            case ...150: 2
            case ...250: 3
            case ...350: 4
            default:     5
            }
        }
        func noxBand(_ v: Double) -> Int {
            switch v {
            case ...20:  1
            case ...50:  2
            case ...100: 3
            case ...200: 4
            default:     5
            }
        }
        func co2Band(_ v: Double) -> Int {
            switch v {
            case ...800:  1
            case ...1000: 2
            case ...1500: 3
            case ...2000: 4
            default:      5
            }
        }
        return UInt8(max(vocBand(vocIndex.rounded(.towardZero)),
                         noxBand(noxIndex.rounded(.towardZero)),
                         co2Band(co2)))
    }

    /// Stands in for the firmware's worst-of-three PM class at the default
    /// edges: ≤ attention → 1 good, ≤ hazard → 2 attention, else 3 hazard.
    /// PM4.0 is never classified.
    private func pmClassFor(pm1: Double, pm25: Double, pm10: Double) -> UInt8 {
        func band(_ v: Double, attention: Double, hazard: Double) -> Int {
            v <= attention ? 1 : v <= hazard ? 2 : 3
        }
        return UInt8(max(band(pm1,  attention: 7.0,  hazard: 25.0),
                         band(pm25, attention: 9.0,  hazard: 35.0),
                         band(pm10, attention: 45.0, hazard: 150.0)))
    }
}
