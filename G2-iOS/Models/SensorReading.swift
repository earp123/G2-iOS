//
//  SensorReading.swift
//  G2-iOS
//
//  A fully decoded live sensor packet — contract v3, 52 bytes (§1.1). Every field
//  that carries an invalid sentinel is surfaced as `Metric.invalid`, never as a
//  real number.
//
//  Units are **display units**: the ×10 and ×100 wire scalings are undone by the
//  parser, so nothing downstream re-scales (§2). CO₂ and the raw tick counts are
//  unscaled integers on the wire and stay `Metric<Int>`; the raw RH/T fields are
//  scaled (×100 / ×200) and so are descaled into their natural units even though
//  they remain uncompensated, sensor-native values.
//

import Foundation

/// One decoded reading from the Sensor Data characteristic (§1.1).
struct SensorReading: Equatable, Sendable {

    // MARK: - Compensated measurements (display units)

    var temperatureC: Metric<Double>   // °C            (i16 ×100, sentinel INT16_MIN)
    var humidityPct: Metric<Double>    // %             (u16 ×100, sentinel 0xFFFF)
    var vocIndex: Metric<Double>       // index 1.0–500.0 (u16 ×10)
    var noxIndex: Metric<Double>       // index 1.0–500.0 (u16 ×10)
    var co2Ppm: Metric<Int>            // ppm           (u16, unscaled)
    var pm1: Metric<Double>            // µg/m³         (u16 ×10, sentinels 0xFFFF/0xFFFE)
    var pm25: Metric<Double>
    var pm4: Metric<Double>
    var pm10: Metric<Double>

    // MARK: - Number concentrations (sensor detail, §4)

    var nc05: Metric<Double>           // #/cm³         (u16 ×10)
    var nc1: Metric<Double>
    var nc25: Metric<Double>
    var nc4: Metric<Double>
    var nc10: Metric<Double>

    // MARK: - Raw, uncompensated values (sensor detail, §4)

    var rawVOCTicks: Metric<Int>       // raw VOC ticks   (u16, unscaled)
    var rawNOxTicks: Metric<Int>       // raw NOx ticks   (u16, unscaled)
    var rawCO2Ppm: Metric<Int>         // ppm, 5 s cadence (u16, unscaled)
    var rawHumidityPct: Metric<Double> // %, uncompensated (i16 ×100)
    var rawTemperatureC: Metric<Double>// °C, uncompensated (i16 ×200)

    // MARK: - State

    /// Byte 32 — packed gas (low nibble) and PM (high nibble) classes, both
    /// derived by firmware from the user-editable edges (thresholds-v3 §1.1).
    var classes: AirClasses
    var fanSpeedPct: Int               // byte 33, 0–100
    /// Byte 34 — the device's own fan mode. `nil` for an undefined value; the
    /// Conditioning picker mirrors this rather than holding local state (§5).
    var fanMode: FanMode?
    var status: DeviceStatus           // byte 35 bitfield
    var sen66Status: SEN66Status       // bytes 36–39, datasheet §4.3
    /// Byte 50. `nil` for an undefined value.
    var deviceState: DeviceState?
    var sequence: UInt16               // bytes 2–3, wraps at 65535

    /// Wall-clock time this reading was received by the client.
    var receivedAt: Date

    /// True when the device says the SEN66 has not finished warming up — the
    /// only context in which a `0` class reads as "Warming up" (§2).
    var isWarmingUp: Bool { status.sen66Warming }

    /// Gas class 0–5 — drives the gas tile (§1.1).
    var gasLevel: AQILevel { AQILevel(raw: classes.gas) }
    /// PM class 0–3 — drives the PM tile (§1.1).
    var pmLevel: PMLevel { PMLevel(raw: classes.pm) }

    /// Gas-class label with the warming-up context applied (§2).
    var gasClassLabel: String { gasLevel.label(isWarming: isWarmingUp) }
    /// PM-class label with the warming-up context applied (§2).
    var pmClassLabel: String { pmLevel.label(isWarming: isWarmingUp) }
}
