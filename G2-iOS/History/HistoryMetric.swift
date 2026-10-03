//
//  HistoryMetric.swift
//  G2-iOS
//
//  Selectable chart series and time ranges for the history view (§3).
//
//  v2 note: eight metrics now, up from six — TVOC/eCO₂ are gone and VOC index,
//  NOx index, CO₂ and PM4.0 take their place. Eight items no longer fit a
//  segmented control, so the picker uses `.menu` (§9.2). The air-quality class
//  stays out of the chart; it lives in the row dot and the drill-down.
//

import SwiftUI

/// Metric the chart plots. `tempHumidity` is a dual-axis overlay (temperature °C on
/// the left axis, humidity % on the right); the rest are single series.
enum HistoryMetric: String, CaseIterable, Identifiable, Sendable {
    case tempHumidity, vocIndex, noxIndex, co2, pm1, pm25, pm4, pm10
    var id: String { rawValue }

    /// Compact label for the picker.
    var title: String {
        switch self {
        case .tempHumidity: "Temp/RH"
        case .vocIndex:     "VOC index"
        case .noxIndex:     "NOx index"
        case .co2:          "CO₂"
        case .pm1:          "PM1.0"
        case .pm25:         "PM2.5"
        case .pm4:          "PM4.0"
        case .pm10:         "PM10"
        }
    }

    var unit: String {
        switch self {
        case .tempHumidity:            "°C · %"
        case .vocIndex, .noxIndex:     "index"
        case .co2:                     "ppm"
        case .pm1, .pm25, .pm4, .pm10: "µg/m³"
        }
    }

    /// Fractional digits for value labels — the index and PM series carry one
    /// decimal on the wire (×10), CO₂ is whole ppm.
    var decimals: Int {
        switch self {
        case .co2: 0
        default:   1
        }
    }

    /// True for the dual-axis Temp/Humidity overlay, which the chart renders via a
    /// dedicated path instead of the single-series `seriesKind`.
    var isOverlay: Bool { self == .tempHumidity }

    var tint: Color {
        switch self {
        case .tempHumidity: Theme.accentWarm
        case .vocIndex:     Theme.accentViolet
        case .noxIndex:     Theme.accentCool
        case .co2:          Theme.accentTeal
        case .pm1:          Theme.aqiExcellent   // matches Dashboard PM row colors
        case .pm25:         Theme.aqiGood
        case .pm4:          Theme.aqiModerate
        case .pm10:         Theme.aqiPoor
        }
    }

    /// The aggregation series this metric plots (nil for `tempHumidity`, which is
    /// a dual-axis overlay of the `.temperature` and `.humidity` series).
    var seriesKind: HistorySeriesKind? {
        switch self {
        case .tempHumidity: nil
        case .vocIndex:     .vocIndex
        case .noxIndex:     .noxIndex
        case .co2:          .co2
        case .pm1:          .pm1
        case .pm25:         .pm25
        case .pm4:          .pm4
        case .pm10:         .pm10
        }
    }
}

/// Chart/list time window. 60 d is the product target (§3).
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

    /// Aggregation bucket width that keeps charts readable/performant (§3).
    var bucket: TimeInterval {
        switch self {
        case .day:       15 * 60        // raw 15-min resolution → ~96 points
        case .week:      60 * 60        // hourly → 168 points
        case .month:     6 * 60 * 60    // 6-hourly → 120 points
        case .sixtyDays: 12 * 60 * 60   // 12-hourly → 120 points
        }
    }
}

/// One aggregated point on the time-series chart. A plain value type so series
/// can cross the HistoryDataStore actor boundary.
struct ChartPoint: Identifiable, Sendable {
    let id = UUID()
    let date: Date
    let value: Double
}
