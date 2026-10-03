//
//  GATT.swift
//  G2-iOS
//
//  Authoritative Smart Air System (G2) BLE GATT contract — **contract v3 (SEN66,
//  thresholds v3)**.
//
//  ⚠️ SOURCE OF TRUTH — these values mirror firmware branch `SEN66` of
//  earp123/G2-Air-Quality-Monitor: `docs/thresholds-v3.md` §2 and the iOS
//  handoff note `docs/gatt-v3-ios-notes.md` for everything v3 changed, and
//  `docs/sen66-migration.md` §6 / `docs/gatt-v2-ios-notes.md` (firmware commit
//  18746cd) for everything it left alone. Where they disagree, the v3 documents
//  win. Do NOT change, guess, or "improve" any UUID, opcode, byte
//  offset, scaling factor, or sentinel. If a value is missing here, ask before
//  assuming.
//
//  Contract v2 was NOT compatible with SPS30-era firmware: the live packet
//  (31 → 52 bytes), the history packet (31 → 34 bytes), the log record
//  (22 → 26 bytes) and the settings payload (8 → 12 bytes) all changed shape,
//  and the live marker moved from 0x02 to 0x03. Legacy payloads are rejected,
//  never best-effort decoded.
//
//  Contract v3 keeps every length and every UUID, but changes meaning (§2):
//  live byte 32 / log-record byte 22 become a packed gas + PM class byte, live
//  byte 1 carries payload version 3, the fan mode loses Custom (value 1), settings
//  bytes 0–7 are retired, opcode 0x0A is removed, opcode 0x10 is new, and a 60-byte
//  Thresholds characteristic is added. A v2 device is refused, not mis-decoded.
//

import CoreBluetooth

/// All identifiers and constants for the Smart Air System GATT interface (§1).
///
/// `nonisolated` so the constants can be read from CoreBluetooth's dedicated-queue
/// (nonisolated) delegate callbacks. The CBUUID values are immutable, hence the
/// `nonisolated(unsafe)` annotations are safe.
nonisolated enum GATT {

    /// Wire-contract version this client implements. Device Info byte 34 must
    /// match; a mismatch is reported to the user, never worked around (§9.3).
    /// v3 (thresholds-v3 §2.5) — a v2 unit gets the update-required state.
    static let contractVersion: UInt8 = 3

    /// Flash log-record version this client implements. Device Info byte 35
    /// carries the device's value; a change wipes the local cache (§2). v3 keeps
    /// the 26-byte layout but byte 22 becomes the packed class byte (§2.7).
    static let historyRecordVersion: UInt8 = 3

    /// Advertised local name of a never-named unit — display-only fallback for
    /// the scan list when a peripheral advertises no local name (§2).
    static let advertisedName = "Smart Air System"

    /// Names a factory-fresh unit reports from the Device Name characteristic.
    ///
    /// Firmware returns the saved nickname, or its `DEVICE_NAME` constant when no
    /// nickname is set (settings-v2 §2.3) — there is no wire flag distinguishing
    /// "never named" from "named to that exact string", so the naming prompt (§6)
    /// matches against this set. Sourced from firmware `main/ble_service.c`
    /// (`"Vigilance Air Monitor"`); `advertisedName` is included because the
    /// default name is still an open naming decision (settings-v2 §3.3) and both
    /// strings are in play across builds.
    static let factoryDefaultDeviceNames: Set<String> = [
        "Vigilance Air Monitor",
        advertisedName,
    ]

    /// Primary service — scan filters on this UUID (§1). Unchanged in v2.
    nonisolated(unsafe) static let serviceUUID = CBUUID(string: "7A3E4F5B-8C2D-4E9A-B1F6-0D3C5E7F9A2B")

    /// Characteristic 1 — Sensor Data, READ + NOTIFY, 52-byte payload (§1.1).
    nonisolated(unsafe) static let sensorCharacteristicUUID = CBUUID(string: "7A3E4F5C-8C2D-4E9A-B1F6-0D3C5E7F9A2B")

    /// Characteristic 2 — Command, WRITE + WRITE_NO_RSP, 1–5 byte payload (§1.6).
    nonisolated(unsafe) static let commandCharacteristicUUID = CBUUID(string: "7A3E4F5D-8C2D-4E9A-B1F6-0D3C5E7F9A2B")

    /// Characteristic 3 — Settings, READ + WRITE, 12-byte payload (§1.3).
    nonisolated(unsafe) static let settingsCharacteristicUUID = CBUUID(string: "7A3E4F5E-8C2D-4E9A-B1F6-0D3C5E7F9A2B")

    /// Characteristic 4 — Device Name, READ + WRITE, 1–20 bytes UTF-8 (§1.4).
    nonisolated(unsafe) static let deviceNameCharacteristicUUID = CBUUID(string: "7A3E4F5F-8C2D-4E9A-B1F6-0D3C5E7F9A2B")

    /// Characteristic 5 — Device Info, READ, 40 bytes (§1.5).
    nonisolated(unsafe) static let deviceInfoCharacteristicUUID = CBUUID(string: "7A3E4F60-8C2D-4E9A-B1F6-0D3C5E7F9A2B")

    /// Characteristic 6 — Thresholds, READ + WRITE, 60 bytes. New in contract v3
    /// (thresholds-v3 §2.2); read once on connect, written whole on Save.
    nonisolated(unsafe) static let thresholdsCharacteristicUUID = CBUUID(string: "7A3E4F61-8C2D-4E9A-B1F6-0D3C5E7F9A2B")

    /// Every characteristic the client discovers, in one place.
    nonisolated(unsafe) static let allCharacteristicUUIDs: [CBUUID] = [
        sensorCharacteristicUUID,
        commandCharacteristicUUID,
        settingsCharacteristicUUID,
        deviceNameCharacteristicUUID,
        deviceInfoCharacteristicUUID,
        thresholdsCharacteristicUUID,
    ]

    /// Classifies a discovered characteristic without leaking CoreBluetooth
    /// types across the BLE-queue → MainActor boundary.
    enum Characteristic: Sendable {
        case sensor
        case command
        case settings
        case deviceName
        case deviceInfo
        case thresholds
        case unknown

        init(_ uuid: CBUUID) {
            switch uuid {
            case GATT.sensorCharacteristicUUID:     self = .sensor
            case GATT.commandCharacteristicUUID:    self = .command
            case GATT.settingsCharacteristicUUID:   self = .settings
            case GATT.deviceNameCharacteristicUUID: self = .deviceName
            case GATT.deviceInfoCharacteristicUUID: self = .deviceInfo
            case GATT.thresholdsCharacteristicUUID: self = .thresholds
            default:                                self = .unknown
            }
        }
    }

    // MARK: - Command opcodes (§1.6)

    /// Command-characteristic opcodes. LOW/MED/HIGH/MAX map to 25/50/75/100%.
    /// `0x0D`–`0x0F` are new in v2. In v3 `0x0A` (Custom) is **removed** —
    /// firmware answers it with an ATT error, so it has no case here and can
    /// never be sent — and `0x10` is new (thresholds-v3 §2.4).
    enum Command: UInt8 {
        case syncHistory  = 0x01  // Full history dump.
        case fanManual    = 0x02  // [pct: u8] — exact fan speed 0–100% (2-byte write).
        case fanAuto      = 0x03  // Gas/PM fan tables, worst wins.
        case fanOff       = 0x04  // Manual 0%.
        case fanLow       = 0x05  // Manual 25%.
        case fanMed       = 0x06  // Manual 50%.
        case fanHigh      = 0x07  // Manual 75%.
        case fanMax       = 0x08  // Manual 100%.
        case getStatus    = 0x09  // Force an immediate sensor notification (needs active CCCD).
        // 0x0A — retired (was Custom / VOC setpoints). Never sent.
        case setTime      = 0x0B  // SET_TIME [sec min hr wday mday mon yr2k] — raw decimal, not BCD.
        case syncRecent   = 0x0C  // SYNC_RECENT [count: u32 LE] — stream newest N records (5-byte write).
        case fanCleaning  = 0x0D  // SEN66 fan cleaning, no params (~12 s, PM pauses, re-arms warming).
        case co2Recal     = 0x0E  // Forced CO2 recalibration [ppm_ref: u16 LE].
        case clearErrors  = 0x0F  // Read-and-clear the SEN66 device status register.
        case restoreThresholds = 0x10  // Thresholds blob → §2.2 defaults; Settings and name untouched.
    }

    /// ATT error returned by the device for an unknown opcode (§1.6).
    static let attErrorUnknownOpcode: UInt8 = 0x0E

    /// Reference concentration the app sends with `0x0E` — clean outdoor air.
    static let co2RecalibrationReferencePpm: UInt16 = 400

    /// Accepted range for the `0x0E` reference concentration. Firmware rejects
    /// anything outside it with an ATT error (firmware §6.7 / notes §4).
    static let co2RecalibrationRange: ClosedRange<UInt16> = 350...2000

    // MARK: - Sensor payload layout (§1.1) — 52 bytes

    /// Required length of a live sensor payload.
    static let sensorPayloadLength = 52

    /// v2 decodes from byte 0 — the eight fake advertising-header bytes that
    /// prefixed the v1 payload are gone (§1.1).
    static let sensorPayloadDecodeOffset = 0

    /// payload[0] of a live v2 packet. `0x02` (v1 live) is never sent on this
    /// branch and is rejected rather than decoded.
    static let livePacketMarker: UInt8 = 0x03
    /// payload[0] of the retired v1 live packet — rejected (§1.1).
    static let legacyLivePacketMarker: UInt8 = 0x02
    /// payload[1] — the packet-format version carried inside a live packet.
    /// Firmware packs `GEUE_CONTRACT_VERSION` here (the same macro as Device Info
    /// byte 34), so it moves to 3 with the contract — firmware thresholds-v3 §5
    /// lists byte 1 among the live bytes that change. A v2 packet is rejected.
    static let livePayloadVersion: UInt8 = 0x03

    /// Byte offsets within the 52-byte live packet (§1.1). Named so the parser
    /// never carries a bare integer that could drift from the contract.
    enum SensorOffset {
        static let marker         = 0
        static let payloadVersion = 1
        static let sequence       = 2   // u16
        static let temperature    = 4   // i16 ×100 °C
        static let humidity       = 6   // u16 ×100 %
        static let vocIndex       = 8   // u16 ×10
        static let noxIndex       = 10  // u16 ×10
        static let co2            = 12  // u16 ppm
        static let pm1            = 14  // u16 ×10 µg/m³
        static let pm25           = 16
        static let pm4            = 18
        static let pm10           = 20
        static let nc05           = 22  // u16 ×10 #/cm³
        static let nc1            = 24
        static let nc25           = 26
        static let nc4            = 28
        static let nc10           = 30
        static let classByte      = 32  // u8 packed: low nibble gas 0–5, high nibble PM 0–3
        static let fanPercent     = 33  // u8
        static let fanMode        = 34  // u8 0 Auto / 2 Manual (1 retired, never sent)
        static let status         = 35  // u8 bitfield
        static let sen66Status    = 36  // u32 device status register
        static let rawVOCTicks    = 40  // u16
        static let rawNOxTicks    = 42  // u16
        static let rawCO2         = 44  // u16 ppm
        static let rawHumidity    = 46  // i16 ×100 %
        static let rawTemperature = 48  // i16 ×200 °C
        static let deviceState    = 50  // u8 0 Standby / 1 Enabled / 2 Wait
        static let reserved       = 51
    }

    // MARK: - Settings payload layout (§1.3) — 12 bytes

    /// Settings characteristic length: 8 retired bytes + brightness + fan mode +
    /// fan manual % + 1 reserved byte. The client always writes 12 bytes; the
    /// 8-byte legacy form is rejected by v3 firmware (thresholds-v3 §2.3).
    static let settingsPayloadLength = 12

    enum SettingsOffset {
        static let retired       = 0   // 8 bytes, were VOC lo/med/hi/max — READ 0, always written 0
        static let retiredLength = 8
        static let ledBrightness = 8   // u8 5–100
        static let fanMode       = 9   // u8 0 Auto / 2 Manual — 1 is rejected by firmware
        static let fanManualPct  = 10  // u8 0–100
        static let reserved      = 11
    }

    /// LED brightness bounds and factory default (§1.3). Firmware clamps writes
    /// below 5 to 5, so the slider never offers a value the device would reject.
    static let ledBrightnessMin: UInt8 = 5
    static let ledBrightnessMax: UInt8 = 100
    static let ledBrightnessDefault: UInt8 = 50

    // MARK: - Thresholds payload layout (thresholds-v3 §2.2) — 60 bytes

    /// READ always returns exactly 60 bytes; a WRITE of any other length is
    /// rejected with `BLE_ATT_ERR_INVALID_ATTR_VALUE_LEN`.
    static let thresholdsPayloadLength = 60

    /// Byte 0 of the blob. Firmware rejects any other value.
    static let thresholdsVersion: UInt8 = 1

    /// Byte offsets within the 60-byte Thresholds blob. All multi-byte fields are
    /// little-endian; PM edges and PM hysteresis are µg/m³ ×10 on the wire.
    enum ThresholdsOffset {
        static let version          = 0   // u8, must be 1
        static let reserved1        = 1   // u8, write 0, ignore on read
        static let vocEdges         = 2   // 4 × u16 C1..C4, VOC index
        static let noxEdges         = 10  // 4 × u16 C1..C4, NOx index
        static let co2Edges         = 18  // 4 × u16 C1..C4, ppm
        static let pm1Attention     = 26  // u16 ×10
        static let pm1Hazard        = 28
        static let pm25Attention    = 30
        static let pm25Hazard       = 32
        static let pm10Attention    = 34
        static let pm10Hazard       = 36
        static let fanGas           = 38  // 5 × u8, % for gas class 1..5
        static let fanPM            = 43  // 3 × u8, % for PM class 1..3
        static let fanDownDelay     = 46  // u16 seconds
        static let ionizerRunOn     = 48  // u16 minutes
        static let hysteresisVOC    = 50  // u16 VOC index
        static let hysteresisNOx    = 52  // u16 NOx index
        static let hysteresisCO2    = 54  // u16 ppm
        static let hysteresisPM     = 56  // u16 ×10
        static let reserved58       = 58  // u16, write 0, ignore on read
    }

    /// Upper bounds firmware enforces on a Thresholds write (§2.2). There are no
    /// lower bounds beyond "strictly increasing" / "below hazard" — C1 may be 0 —
    /// so the app enforces none either: it must accept every blob firmware does.
    static let thresholdsVOCEdgeMax: UInt16 = 500
    static let thresholdsNOxEdgeMax: UInt16 = 500
    static let thresholdsCO2EdgeMax: UInt16 = 40_000
    static let thresholdsFanPercentMax: UInt8 = 100
    static let thresholdsFanDownDelayMaxSeconds: UInt16 = 3_600
    static let thresholdsIonizerRunOnMaxMinutes: UInt16 = 1_440

    // MARK: - Device Name (§1.4)

    /// Maximum Device Name length **in UTF-8 bytes**, not characters. Set by the
    /// advertising budget (settings-v2 §2.3) — do not raise it.
    static let deviceNameMaxBytes = 20

    // MARK: - Device Info payload layout (§1.5) — 40 bytes

    static let deviceInfoPayloadLength = 40

    enum DeviceInfoOffset {
        static let serial           = 0   // 32 bytes ASCII, NUL-padded
        static let serialLength     = 32
        static let firmwareMajor    = 32
        static let firmwareMinor    = 33
        static let contractVersion  = 34
        static let logRecordVersion = 35
        static let reserved         = 36  // 4 bytes
    }

    // MARK: - History packet demux (shares the Sensor characteristic) (§1.2)
    //
    // Live sensor notifications keep firing during a history stream, on the SAME
    // characteristic — demux on payload[0]: 0x03 = live, 0xA5 = history.
    // A v2 history packet is 34 bytes: 0xA5, 0x48 ('H'), u24 total, u24 index,
    // and a 26-byte log record v2. 31-byte v1 packets are rejected on length.

    /// payload[0] value that marks a history sync packet (vs live data 0x03).
    static let historyPacketMarker: UInt8 = 0xA5
    /// payload[1] for a history packet (ASCII 'H').
    static let historyHeaderMarker: UInt8 = 0x48

    /// Required length of a v2 history packet. The retired v1 packet was 31
    /// bytes — length is how a client tells the two apart (firmware §6.2).
    static let historyPacketLength = 34

    /// Wire offsets of the u24 LE total/index fields. Both are relative to THIS
    /// sync (a recent-N sync has total == N) and don't wrap for any realistic
    /// buffer, so index/total is a reliable progress fraction. Completion is still
    /// signalled by the all-zero record sentinel.
    static let historyTotalCountOffset = 2
    static let historyRecordIndexOffset = 5
    /// Byte offset of the log record within a history packet.
    static let historyRecordOffset = 8
    /// Length of log record v2 (`geue_log_record_t`), packed, no padding (§1.2).
    static let historyRecordLength = 26

    /// Byte offsets within the 26-byte log record, relative to the record start.
    /// Number concentrations and raw values are **not** logged (firmware §6.3).
    /// Record v3 has the same layout as v2; only byte 22's meaning changed.
    enum HistoryRecordOffset {
        static let timestamp   = 0   // u32 Unix epoch seconds
        static let temperature = 4   // i16 ×100 °C
        static let humidity    = 6   // u16 ×100 %
        static let vocIndex    = 8   // u16 ×10
        static let noxIndex    = 10  // u16 ×10
        static let co2         = 12  // u16 ppm
        static let pm1         = 14  // u16 ×10 µg/m³
        static let pm25        = 16
        static let pm4         = 18
        static let pm10        = 20
        static let classByte   = 22  // u8 packed, same rule as live byte 32
        static let status      = 23  // u8
        static let sequence    = 24  // u16
    }

    // MARK: - Invalid sentinels and the shared decode family (§1)
    //
    // One decode per wire shape, shared by SensorParser (live), HistoryPacketParser
    // (history) and the settings/info decoders, so a sentinel rule is never
    // duplicated — or forgotten — across files.

    /// No valid reading — sensor absent, warming up, or read failed.
    static let u16Sentinel: UInt16 = 0xFFFF
    /// Over-range clamp, PM fields only. Folded into the same invalid state as
    /// no-reading: there is no distinct over-range UI (§1).
    static let pmSentinelOverRange: UInt16 = 0xFFFE
    /// Invalid sentinel for signed fields (`INT16_MIN`).
    static let i16Sentinel: Int16 = Int16.min

    /// Retained v1 spelling of `u16Sentinel`, kept because PM is the field where
    /// the two-sentinel rule originated and reads clearly at the call site.
    static let pmSentinelNoReading: UInt16 = u16Sentinel

    /// Unscaled u16 → `Int`, or `nil` for the invalid sentinel.
    static func decodeU16(_ raw: UInt16) -> Int? {
        raw == u16Sentinel ? nil : Int(raw)
    }

    /// u16 ×10 → display units, or `nil` for the invalid sentinel.
    /// Used for VOC index, NOx index and number concentrations.
    static func decodeU16x10(_ raw: UInt16) -> Double? {
        raw == u16Sentinel ? nil : Double(raw) / 10.0
    }

    /// PM u16 ×10 → µg/m³, or `nil` for **either** PM sentinel (0xFFFF
    /// no-reading, 0xFFFE over-range), so 0xFFFE never shows as 6553.4.
    static func decodePMx10(_ raw: UInt16) -> Double? {
        (raw == u16Sentinel || raw == pmSentinelOverRange) ? nil : Double(raw) / 10.0
    }

    /// i16 ×100 → display units (°C, %), or `nil` for the invalid sentinel.
    static func decodeI16x100(_ raw: Int16) -> Double? {
        raw == i16Sentinel ? nil : Double(raw) / 100.0
    }

    /// i16 ×200 → °C, or `nil` for the invalid sentinel. The SEN66's native
    /// scaling for the uncompensated temperature (§1.1 bytes 48–49).
    static func decodeI16x200(_ raw: Int16) -> Double? {
        raw == i16Sentinel ? nil : Double(raw) / 200.0
    }

    /// u16 ×100 → display units (%), or `nil` for the invalid sentinel.
    static func decodeU16x100(_ raw: UInt16) -> Double? {
        raw == u16Sentinel ? nil : Double(raw) / 100.0
    }
}
