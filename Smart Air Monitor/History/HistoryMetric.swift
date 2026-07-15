//
//  HistoryMetric.swift
//  Smart Air Monitor
//
//  Selectable chart series and time ranges for the history view (§4.2).
//

import SwiftUI

/// Metric the chart plots. `tempHumidity` is a dual-axis overlay (temperature °C on
/// the left axis, humidity % on the right); the rest are single series. PM1.0/PM2.5/
/// PM10 are logged in the flash record since firmware 2026-07-09 (§4.2).
enum HistoryMetric: String, CaseIterable, Identifiable, Sendable {
    case tempHumidity, tvoc, eco2, pm1, pm25, pm10
    var id: String { rawValue }

    /// Compact label for the segmented picker.
    var title: String {
        switch self {
        case .tempHumidity: "Temp/RH"
        case .tvoc:         "TVOC"
        case .eco2:         "eCO₂"
        case .pm1:          "PM1.0"
        case .pm25:         "PM2.5"
        case .pm10:         "PM10"
        }
    }

    var unit: String {
        switch self {
        case .tempHumidity: "°C · %"
        case .tvoc:         "ppb"
        case .eco2:         "ppm"
        case .pm1, .pm25, .pm10: "µg/m³"
        }
    }

    /// True for the dual-axis Temp/Humidity overlay, which the chart renders via a
    /// dedicated path instead of the single-series `value(from:)`.
    var isOverlay: Bool { self == .tempHumidity }

    var tint: Color {
        switch self {
        case .tempHumidity: Theme.accentWarm
        case .tvoc:         Theme.accentViolet
        case .eco2:         Theme.accentTeal
        case .pm1:          Theme.aqiExcellent   // matches Dashboard PM row colors
        case .pm25:         Theme.aqiModerate
        case .pm10:         Theme.aqiPoor
        }
    }

    /// Extracts this single-series metric's value from a record (nil if sentinel /
    /// not present). Not used for `tempHumidity` — see `HistoryStore` series.
    func value(from record: HistoryRecord) -> Double? {
        switch self {
        case .tempHumidity: nil
        case .tvoc:         record.tvocPpb.map(Double.init)
        case .eco2:         record.eco2Ppm.map(Double.init)
        case .pm1:          record.pm1.map(Double.init)
        case .pm25:         record.pm25.map(Double.init)
        case .pm10:         record.pm10.map(Double.init)
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
