//
//  DashboardView.swift
//  Smart Air Monitor
//
//  Live air-quality metrics (§6.1). AQI is the visual anchor; every metric renders
//  "—" for its sentinel; a freshness cue tracks the 2 s notify cadence with a stale
//  treatment when updates stop. Malformed packets surface non-fatally (§7).
//

import SwiftUI

struct DashboardView: View {
    @Environment(BluetoothManager.self) private var bluetooth

    // Staleness thresholds relative to the 2 s notify cadence (§6.1).
    private let liveWindow: TimeInterval = 3
    private let staleWindow: TimeInterval = 6

    var body: some View {
        ScrollView {
            // TimelineView gives a ticking clock so freshness updates even between packets.
            TimelineView(.periodic(from: .now, by: 1)) { context in
                VStack(spacing: Theme.spacing) {
                    if let reading = bluetooth.latestReading {
                        freshness(for: reading, now: context.date)
                        if let parseError = bluetooth.lastParseError {
                            parseErrorBanner(parseError)
                        }
                        aqiHero(reading.aqi)
                        metricGrid(reading)
                        particulateMatter(reading)
                        fanCard(reading)
                        sequenceFooter(reading)
                    } else {
                        waitingState
                    }
                }
                .padding(Theme.spacing)
            }
        }
    }

    // MARK: - Freshness (§6.1)

    private func freshness(for reading: SensorReading, now: Date) -> some View {
        let age = now.timeIntervalSince(reading.receivedAt)
        let isLive = age <= liveWindow
        let isStale = age > staleWindow
        return HStack(spacing: 8) {
            Circle()
                .fill(isStale ? Theme.aqiPoor : Theme.aqiExcellent)
                .frame(width: 8, height: 8)
                .symbolEffect(.pulse, isActive: isLive)
                .opacity(isLive ? 1 : 0.6)
            Text(freshnessText(age: age, isLive: isLive, isStale: isStale))
                .font(.caption.weight(.medium))
                .foregroundStyle(isStale ? Theme.aqiPoor : Theme.textSecondary)
            Spacer()
            Button {
                bluetooth.refreshNow()   // 0x09 GET_STATUS (§6.2)
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
                    .font(.caption.weight(.semibold))
            }
            .tint(Theme.accent)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func freshnessText(age: TimeInterval, isLive: Bool, isStale: Bool) -> String {
        if isLive { return "Live" }
        if isStale { return "Stale — no update for \(Int(age))s" }
        return "Updated \(Int(age))s ago"
    }

    // MARK: - AQI hero (§6.1 — visual anchor)

    private func aqiHero(_ aqi: AQILevel) -> some View {
        VStack(spacing: 6) {
            Text("AIR QUALITY")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.textSecondary)
            Text(aqi.isValid ? "\(aqi.rawValue)" : "—")
                .font(.system(size: 72, weight: .bold, design: .rounded))
                .foregroundStyle(aqi.color)
                .contentTransition(.numericText())
            Text(aqi.label)
                .font(.title3.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
            Text("UBA index · 1 (excellent) – 5 (unhealthy)")
                .font(.caption2)
                .foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .background(aqi.color.opacity(0.14),
                    in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
                .strokeBorder(aqi.color.opacity(0.4), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Air quality index \(aqi.isValid ? "\(aqi.rawValue), \(aqi.label)" : "warming up")")
    }

    // MARK: - Metric grid (§6.1)

    private func metricGrid(_ reading: SensorReading) -> some View {
        let columns = [GridItem(.flexible(), spacing: Theme.spacing),
                       GridItem(.flexible(), spacing: Theme.spacing)]
        return LazyVGrid(columns: columns, spacing: Theme.spacing) {
            MetricCard(icon: "thermometer.medium", title: "Temperature",
                       value: reading.temperatureC.formatted(decimals: 1), unit: "°C", tint: Theme.accentWarm)
            MetricCard(icon: "humidity.fill", title: "Humidity",
                       value: reading.humidityPct.formatted(decimals: 1), unit: "%", tint: Theme.accentCool)
            MetricCard(icon: "aqi.medium", title: "TVOC",
                       value: reading.tvocPpb.formatted, unit: "ppb", tint: Theme.accentViolet)
            MetricCard(icon: "carbon.dioxide.cloud.fill", title: "eCO₂",
                       value: reading.eco2Ppm.formatted, unit: "ppm", tint: Theme.accentTeal)
        }
    }

    // Particulate matter card (PM1.0 / PM2.5 / PM10) (§6.1).
    private func particulateMatter(_ reading: SensorReading) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Particulate Matter", systemImage: "aqi.low")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
            pmRow("PM1.0", reading.pm1, Theme.aqiExcellent)
            Divider().overlay(Theme.hairline)
            pmRow("PM2.5", reading.pm25, Theme.aqiModerate)
            Divider().overlay(Theme.hairline)
            pmRow("PM10", reading.pm10, Theme.aqiPoor)
        }
        .card()
    }

    private func pmRow(_ label: String, _ metric: Metric<Int>, _ color: Color) -> some View {
        HStack {
            Circle().fill(color).frame(width: 9, height: 9)
            Text(label).font(.subheadline).foregroundStyle(Theme.textSecondary)
            Spacer()
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(metric.formatted)
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                    .contentTransition(.numericText())
                Text("µg/m³").font(.caption2).foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private func fanCard(_ reading: SensorReading) -> some View {
        HStack {
            Label("Fan", systemImage: "fan.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            Text("\(reading.fanSpeedPct)%")
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.accent)
                .contentTransition(.numericText())
        }
        .card()
    }

    private func sequenceFooter(_ reading: SensorReading) -> some View {
        Text("Packet sequence #\(reading.sequence)")
            .font(.caption2)
            .foregroundStyle(Theme.textSecondary)
            .frame(maxWidth: .infinity)
    }

    // MARK: - States

    private func parseErrorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.aqiModerate)
            Text("\(message). Showing last good values.")
                .font(.caption)
                .foregroundStyle(Theme.textPrimary)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Theme.aqiModerate.opacity(0.14),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var waitingState: some View {
        VStack(spacing: 12) {
            ProgressView().tint(Theme.accent)
            Text("Waiting for first reading…")
                .font(.headline).foregroundStyle(Theme.textPrimary)
            Text("The monitor sends a packet every 2 seconds.")
                .font(.subheadline).foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }
}

/// A single live metric cell (§6.1). Renders "—" for an invalid/sentinel value.
struct MetricCard: View {
    let icon: String
    let title: String
    let value: String
    let unit: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(tint)
                .labelStyle(.titleAndIcon)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                    .contentTransition(.numericText())
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(unit).font(.subheadline).foregroundStyle(Theme.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 96, alignment: .leading)
        .card()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(value == "—" ? "unavailable" : "\(value) \(unit)")")
    }
}
