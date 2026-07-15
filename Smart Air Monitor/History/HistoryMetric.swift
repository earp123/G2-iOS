//
//  HistoryMetric.swift
//  Smart Air Monitor
//
//  Selectable chart series and time ranges for the history view (§4.2).
//

import SwiftUI

/// Metric the chart plots. PM is present but intentionally "not logged" — it is
/// absent from the 16-byte flash record, so we say so rather than faking it (§4.2).
enum HistoryMetric: String, CaseIterable, Identifiable, Sendable {
    case temperature, humidity, tvoc, eco2, aqi, pm
    var id: String { rawValue }

    var title: String {
        switch self {
        case .temperature: "Temp"
        case .humidity:    "Humidity"
        case .tvoc:        "TVOC"
        case .eco2:        "eCO₂"
        case .aqi:         "AQI"
        case .pm:          "PM"
        }
    }

    var unit: String {
        switch self {
        case .temperature: "°C"
        case .humidity:    "%"
        case .tvoc:        "ppb"
        case .eco2:        "ppm"
        case .aqi:         "UBA"
        case .pm:          "µg/m³"
        }
    }

    /// PM is not logged in the flash record (§4.2).
    var isLogged: Bool { self != .pm }

    var tint: Color {
        switch self {
        case .temperature: Theme.accentWarm
        case .humidity:    Theme.accentCool
        case .tvoc:        Theme.accentViolet
        case .eco2:        Theme.accentTeal
        case .aqi:         Theme.accent
        case .pm:          Theme.textSecondary
        }
    }

    /// Extracts this metric's value from a record (nil if sentinel / not logged).
    func value(from record: HistoryRecord) -> Double? {
        switch self {
        case .temperature: record.temperatureC
        case .humidity:    record.humidityPct
        case .tvoc:        record.tvocPpb.map(Double.init)
        case .eco2:        record.eco2Ppm.map(Double.init)
        case .aqi:         record.aqi == 0 ? nil : Double(record.aqi)
        case .pm:          nil
        }
    }
}

/// Chart/list time window. 60 d is the product target (§4.2).
enum HistoryRange: String, CaseIterable, Identifiable, Sendable {
    case day = "24h"
    case week = "7d"
    case month = "30d"
    case sixtyDays = "60d"
    var id: String { rawValue }

    var duration: TimeInterval {
        switch self {
        case .day:       86_400
        case .week:      7 * 86_400
        case .month:     30 * 86_400
        case .sixtyDays: 60 * 86_400
        }
    }

    /// Aggregation bucket width that keeps charts readable/performant (§4.2).
    var bucket: TimeInterval {
        switch self {
        case .day:       15 * 60        // raw 15-min resolution → ~96 points
        case .week:      60 * 60        // hourly → 168 points
        case .month:     6 * 60 * 60    // 6-hourly → 120 points
        case .sixtyDays: 12 * 60 * 60   // 12-hourly → 120 points
        }
    }
}

/// One aggregated point on the time-series chart.
struct ChartPoint: Identifiable {
    let id = UUID()
    let date: Date
    let value: Double
}
