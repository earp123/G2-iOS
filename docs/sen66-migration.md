# Task: SEN66 migration — GATT contract v2, full sensor surface, settings v2, nickname

**Branch:** `SEN66` (cut 2026-09-14). This branch tracks firmware branch `SEN66` of `earp123/G2-Air-Quality-Monitor` and is **not** compatible with `SPS30`-era firmware — the live packet, history packet, and settings payload all changed shape.
**Contract source of truth:** firmware `docs/sen66-migration.md` §6 and, once it lands, firmware `docs/gatt-v2-ios-notes.md`. The tables below mirror §6. If the firmware handoff note disagrees with this file, the firmware note wins — stop and flag the difference before coding around it.
**Status:** READY. STOP-AND-ASK items in section 9.

> **Partly superseded by [`thresholds-v3.md`](thresholds-v3.md) (GATT contract v3, landed).** For
> live byte 1 (payload version now `0x03`), live byte 32 and log-record byte 22 (now the packed
> gas / PM class byte, not `aq_class`), live byte 34 / Settings byte 9 (0 Auto · 2 Manual — Custom
> retired), Settings bytes 0–7 (retired, read and written as 0), opcode `0x0A` (removed), the
> Device Info versions (now 3 / 3, with no all-zero exemption) and everything about the VOC
> threshold editor and Custom mode, thresholds-v3 wins. The rest of this file still describes the
> shipped decode. Superseded lines below are marked **v3:**.

---

## 0. Read before writing

- `CHANGELOG.md`, `README.md`
- `G2-iOS/BLE/GATT.swift`, `SensorParser.swift`, `HistoryPacketParser.swift`, `BluetoothManager.swift`
- `G2-iOS/Models/*` (`SensorReading`, `DeviceStatus`, `AQILevel`, `TVOCThresholds`, `FanMode`, `DiscoveredDevice`)
- `G2-iOS/History/*` (`HistoryRecord`, `HistoryDataStore`, `HistoryStore`, `HistoryMetric`, both repositories)
- `G2-iOS/Views/Conditioning/ConditioningView.swift`, `Views/Settings/SettingsView.swift`, `Views/Dashboard/*`, `Views/Scan/*`
- Firmware repo, branch `SEN66`: `docs/sen66-migration.md`, `docs/ble-settings-v2-led-fan-nickname.md`, `docs/gatt-v2-ios-notes.md` (when present)

## 1. Contract v2 — what changes on the wire

Service UUID unchanged. All multi-byte LE. u16 invalid = `0xFFFF` (PM also `0xFFFE`); i16 invalid = `Int16.min`.

### 1.1 Sensor Data `7A3E4F5C-…` — 52 bytes (was 31)

`sensorPayloadDecodeOffset` becomes **0**. Demux on byte 0: `0x03` live v2, `0xA5` history. Reject anything else, including legacy `0x02`.

| Byte | Field |
|---|---|
| 0 | marker `0x03` |
| 1 | payload version `0x02` — **v3: `0x03`** |
| 2–3 | seq u16 |
| 4–5 | temp i16 ×100 °C |
| 6–7 | RH u16 ×100 % |
| 8–9 | VOC index u16 ×10 (1.0–500.0) |
| 10–11 | NOx index u16 ×10 |
| 12–13 | CO2 u16 ppm |
| 14–21 | PM1.0 / PM2.5 / PM4.0 / PM10 u16 µg/m³ ×10 |
| 22–31 | NC0.5 / NC1.0 / NC2.5 / NC4.0 / NC10 u16 #/cm³ ×10 |
| 32 | aq_class u8 0–5 (0 = unknown/warming) — **v3: packed class byte, low nibble gas 0–5, high nibble PM 0–3** |
| 33 | fan % u8 |
| 34 | fan mode u8: 0 Auto, 1 Custom, 2 Manual — **v3: 0 Auto, 2 Manual; 1 never sent** |
| 35 | status u8 — bit0 SEN66 present · bit1 fresh this tick · bit2 SEN66 warming · bit3 TWAI online · bit4 SEN66 sticky error · bit5 ionizer fault · bit6 ionizer on · bit7 reserved |
| 36–39 | SEN66 device status register u32 (bit 21 fan-speed warning; error bits 11 PM, 9 CO2, 7 gas, 6 RH&T, 4 fan) |
| 40–41 / 42–43 / 44–45 | raw VOC ticks / raw NOx ticks / raw CO2 ppm u16 |
| 46–47 / 48–49 | raw RH i16 ×100 / raw T i16 ×200 (sensor-native, uncompensated) |
| 50 | device state u8: 0 Standby, 1 Enabled, 2 Wait |
| 51 | reserved |

### 1.2 History packet — 34 bytes; record — 26 bytes

`0xA5 0x48 | total u24 @2 | index u24 @5 | record @8`. Reject 31-byte packets. Sentinel rule unchanged (all-zero record).
Record: `timestamp u32 | temp i16 ×100 | rh u16 ×100 | voc u16 ×10 | nox u16 ×10 | co2 u16 | pm1 | pm25 | pm4 | pm10 (u16 ×10 each) | aq_class u8 | status u8 | seq u16`.
**v3:** byte 22 (`aq_class`) is the packed class byte, same rule as live byte 32; log record version 3. A v2-era record decodes with PM class 0 (grey PM tile).

### 1.3 Settings `7A3E4F5E-…` — 12 bytes

`[0–7] VOC-index thresholds lo/med/hi/max 4×u16 (1–500, defaults 100/150/250/400) | [8] LED brightness u8 5–100 | [9] fan mode u8 | [10] fan manual % u8 | [11] reserved`. Always write 12 bytes.
**v3:** bytes 0–7 are retired (read 0, always written 0); byte 9 is 0 Auto / 2 Manual. Every band now lives in the 60-byte Thresholds characteristic `7A3E4F61-…`.

### 1.4 Device Name `7A3E4F5F-8C2D-4E9A-B1F6-0D3C5E7F9A2B` — READ + WRITE, 1–20 bytes UTF-8, no NUL, trimmed.

### 1.5 Device Info `7A3E4F60-8C2D-4E9A-B1F6-0D3C5E7F9A2B` — READ, 40 bytes

`[0–31] SEN66 serial ASCII NUL-padded | [32] SEN66 fw major | [33] minor | [34] contract version (expect 2) | [35] log record version (expect 2) | [36–39] reserved`.
**v3:** expect 3 / 3. Bytes 34–35 are always populated, even with no SEN66 at boot — only bytes 0–33 are zero then.

### 1.6 Commands — three new opcodes

`0x0D` SEN66 fan cleaning (no params) · `0x0E` forced CO2 recalibration `[ppm u16 LE]` (app sends 400) · `0x0F` clear SEN66 sticky errors. Existing `0x01`–`0x0C` unchanged; `0x0A` is now labelled **Custom**.
**v3:** `0x0A` is removed (never sent); `0x10` restores the thresholds blob to defaults.

## 2. BLE layer

- `GATT.swift`: update every constant to section 1; add `deviceNameCharacteristicUUID`, `deviceInfoCharacteristicUUID`, the three opcodes, `contractVersion = 2`. Keep the "SOURCE OF TRUTH" header discipline — no guessed values.
- `Characteristic` enum gains `.deviceName`, `.deviceInfo`. `BluetoothManager` reads Settings, Device Name, and Device Info once after discovery, exposes them as observable state, and offers `writeSettings(_:)`, `writeDeviceName(_:)`, `sendFanCleaning()`, `sendCO2Recalibration(ppm:)`, `sendClearSensorErrors()`.
- `SensorParser`: rewrite for 1.1. Length-checked, no force unwraps, every u16/i16 field through one shared invalid-sentinel decode (extend `GATT.decodePM` into a general `decodeU16x10`, `decodeI16x100` family). Output `SensorReading` with typed `Metric<Double>`s in display units (index as `Double` /10, PM µg/m³ /10, NC #/cm³ /10, raw fields kept as raw `Metric<Int>`), plus `aqClass`, `fanMode`, `deviceState`, `status`, `sen66Status`.
- `DeviceStatus`: new bit map from byte 35; add a `SEN66Status` struct decoding the u32 (fan-speed warning + five error flags, names per datasheet §4.3). The ionizer decode stays where it is (bits 5/6 unchanged).
- `AQILevel`: built from `aq_class` byte; `0` → a new `.unknown` case rendered as "Warming up" when status bit2 is set, "—" otherwise. **v3:** built from the gas nibble of the packed byte (`AirClasses`); `PMLevel` covers the PM nibble.
- `HistoryPacketParser`: 1.2. Add `GATT.historyRecordVersion = 2`; on the first successful sync after launch compare against a `UserDefaults` key and wipe all `HistoryRecord` rows (via the actor) when it changes.
- Scan list: `DiscoveredDevice.name` must come from `CBAdvertisementDataLocalNameKey`, falling back to `peripheral.name` only when the key is absent. `GATT.advertisedName` stays display-only.
- Simulator path: synthesize 52-byte v2 packets and 34-byte history packets through the real parsers.

## 3. History / SwiftData

- `HistoryRecord`: fields `vocIndex`, `noxIndex`, `co2`, `pm1`, `pm25`, `pm4`, `pm10` (`Double?`), `aqClass`, `status`, `seq`, `timestamp`, `temperature`, `humidity`, `deviceID`. `tvoc`/`eco2` are removed (not renamed — the semantics changed).
- Pre-1.0, no production data: point the `ModelContainer` at a new store file (`history-v2.store`) and delete the old file on first launch. No versioned migration.
- `HistoryMetric`: Temp/RH overlay · VOC index · NOx index · CO2 · PM1.0 · PM2.5 · PM4 · PM10 (8 items — see 9.2 for the picker). AQ class stays out of the chart, in the row dot and drill-down as today.
- Mock repository and CSV export: add the new columns, drop the old ones. CSV header order = record field order.

## 4. Dashboard

- Hero = `aqClass` via `AQILevel`; warming state shown explicitly (status bit2).
- Tiles: Temp, RH, VOC index, NOx index, CO2, PM1.0, PM2.5, PM4, PM10.
- "Sensor detail" disclosure (collapsed by default): number concentrations ×5, raw VOC/NOx ticks, raw CO2, raw RH/T, SEN66 fw + serial (from Device Info), device state, SEN66 status flags with the fan-speed warning surfaced as a yellow row.
- Freshness: use status bit1 in addition to the `TimelineView` age.

## 5. Conditioning tab

- Rename: `FanMode.tvocAuto.title` → **"Custom"**; the auto-mode note → "Custom (VOC index thresholds)"; nothing else about `0x0A` changes. **v3:** Custom is deleted; the picker is Auto / Manual.
- The mode picker **mirrors byte 34**. `mode` is no longer app-local state: initialise from the device and update on every reading. Guard `onChange(of: mode)` so a device-driven update does not re-send the command (compare against last device-reported mode before writing).
- **Manual 0 % warning.** When `fanMode == .manual && fanSpeedPct == 0`, show a persistent warning card at the top of the tab ("Fan is set to Manual / Off and will stay off at the next start. Switch to Auto or Custom to restore automatic control.") and a warning badge on the Conditioning tab item. This is the app-side half of a firmware decision: firmware restores Manual 0 % exactly as saved, by design.

## 6. Settings tab

- Threshold editor: label "VOC INDEX THRESHOLDS", range 1–500, step 10, defaults 100/150/250/400; `TVOCThresholds` → `VOCThresholds` (same monotonic validation). Fan-mapping reference header → "FAN MAPPING (CUSTOM)". **v3:** both deleted; replaced by the Air quality thresholds section.
- **LED brightness** slider 5–100 %, label shows %, pre-populated from settings byte 8, writes the full 12-byte settings on release (debounced like the fan slider). Default from a fresh unit is 50.
- **Device name**: text field pre-populated from the Name characteristic, 20-byte UTF-8 limit enforced in the editor (count bytes, not characters), save writes the characteristic and updates the connection chip. On connect, if the read name equals the firmware default (whatever Device Name returns on a never-named unit — read it, don't hard-code it), present a one-time naming sheet (skippable, never shown again for that peripheral identifier).
- Diagnostics: keep RSSI/MTU; add Device Info rows (serial, SEN66 fw, contract version — show a red row if contract version ≠ 2); SEN66 status flags; three maintenance buttons — "Clean sensor fan" (`0x0D`, note "~10 s, PM readings pause"), "Clear sensor errors" (`0x0F`), "Calibrate CO2 outdoors" (`0x0E` with 400, behind a confirmation alert stating the sensor must have been outdoors ≥ 3 min).

## 7. Tests

Golden vectors for: a full valid 52-byte packet; all-invalid sentinels; PM `0xFFFE`; warming state (bit2 set, aq_class 0); a 34-byte history packet + sentinel; a 31-byte legacy packet (must be rejected); 12-byte settings encode/decode round-trip incl. brightness clamp display; name byte-length validation with a multi-byte UTF-8 string. `BUILD SUCCEEDED`, zero warnings, Swift 6 strict concurrency, iOS 17 target.

## 8. Zero-change

`BluetoothManager` queue/actor architecture, `HistoryDataStore` batching and 90-day pruning, sync progress logic, incremental-sync (`0x0C`) request math, `Theme`, bundle id, deployment target.

## 9. STOP-AND-ASK

1. Firmware `docs/gatt-v2-ios-notes.md` disagrees with section 1 → stop, report the diff.
2. Chart metric picker: 8 items no longer fit a segmented control. Default: `.menu` picker style. Stop only if Sam wants a different layout.
3. If the Device Info read returns contract version ≠ 2 on the bench unit, do not "handle" it — report it.
4. Any change that would require a SwiftData versioned migration.

## 10. Deliverables

- Code on `SEN66`.
- `CHANGELOG.md` entry mirroring the firmware contract tables, the store reset, the Custom rename, the Manual-0 % warning, the brightness/name/maintenance features, and test results.
