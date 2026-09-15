//
//  DashboardView.swift
//  G2-iOS
//
//  Live air-quality metrics (§4). The derived air-quality class is the visual
//  anchor; every metric renders "—" for its sentinel; freshness combines the
//  device's own "fresh this tick" flag (status bit 1) with packet age. Malformed
//  packets surface non-fatally (§7).
//
//  The full SEN66 surface — number concentrations, raw/uncompensated values,
//  sensor identity, device state and the device status register — lives behind a
//  "Sensor detail" disclosure that starts collapsed (§4).
//

import SwiftUI

struct DashboardView: View {
    @Environment(BluetoothManager.self) private var bluetooth

    /// Collapsed by default (§4); the state persists for the session.
    @State private var showSensorDetail = false

    // Staleness thresholds relative to the 2 s notify cadence (§4).
    private let liveWindow: TimeInterval = 3
    private let staleWindow: TimeInterval = 6

    var body: some View {
        ScrollView {
            // TimelineView gives a ticking clock so freshness updates even between packets.
            TimelineView(.periodic(from: .now, by: 1)) { context in
                VStack(spacing: Theme.spacing) {
                    if let info = bluetooth.unsupportedContract {
                        unsupportedContractState(info)
                    } else if let reading = bluetooth.latestReading {
                        freshness(for: reading, now: context.date)
                        if bluetooth.sensorDisconnected {
                            sensorDisconnectedBanner
                        }
                        if let parseError = bluetooth.lastParseError {
                            parseErrorBanner(parseError)
                        }
                        aqHero(reading)
                        metricGrid(reading)
                        fanCard(reading)
                        sensorDetail(reading)
                        sequenceFooter(reading)
                    } else {
                        waitingState
                    }
                }
                .padding(Theme.spacing)
            }
        }
    }

    // MARK: - Freshness (§4)

    private func freshness(for reading: SensorReading, now: Date) -> some View {
        let age = now.timeIntervalSince(reading.receivedAt)
        // Two independent signals: packets still arriving, and the device saying
        // this tick carried a freshly measured sample rather than a cached repeat.
        let isRecent = age <= liveWindow
        let isStale = age > staleWindow
        let isLive = isRecent && reading.status.isFresh
        return HStack(spacing: 8) {
            Circle()
                .fill(isStale ? Theme.aqiPoor : isLive ? Theme.aqiExcellent : Theme.aqiModerate)
                .frame(width: 8, height: 8)
                .symbolEffect(.pulse, isActive: isLive)
                .opacity(isLive ? 1 : 0.6)
            Text(freshnessText(age: age, reading: reading, isRecent: isRecent, isStale: isStale))
                .font(.caption.weight(.medium))
                .foregroundStyle(isStale ? Theme.aqiPoor : Theme.textSecondary)
            Spacer()
            Button {
                bluetooth.refreshNow()   // 0x09 GET_STATUS (§1.6)
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
                    .font(.caption.weight(.semibold))
            }
            .tint(Theme.accent)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func freshnessText(age: TimeInterval, reading: SensorReading,
                               isRecent: Bool, isStale: Bool) -> String {
        if isStale { return "Stale — no update for \(Int(age))s" }
        if !isRecent { return "Updated \(Int(age))s ago" }
        // Packets are arriving; bit 1 says whether the sample behind them is new.
        return reading.status.isFresh ? "Live" : "Live — repeating last sample"
    }

    // MARK: - Air-quality hero (§4 — visual anchor)

    private func aqHero(_ reading: SensorReading) -> some View {
        let aq = reading.aqClass
        return VStack(spacing: 6) {
            Text("AIR QUALITY")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.textSecondary)
            Text(aq.isValid ? "\(aq.rawValue)" : "—")
                .font(.system(size: 72, weight: .bold, design: .rounded))
                .foregroundStyle(aq.color)
                .contentTransition(.numericText())
            Text(reading.aqClassLabel)
                .font(.title3.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
            if reading.isWarmingUp {
                Label("Sensor is warming up — readings settle over the first minute.",
                      systemImage: "hourglass")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, Theme.spacing)
            } else {
                Text("Air-quality class · 1 (excellent) – 5 (unhealthy)")
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .background(aq.color.opacity(0.14),
                    in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
                .strokeBorder(aq.color.opacity(0.4), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "Air quality class \(aq.isValid ? "\(aq.rawValue), \(reading.aqClassLabel)" : reading.aqClassLabel)")
    }

    // MARK: - Metric grid (§4)

    private func metricGrid(_ reading: SensorReading) -> some View {
        let columns = [GridItem(.flexible(), spacing: Theme.spacing),
                       GridItem(.flexible(), spacing: Theme.spacing)]
        return LazyVGrid(columns: columns, spacing: Theme.spacing) {
            MetricCard(icon: "thermometer.medium", title: "Temperature",
                       value: reading.temperatureC.formatted(decimals: 1), unit: "°C", tint: Theme.accentWarm)
            MetricCard(icon: "humidity.fill", title: "Humidity",
                       value: reading.humidityPct.formatted(decimals: 1), unit: "%", tint: Theme.accentCool)
            MetricCard(icon: "aqi.medium", title: "VOC index",
                       value: reading.vocIndex.formatted(decimals: 1), unit: "", tint: Theme.accentViolet)
            MetricCard(icon: "wind", title: "NOx index",
                       value: reading.noxIndex.formatted(decimals: 1), unit: "", tint: Theme.accentCool)
            MetricCard(icon: "carbon.dioxide.cloud.fill", title: "CO₂",
                       value: reading.co2Ppm.formatted, unit: "ppm", tint: Theme.accentTeal)
            MetricCard(icon: "aqi.low", title: "PM1.0",
                       value: reading.pm1.formatted(decimals: 1), unit: "µg/m³", tint: Theme.aqiExcellent)
            MetricCard(icon: "aqi.low", title: "PM2.5",
                       value: reading.pm25.formatted(decimals: 1), unit: "µg/m³", tint: Theme.aqiGood)
            MetricCard(icon: "aqi.medium", title: "PM4.0",
                       value: reading.pm4.formatted(decimals: 1), unit: "µg/m³", tint: Theme.aqiModerate)
            MetricCard(icon: "aqi.high", title: "PM10",
                       value: reading.pm10.formatted(decimals: 1), unit: "µg/m³", tint: Theme.aqiPoor)
        }
    }

    private func fanCard(_ reading: SensorReading) -> some View {
        HStack {
            Label("Fan", systemImage: "fan.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
            if let mode = reading.fanMode {
                Text(mode.title)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Theme.surfaceHi, in: Capsule())
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            Text("\(reading.fanSpeedPct)%")
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.accent)
                .contentTransition(.numericText())
        }
        .card()
    }

    // MARK: - Sensor detail (§4 — collapsed by default)

    private func sensorDetail(_ reading: SensorReading) -> some View {
        DisclosureGroup(isExpanded: $showSensorDetail) {
            VStack(alignment: .leading, spacing: 14) {
                detailSection("NUMBER CONCENTRATION") {
                    detailRow("NC0.5", reading.nc05.formatted(decimals: 1), "#/cm³")
                    detailRow("NC1.0", reading.nc1.formatted(decimals: 1), "#/cm³")
                    detailRow("NC2.5", reading.nc25.formatted(decimals: 1), "#/cm³")
                    detailRow("NC4.0", reading.nc4.formatted(decimals: 1), "#/cm³")
                    detailRow("NC10", reading.nc10.formatted(decimals: 1), "#/cm³")
                }

                detailSection("RAW / UNCOMPENSATED") {
                    detailRow("VOC ticks", reading.rawVOCTicks.formatted, "")
                    detailRow("NOx ticks", reading.rawNOxTicks.formatted, "")
                    detailRow("CO₂ raw", reading.rawCO2Ppm.formatted, "ppm")
                    detailRow("Humidity raw", reading.rawHumidityPct.formatted(decimals: 2), "%")
                    detailRow("Temperature raw", reading.rawTemperatureC.formatted(decimals: 2), "°C")
                }

                detailSection("SENSOR") {
                    detailRow("Serial", bluetooth.deviceInfo?.serialText ?? "—", "")
                    detailRow("SEN66 firmware", bluetooth.deviceInfo?.firmwareVersionText ?? "—", "")
                    detailRow("Device state", reading.deviceState?.label ?? "—", "")
                }

                sen66StatusSection(reading.sen66Status)
            }
            .padding(.top, 12)
        } label: {
            Label("Sensor detail", systemImage: "list.bullet.rectangle")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
        }
        .tint(Theme.accent)
        .card()
    }

    @ViewBuilder
    private func detailSection(_ title: String, @ViewBuilder rows: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(Theme.textSecondary)
            rows()
        }
    }

    private func detailRow(_ label: String, _ value: String, _ unit: String) -> some View {
        HStack {
            Text(label).font(.subheadline).foregroundStyle(Theme.textSecondary)
            Spacer()
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(Theme.textPrimary)
                if !unit.isEmpty {
                    Text(unit).font(.caption2).foregroundStyle(Theme.textSecondary)
                }
            }
        }
    }

    /// SEN66 device status register (§4). The fan-speed warning is advisory and
    /// gets its own yellow treatment; the five error bits read as faults.
    private func sen66StatusSection(_ status: SEN66Status) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("SEN66 STATUS").font(.caption.weight(.semibold)).foregroundStyle(Theme.textSecondary)
                Spacer()
                Text(status.hexDescription)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(Theme.textSecondary)
            }
            if status.isClean {
                Label("No faults reported", systemImage: "checkmark.circle.fill")
                    .font(.subheadline)
                    .foregroundStyle(Theme.aqiExcellent)
            } else {
                ForEach(status.activeIndicators) { indicator in
                    SEN66StatusRow(indicator: indicator, isWarningOnly: indicator.bit == 21)
                }
            }
        }
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

    /// Status bit 0 clear: the SEN66 is not responding, so every field below is
    /// a sentinel. Say "disconnected" rather than showing a screen of dashes as
    /// though they were readings (notes §2).
    private var sensorDisconnectedBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Sensor disconnected", systemImage: "sensor.tag.radiowaves.forward.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.aqiUnhealthy)
            Text("The monitor is connected but reports no SEN66 sensor. "
                 + "Every reading below is unavailable until the sensor responds.")
                .font(.footnote)
                .foregroundStyle(Theme.textPrimary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.spacing)
        .background(Theme.aqiUnhealthy.opacity(0.14),
                    in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
                .strokeBorder(Theme.aqiUnhealthy.opacity(0.45), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
    }

    /// The device speaks a contract this build does not implement. Readings are
    /// refused rather than decoded into plausible-looking numbers — reported, not
    /// worked around (§9.3 / notes §7).
    private func unsupportedContractState(_ info: DeviceInfo) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.octagon.fill")
                .font(.system(size: 44))
                .foregroundStyle(Theme.aqiUnhealthy)
            Text("Incompatible monitor firmware")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            Text("This monitor reports GATT contract v\(info.contractVersion) and log record "
                 + "v\(info.logRecordVersion). This app implements contract v\(GATT.contractVersion) "
                 + "and record v\(GATT.historyRecordVersion).")
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
            Text("Readings are not shown, because decoding a different contract would "
                 + "produce numbers that look right and are not. Update the monitor firmware "
                 + "or this app so the versions match, and report the mismatch.")
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .padding(.horizontal, Theme.spacing)
        .background(Theme.aqiUnhealthy.opacity(0.10),
                    in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
                .strokeBorder(Theme.aqiUnhealthy.opacity(0.45), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
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

/// One SEN66 device-status flag. The fan-speed warning is a yellow advisory row;
/// the datasheet's five error bits read as red faults (§4 / §6).
struct SEN66StatusRow: View {
    let indicator: StatusIndicator
    let isWarningOnly: Bool

    private var tint: Color { isWarningOnly ? Theme.aqiModerate : Theme.aqiUnhealthy }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isWarningOnly ? "exclamationmark.triangle.fill" : "xmark.octagon.fill")
                .foregroundStyle(tint)
            Text(indicator.label)
                .font(.subheadline)
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            Text("bit \(indicator.bit)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(Theme.textSecondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(indicator.label), \(isWarningOnly ? "warning" : "error")")
    }
}

/// A single live metric cell (§4). Renders "—" for an invalid/sentinel value.
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
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                    .contentTransition(.numericText())
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                if !unit.isEmpty {
                    Text(unit).font(.subheadline).foregroundStyle(Theme.textSecondary)
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 96, alignment: .leading)
        .card()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(value == "—" ? "unavailable" : "\(value) \(unit)")")
    }
}
