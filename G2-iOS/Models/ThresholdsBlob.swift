//
//  ThresholdsBlob.swift
//  G2-iOS
//
//  The Thresholds characteristic `7A3E4F61-…` — 60 bytes, READ + WRITE, new in
//  contract v3 (firmware thresholds-v3 §2.2). Every adjustable band, fan table,
//  timer and hysteresis the device uses, read once on connect and written whole:
//
//    [0]      version u8 (must be 1)       [1]      reserved u8 (write 0)
//    [2–9]    VOC  C1..C4 4 × u16 index     [10–17]  NOx C1..C4 4 × u16 index
//    [18–25]  CO2  C1..C4 4 × u16 ppm
//    [26–37]  PM1 / PM2.5 / PM10 attention, hazard — 6 × u16 µg/m³ ×10
//    [38–42]  fan % for gas class 1..5      [43–45]  fan % for PM class 1..3
//    [46–47]  fan-down delay u16 s          [48–49]  ionizer run-on u16 min
//    [50–55]  hysteresis VOC / NOx / CO2 3 × u16 (row units)
//    [56–57]  PM hysteresis u16 ×10         [58–59]  reserved u16 (write 0)
//
//  Firmware validates the whole blob and rejects a write with an ATT error if any
//  rule fails — nothing is applied. `validate()` runs the same rules, in the
//  same order, so the user sees which field is wrong before a write is ever
//  attempted. It is exactly as strict as firmware and no stricter: a blob the
//  device holds always validates here (thresholds-v3 §4 item 6).
//
//  Values are kept in **wire units** — PM fields stay µg/m³ ×10 — so the struct
//  packs byte for byte; the editor does the ÷10 for display.
//

import Foundation

/// The 60-byte Thresholds blob (§2.2), in wire units.
///
/// `nonisolated` — a pure wire codec like `GATT`, usable from any context.
nonisolated struct ThresholdsBlob: Equatable, Sendable {

    var version: UInt8
    /// C1…C4 per gas, strictly increasing. Class = 1 at or below C1, … 5 above C4.
    var vocEdges: [UInt16]
    var noxEdges: [UInt16]
    var co2Edges: [UInt16]
    /// PM edges, µg/m³ ×10. Class = 1 at or below attention, 2 at or below hazard, else 3.
    var pm1Attention: UInt16
    var pm1Hazard: UInt16
    var pm25Attention: UInt16
    var pm25Hazard: UInt16
    var pm10Attention: UInt16
    var pm10Hazard: UInt16
    /// Fan % for gas class 1…5 and PM class 1…3. Auto runs the higher of the two.
    var fanGas: [UInt8]
    var fanPM: [UInt8]
    var fanDownDelaySeconds: UInt16
    var ionizerRunOnMinutes: UInt16
    /// Falling-edge hysteresis per gas, in that row's units.
    var hysteresisVOC: UInt16
    var hysteresisNOx: UInt16
    var hysteresisCO2: UInt16
    /// Shared by the three PM channels, µg/m³ ×10.
    var hysteresisPM: UInt16

    static let gasEdgeCount = 4
    static let gasClassCount = 5
    static let pmClassCount = 3

    /// Firmware defaults (§2.2) — exactly the v2 build's compiled values, so a
    /// unit that never receives a write behaves as it did before v3.
    static let defaults = ThresholdsBlob(
        version: GATT.thresholdsVersion,
        vocEdges: [100, 150, 250, 350],
        noxEdges: [20, 50, 100, 200],
        co2Edges: [800, 1000, 1500, 2000],
        pm1Attention: 70, pm1Hazard: 250,
        pm25Attention: 90, pm25Hazard: 350,
        pm10Attention: 450, pm10Hazard: 1500,
        fanGas: [0, 25, 50, 75, 100],
        fanPM: [20, 50, 100],
        fanDownDelaySeconds: 0,
        ionizerRunOnMinutes: 60,
        hysteresisVOC: 0,
        hysteresisNOx: 0,
        hysteresisCO2: 0,
        hysteresisPM: 0
    )

    // MARK: - Channels

    /// The three gas rows. Each has four edges C1…C4 and its own hysteresis.
    enum GasChannel: CaseIterable, Hashable, Sendable {
        case voc, nox, co2

        var title: String {
            switch self {
            case .voc: "VOC"
            case .nox: "NOx"
            case .co2: "CO₂"
            }
        }

        /// Unit label shown beside the row.
        var unit: String {
            switch self {
            case .voc, .nox: "index"
            case .co2:       "ppm"
            }
        }

        /// The firmware's ceiling for C4 (§2.2).
        var edgeMax: UInt16 {
            switch self {
            case .voc: GATT.thresholdsVOCEdgeMax
            case .nox: GATT.thresholdsNOxEdgeMax
            case .co2: GATT.thresholdsCO2EdgeMax
            }
        }
    }

    /// The three classified PM channels. PM4.0 is reported but never classified.
    enum PMChannel: CaseIterable, Hashable, Sendable {
        case pm1, pm25, pm10

        var title: String {
            switch self {
            case .pm1:  "PM1.0"
            case .pm25: "PM2.5"
            case .pm10: "PM10"
            }
        }
    }

    /// Fixed-length view of a gas row. The arrays are `var` so tests and the
    /// editor can set them directly; every read used by `pack()` and
    /// `validate()` goes through here, so the two always see the same four values.
    func edges(_ channel: GasChannel) -> [UInt16] {
        let raw: [UInt16]
        switch channel {
        case .voc: raw = vocEdges
        case .nox: raw = noxEdges
        case .co2: raw = co2Edges
        }
        return Self.fixedLength(raw, Self.gasEdgeCount)
    }

    func hysteresis(_ channel: GasChannel) -> UInt16 {
        switch channel {
        case .voc: hysteresisVOC
        case .nox: hysteresisNOx
        case .co2: hysteresisCO2
        }
    }

    func attention(_ channel: PMChannel) -> UInt16 {
        switch channel {
        case .pm1:  pm1Attention
        case .pm25: pm25Attention
        case .pm10: pm10Attention
        }
    }

    func hazard(_ channel: PMChannel) -> UInt16 {
        switch channel {
        case .pm1:  pm1Hazard
        case .pm25: pm25Hazard
        case .pm10: pm10Hazard
        }
    }

    /// Fixed-length views of the two fan tables.
    var fanGasTable: [UInt8] { Self.fixedLength(fanGas, Self.gasClassCount) }
    var fanPMTable: [UInt8] { Self.fixedLength(fanPM, Self.pmClassCount) }

    // MARK: - Wire encoding (§2.2)

    /// Serialises the 60-byte little-endian blob for a WRITE. Reserved bytes
    /// (1, 58–59) are always written as zero; nothing else is altered or clamped
    /// — `validate()` is what stands between a bad value and the device.
    func pack() -> Data {
        var b = [UInt8](repeating: 0, count: GATT.thresholdsPayloadLength)
        let o = GATT.ThresholdsOffset.self

        func putU16(_ v: UInt16, _ i: Int) {
            b[i] = UInt8(v & 0x00FF)
            b[i + 1] = UInt8((v >> 8) & 0x00FF)
        }

        b[o.version] = version
        b[o.reserved1] = 0
        for (i, edge) in edges(.voc).enumerated() { putU16(edge, o.vocEdges + 2 * i) }
        for (i, edge) in edges(.nox).enumerated() { putU16(edge, o.noxEdges + 2 * i) }
        for (i, edge) in edges(.co2).enumerated() { putU16(edge, o.co2Edges + 2 * i) }
        putU16(pm1Attention,  o.pm1Attention)
        putU16(pm1Hazard,     o.pm1Hazard)
        putU16(pm25Attention, o.pm25Attention)
        putU16(pm25Hazard,    o.pm25Hazard)
        putU16(pm10Attention, o.pm10Attention)
        putU16(pm10Hazard,    o.pm10Hazard)
        for (i, pct) in fanGasTable.enumerated() { b[o.fanGas + i] = pct }
        for (i, pct) in fanPMTable.enumerated() { b[o.fanPM + i] = pct }
        putU16(fanDownDelaySeconds, o.fanDownDelay)
        putU16(ionizerRunOnMinutes, o.ionizerRunOn)
        putU16(hysteresisVOC, o.hysteresisVOC)
        putU16(hysteresisNOx, o.hysteresisNOx)
        putU16(hysteresisCO2, o.hysteresisCO2)
        putU16(hysteresisPM,  o.hysteresisPM)
        putU16(0, o.reserved58)
        return Data(b)
    }

    /// Decodes a READ. `nil` unless the payload is exactly 60 bytes — firmware
    /// always returns 60, so anything else is a contract break, not something to
    /// decode from its first 60 bytes. Reserved bytes are ignored. The values are
    /// taken as-is, not validated: the editor shows what the device holds.
    static func unpack(_ data: Data) -> ThresholdsBlob? {
        guard data.count == GATT.thresholdsPayloadLength else { return nil }
        // `Data` may be a slice with a non-zero startIndex; normalise first.
        let b = [UInt8](data)
        let o = GATT.ThresholdsOffset.self

        func u16(_ i: Int) -> UInt16 { UInt16(b[i]) | (UInt16(b[i + 1]) << 8) }
        func row(_ start: Int) -> [UInt16] { (0..<Self.gasEdgeCount).map { u16(start + 2 * $0) } }

        return ThresholdsBlob(
            version: b[o.version],
            vocEdges: row(o.vocEdges),
            noxEdges: row(o.noxEdges),
            co2Edges: row(o.co2Edges),
            pm1Attention: u16(o.pm1Attention), pm1Hazard: u16(o.pm1Hazard),
            pm25Attention: u16(o.pm25Attention), pm25Hazard: u16(o.pm25Hazard),
            pm10Attention: u16(o.pm10Attention), pm10Hazard: u16(o.pm10Hazard),
            fanGas: Array(b[o.fanGas ..< o.fanGas + Self.gasClassCount]),
            fanPM: Array(b[o.fanPM ..< o.fanPM + Self.pmClassCount]),
            fanDownDelaySeconds: u16(o.fanDownDelay),
            ionizerRunOnMinutes: u16(o.ionizerRunOn),
            hysteresisVOC: u16(o.hysteresisVOC),
            hysteresisNOx: u16(o.hysteresisNOx),
            hysteresisCO2: u16(o.hysteresisCO2),
            hysteresisPM: u16(o.hysteresisPM)
        )
    }

    // MARK: - Validation (mirrors firmware `thresholds_validate`, §2.2)

    /// One failed firmware rule. `row` says where the editor shows it inline.
    enum ValidationError: Error, Equatable, Hashable, Sendable {
        /// Byte 0 is not 1.
        case unsupportedVersion(UInt8)
        /// C1 < C2 < C3 < C4 does not hold for this gas.
        case edgesNotIncreasing(GasChannel)
        /// C4 is above the gas's ceiling (500 / 500 / 40000).
        case edgeAboveMax(GasChannel, max: UInt16)
        /// Hysteresis is not below the smallest gap between adjacent edges.
        case hysteresisTooLarge(GasChannel, smallestGap: UInt16)
        /// Non-zero hysteresis is not below C1, so class 1 could never return.
        case hysteresisNotBelowFirstEdge(GasChannel, c1: UInt16)
        /// Attention is not below hazard for this PM channel.
        case attentionNotBelowHazard(PMChannel)
        /// PM hysteresis (×10) is not below the narrowest hazard − attention band.
        case pmHysteresisTooLarge(smallestBand: UInt16)
        /// Non-zero PM hysteresis (×10) is not below the smallest attention edge.
        case pmHysteresisNotBelowAttention(smallestAttention: UInt16)
        /// Fan % above 100 for gas class 1…5.
        case fanGasAboveMax(gasClass: Int)
        /// Fan % above 100 for PM class 1…3.
        case fanPMAboveMax(pmClass: Int)
        /// Fan-down delay above 3600 s.
        case fanDownDelayAboveMax
        /// Ionizer run-on above 1440 min.
        case ionizerRunOnAboveMax

        /// Where in the editor the error belongs (thresholds-v3 §3: inline errors
        /// under the offending row).
        enum Row: Hashable, Sendable {
            case version
            case gasEdges(GasChannel)
            case pmEdges(PMChannel)
            case fanGas
            case fanPM
            case fanDownDelay
            case ionizerRunOn
            case hysteresis(GasChannel)
            case hysteresisPM
        }

        var row: Row {
            switch self {
            case .unsupportedVersion:                 .version
            case .edgesNotIncreasing(let channel),
                 .edgeAboveMax(let channel, _):       .gasEdges(channel)
            case .hysteresisTooLarge(let channel, _),
                 .hysteresisNotBelowFirstEdge(let channel, _): .hysteresis(channel)
            case .attentionNotBelowHazard(let channel): .pmEdges(channel)
            case .pmHysteresisTooLarge,
                 .pmHysteresisNotBelowAttention:      .hysteresisPM
            case .fanGasAboveMax:                     .fanGas
            case .fanPMAboveMax:                      .fanPM
            case .fanDownDelayAboveMax:               .fanDownDelay
            case .ionizerRunOnAboveMax:               .ionizerRunOn
            }
        }

        /// One-line, user-facing explanation naming the field (§1.2).
        var message: String {
            switch self {
            case .unsupportedVersion(let v):
                "The monitor reports thresholds format v\(v); this app writes v\(GATT.thresholdsVersion). "
                    + "Restore defaults on the monitor before editing."
            case .edgesNotIncreasing(let channel):
                "\(channel.title) edges must be strictly increasing: C1 < C2 < C3 < C4."
            case .edgeAboveMax(let channel, let max):
                "\(channel.title) C4 must be \(max) or less."
            case .hysteresisTooLarge(let channel, let gap):
                "\(channel.title) hysteresis must be below \(gap) — the smallest gap between its edges."
            case .hysteresisNotBelowFirstEdge(let channel, let c1):
                "\(channel.title) hysteresis must be 0 or below C1 (\(c1)), or the class could never return to 1."
            case .attentionNotBelowHazard(let channel):
                "\(channel.title) attention must be below hazard."
            case .pmHysteresisTooLarge(let band):
                "PM hysteresis must be below \(ThresholdsBlob.tenthsText(band)) µg/m³ — "
                    + "the narrowest attention-to-hazard band."
            case .pmHysteresisNotBelowAttention(let attention):
                "PM hysteresis must be 0 or below \(ThresholdsBlob.tenthsText(attention)) µg/m³ — "
                    + "the lowest attention edge — or PM could never return to good."
            case .fanGasAboveMax(let gasClass):
                "Fan for gas class \(gasClass) must be \(GATT.thresholdsFanPercentMax) % or less."
            case .fanPMAboveMax(let pmClass):
                "Fan for PM class \(pmClass) must be \(GATT.thresholdsFanPercentMax) % or less."
            case .fanDownDelayAboveMax:
                "Fan-down delay must be \(GATT.thresholdsFanDownDelayMaxSeconds) s or less."
            case .ionizerRunOnAboveMax:
                "Ionizer run-on must be \(GATT.thresholdsIonizerRunOnMaxMinutes) min or less."
            }
        }
    }

    /// The first rule the blob breaks, in firmware's own order, or `nil` when
    /// firmware would accept the write. Save is enabled only on `nil`.
    func validate() -> ValidationError? {
        validationErrors().first
    }

    /// Every rule the blob breaks, in firmware's check order (so `.first` is the
    /// one firmware would log). The editor shows them all at once, inline.
    ///
    /// Rules (§2.2, plus firmware's hysteresis floor — gatt-v3 notes §6):
    ///  • version == 1
    ///  • per gas: C1 < C2 < C3 < C4; C4 ≤ 500 (VOC, NOx) / 40000 (CO2);
    ///    hysteresis < the smallest adjacent-edge gap, and 0 or < C1
    ///  • per PM channel: attention < hazard
    ///  • PM hysteresis < the smallest (hazard − attention) of PM1 / PM2.5 / PM10,
    ///    and 0 or < the smallest attention edge
    ///  • every fan % ≤ 100; fan-down delay ≤ 3600 s; ionizer run-on ≤ 1440 min
    /// There is no lower bound on any edge — C1 may be 0 — and reserved bytes are
    /// not checked (firmware ignores them).
    ///
    /// A hysteresis check depends on its row being well-formed, as in firmware,
    /// so it is skipped while that row already has an ordering error.
    func validationErrors() -> [ValidationError] {
        var errors: [ValidationError] = []

        if version != GATT.thresholdsVersion {
            errors.append(.unsupportedVersion(version))
        }

        for channel in GasChannel.allCases {
            let edge = edges(channel)
            let increasing = zip(edge, edge.dropFirst()).allSatisfy { $0 < $1 }
            if !increasing {
                errors.append(.edgesNotIncreasing(channel))
            }
            if let c4 = edge.last, c4 > channel.edgeMax {
                errors.append(.edgeAboveMax(channel, max: channel.edgeMax))
            }
            if increasing, let gap = zip(edge, edge.dropFirst()).map({ $1 - $0 }).min(),
               hysteresis(channel) >= gap {
                errors.append(.hysteresisTooLarge(channel, smallestGap: gap))
            }
            if increasing, let c1 = edge.first,
               hysteresis(channel) != 0, hysteresis(channel) >= c1 {
                errors.append(.hysteresisNotBelowFirstEdge(channel, c1: c1))
            }
        }

        var pmPairsValid = true
        for channel in PMChannel.allCases where attention(channel) >= hazard(channel) {
            errors.append(.attentionNotBelowHazard(channel))
            pmPairsValid = false
        }
        if pmPairsValid,
           let band = PMChannel.allCases.map({ hazard($0) - attention($0) }).min(),
           hysteresisPM >= band {
            errors.append(.pmHysteresisTooLarge(smallestBand: band))
        }
        if pmPairsValid,
           let attention = PMChannel.allCases.map({ self.attention($0) }).min(),
           hysteresisPM != 0, hysteresisPM >= attention {
            errors.append(.pmHysteresisNotBelowAttention(smallestAttention: attention))
        }

        for (i, pct) in fanGasTable.enumerated() where pct > GATT.thresholdsFanPercentMax {
            errors.append(.fanGasAboveMax(gasClass: i + 1))
        }
        for (i, pct) in fanPMTable.enumerated() where pct > GATT.thresholdsFanPercentMax {
            errors.append(.fanPMAboveMax(pmClass: i + 1))
        }

        if fanDownDelaySeconds > GATT.thresholdsFanDownDelayMaxSeconds {
            errors.append(.fanDownDelayAboveMax)
        }
        if ionizerRunOnMinutes > GATT.thresholdsIonizerRunOnMaxMinutes {
            errors.append(.ionizerRunOnAboveMax)
        }
        return errors
    }

    // MARK: - Editor fields

    /// One editable number in the blob — a cell of the editor's grids (§3).
    enum Field: Hashable, Sendable, CaseIterable {
        case gasEdge(GasChannel, Int)   // edge index 0…3 = C1…C4
        case pmAttention(PMChannel)
        case pmHazard(PMChannel)
        case fanGas(Int)                // index 0…4 = gas class 1…5
        case fanPM(Int)                 // index 0…2 = PM class 1…3
        case fanDownDelay
        case ionizerRunOn
        case hysteresis(GasChannel)
        case hysteresisPM

        /// Every field, in editor order.
        static let allCases: [Field] = {
            var all: [Field] = []
            for channel in GasChannel.allCases {
                for i in 0..<ThresholdsBlob.gasEdgeCount { all.append(.gasEdge(channel, i)) }
            }
            for channel in PMChannel.allCases {
                all.append(.pmAttention(channel))
                all.append(.pmHazard(channel))
            }
            for i in 0..<ThresholdsBlob.gasClassCount { all.append(.fanGas(i)) }
            for i in 0..<ThresholdsBlob.pmClassCount { all.append(.fanPM(i)) }
            all.append(.fanDownDelay)
            all.append(.ionizerRunOn)
            for channel in GasChannel.allCases { all.append(.hysteresis(channel)) }
            all.append(.hysteresisPM)
            return all
        }()

        /// PM edges and PM hysteresis are µg/m³ with one decimal; the wire value
        /// is the displayed value × 10. Everything else is a whole number.
        var isTenths: Bool {
            switch self {
            case .pmAttention, .pmHazard, .hysteresisPM: true
            default: false
            }
        }

        /// The editor row the field sits in — where its own input errors and its
        /// rule's validation errors are shown together.
        var row: ValidationError.Row {
            switch self {
            case .gasEdge(let channel, _):  .gasEdges(channel)
            case .pmAttention(let channel),
                 .pmHazard(let channel):    .pmEdges(channel)
            case .fanGas:                   .fanGas
            case .fanPM:                    .fanPM
            case .fanDownDelay:             .fanDownDelay
            case .ionizerRunOn:             .ionizerRunOn
            case .hysteresis(let channel):  .hysteresis(channel)
            case .hysteresisPM:             .hysteresisPM
            }
        }

        /// Largest value the wire field can hold — u8 for fan %, u16 otherwise.
        /// A sanity cap for input, not a firmware rule (`validate()` owns those).
        var wireMax: UInt16 {
            switch self {
            case .fanGas, .fanPM: UInt16(UInt8.max)
            default:              UInt16.max
            }
        }
    }

    /// Reads or writes one field in wire units. Fan fields are u8 on the wire;
    /// the editor never offers more than `Field.wireMax`.
    subscript(field: Field) -> UInt16 {
        get {
            switch field {
            case .gasEdge(let channel, let i):
                let row = edges(channel)
                return row.indices.contains(i) ? row[i] : 0
            case .pmAttention(let channel): return attention(channel)
            case .pmHazard(let channel):    return hazard(channel)
            case .fanGas(let i):
                let table = fanGasTable
                return table.indices.contains(i) ? UInt16(table[i]) : 0
            case .fanPM(let i):
                let table = fanPMTable
                return table.indices.contains(i) ? UInt16(table[i]) : 0
            case .fanDownDelay:            return fanDownDelaySeconds
            case .ionizerRunOn:            return ionizerRunOnMinutes
            case .hysteresis(let channel): return hysteresis(channel)
            case .hysteresisPM:            return hysteresisPM
            }
        }
        set {
            switch field {
            case .gasEdge(let channel, let i):
                var row = edges(channel)
                guard row.indices.contains(i) else { return }
                row[i] = newValue
                switch channel {
                case .voc: vocEdges = row
                case .nox: noxEdges = row
                case .co2: co2Edges = row
                }
            case .pmAttention(.pm1):  pm1Attention = newValue
            case .pmAttention(.pm25): pm25Attention = newValue
            case .pmAttention(.pm10): pm10Attention = newValue
            case .pmHazard(.pm1):     pm1Hazard = newValue
            case .pmHazard(.pm25):    pm25Hazard = newValue
            case .pmHazard(.pm10):    pm10Hazard = newValue
            case .fanGas(let i):
                var table = fanGasTable
                guard table.indices.contains(i) else { return }
                table[i] = UInt8(clamping: newValue)
                fanGas = table
            case .fanPM(let i):
                var table = fanPMTable
                guard table.indices.contains(i) else { return }
                table[i] = UInt8(clamping: newValue)
                fanPM = table
            case .fanDownDelay:          fanDownDelaySeconds = newValue
            case .ionizerRunOn:          ionizerRunOnMinutes = newValue
            case .hysteresis(.voc):      hysteresisVOC = newValue
            case .hysteresis(.nox):      hysteresisNOx = newValue
            case .hysteresis(.co2):      hysteresisCO2 = newValue
            case .hysteresisPM:          hysteresisPM = newValue
            }
        }
    }

    // MARK: - Helpers

    /// A ×10 wire value as display text with exactly one decimal — integer
    /// arithmetic, so 25 is always "2.5", never "2.4999…".
    static func tenthsText(_ wire: UInt16) -> String {
        "\(wire / 10).\(wire % 10)"
    }

    /// Pads with zeros or truncates to `count` — the shape firmware's fixed
    /// arrays have.
    private static func fixedLength<T: FixedWidthInteger>(_ values: [T], _ count: Int) -> [T] {
        values.count == count
            ? values
            : Array(values.prefix(count)) + Array(repeating: 0, count: Swift.max(0, count - values.count))
    }
}
