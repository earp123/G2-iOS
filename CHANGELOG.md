# Changelog

All notable changes to the **Smart Air System** iOS client.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
the app version tracks [Semantic Versioning](https://semver.org/).

> **Team sync note.** Everything below is in the working tree on top of the single
> `Initial Commit` (`31f5189`), which still contains the *pre-rebuild* app. None of
> this is tagged or merged yet. Pull, then read **[Action items](#action-items-for-the-team)**
> at the bottom before building.
>
> App version: **1.0 (build 1)** · Bundle id: `GEUE.Smart-Air-Monitor` ·
> Deployment target: **iOS 17.0** · Swift **6.0** (strict concurrency) ·
> Dependencies: **none** (CoreBluetooth, SwiftData, Swift Charts, Foundation only).

---

## [Unreleased] — targeting 1.0.0

### SEN66 migration — GATT contract v2, full sensor surface, settings v2, device naming

**Breaking.** This release speaks **GATT contract v2** and is **not compatible
with SPS30-era firmware**. It requires firmware branch `SEN66` of
`earp123/G2-Air-Quality-Monitor` (contract version 2, log record version 2).
A v1 device is detected on connect and refused rather than mis-decoded.

Contract verified byte-for-byte against firmware `docs/sen66-migration.md` §6 and
the iOS handoff note `docs/gatt-v2-ios-notes.md` (firmware commit `18746cd`,
SHA-256 `83a95696…`): 144 machine-checked assertions over every byte offset,
scale divisor, sentinel, marker, length, opcode, status bit and UUID, plus all
17 behavioural requirements from the note's §9 checklist and prose.

#### Wire contract v2

| Surface | v1 | v2 |
|---|---|---|
| Sensor Data `7A3E4F5C-…` | 31 B, marker `0x02`, decode from byte 8 | **52 B**, marker `0x03`, decode from **byte 0** |
| History packet | 31 B | **34 B** |
| Log record `geue_log_record_t` | 22 B | **26 B** |
| Settings `7A3E4F5E-…` | 8 B | **12 B** (always written in full) |
| Device Name `7A3E4F5F-…` | — | **new**, READ + WRITE, 1–20 B UTF-8 |
| Device Info `7A3E4F60-…` | — | **new**, READ, 40 B |

Service UUID and the four existing characteristic UUIDs are unchanged.

**Live packet (52 B).** `0` marker `0x03` · `1` payload version `0x02` ·
`2–3` seq u16 · `4–5` temp i16 ×100 °C · `6–7` RH u16 ×100 % ·
`8–9` VOC index u16 ×10 · `10–11` NOx index u16 ×10 · `12–13` CO₂ u16 ppm ·
`14–21` PM1.0 / PM2.5 / PM4.0 / PM10 u16 ×10 µg/m³ ·
`22–31` NC0.5 / NC1.0 / NC2.5 / NC4.0 / NC10 u16 ×10 #/cm³ ·
`32` aq_class u8 0–5 · `33` fan % u8 · `34` fan mode u8 (0 Auto / 1 Custom / 2 Manual) ·
`35` status u8 · `36–39` SEN66 device status u32 ·
`40–45` raw VOC ticks / raw NOx ticks / raw CO₂ ppm u16 ·
`46–47` raw RH i16 **×100** · `48–49` raw T i16 **×200** ·
`50` device state u8 · `51` reserved.

> The two temperature scales differ deliberately: compensated temperature is
> ÷100, the sensor-native raw temperature is ÷200. Dividing the raw field by 100
> reads twice as hot as reality.

**Status byte 35.** bit0 SEN66 present · bit1 fresh sample this tick ·
bit2 SEN66 warming · bit3 TWAI online · bit4 SEN66 sticky error ·
bit5 ionizer fault · bit6 ionizer on · bit7 reserved.

**Log record v2 (26 B).** `timestamp u32 | temp i16 ×100 | rh u16 ×100 |
voc u16 ×10 | nox u16 ×10 | co2 u16 | pm1 | pm25 | pm4 | pm10 (u16 ×10) |
aq_class u8 | status u8 | seq u16`. Number concentrations and raw values are
live-only, never logged.

**Settings (12 B).** `[0–7]` VOC-index thresholds lo/med/hi/max 4×u16
(1–500, defaults **100/150/250/400**) · `[8]` LED brightness u8 5–100 (default 50) ·
`[9]` fan mode u8 · `[10]` fan manual % u8 · `[11]` reserved.

**Device Info (40 B).** `[0–31]` SEN66 serial ASCII NUL-padded · `[32]` fw major ·
`[33]` fw minor · `[34]` contract version · `[35]` log record version · `[36–39]` reserved.

**New opcodes.** `0x0D` SEN66 fan cleaning · `0x0E` forced CO₂ recalibration
`[ppm u16 LE]` (app sends 400) · `0x0F` clear SEN66 sticky errors.
`0x01`–`0x0C` unchanged; `0x0A` is now labelled **Custom**.

#### Added
- **Full SEN66 metric surface.** Dashboard tiles for Temperature, Humidity,
  VOC index, NOx index, CO₂, PM1.0, PM2.5, PM4.0 and PM10. A collapsed-by-default
  **Sensor detail** disclosure carries the five number concentrations, raw VOC/NOx
  ticks, raw CO₂, raw uncompensated RH/T, SEN66 serial and firmware, device state,
  and the SEN66 device status register — with the **fan-speed warning (bit 21)
  surfaced as a yellow advisory row**, distinct from the five red error bits.
- **Device Name characteristic.** Name a unit from Settings, enforced at **20 UTF-8
  bytes, not 20 characters** (the editor counts and truncates on bytes, never
  splitting a scalar). A one-time, skippable naming sheet is offered on connect for
  a unit still reporting its factory default name, and never shown again for that
  peripheral.
- **LED brightness slider**, 5–100 %, pre-populated from settings byte 8 and
  debounced to a single 12-byte write on release.
- **Sensor maintenance** in Settings: *Clean sensor fan* (`0x0D`, ~12 s, disabled
  while the sensor is warming because firmware ignores it then), *Clear sensor
  errors* (`0x0F`), and *Calibrate CO₂ outdoors* (`0x0E` at 400 ppm, behind a
  confirmation alert stating the ≥ 3 minutes outdoors requirement).
- **Device Info diagnostics** — serial, SEN66 firmware, contract version (red row
  and explanation when it is not 2), and log record version.
- **Incompatible-firmware guard.** A device reporting a contract or log-record
  version this build does not implement has its live packets **refused**, with a
  full-screen explanation, rather than decoded into plausible-looking numbers.
  An all-zero Device Info is treated as "no SEN66 attached at boot" — which is
  what firmware reports in that case — not as a version mismatch.
- **Sensor-disconnected state.** Status bit 0 clear now reads as "Sensor
  disconnected" instead of a screen of dashes presented as readings.
- **MTU guard** in diagnostics: the 52-byte packet needs an ATT MTU of at least
  55, and a smaller negotiated value is flagged red. The value is sampled once
  the link is fully up and refreshed on the RSSI tick — sampling it at
  `didConnect`, as the first revision did, always reported the 23-byte default
  because iOS performs the ATT MTU exchange asynchronously after connecting.
- **Golden-vector test target** (`G2-iOSTests`, Swift Testing) — see Tests below.

#### Changed
- **"TVOC Auto" is now "Custom".** Opcode `0x0A` is unchanged, but its thresholds
  are a **VOC index (1–500)**, not TVOC ppb. `TVOCThresholds` → `VOCThresholds`,
  defaults 150/350/650/1000 → **100/150/250/400**, Settings header
  "FAN MAPPING (CUSTOM)".
- **The fan mode picker mirrors the device** (live byte 34) instead of holding
  app-local state. A device-driven update no longer echoes back as a command;
  selecting Manual sends the on-screen speed, since Manual has no mode opcode.
- **Air-quality hero is `aq_class`**, derived in firmware (worst component wins
  across VOC, NOx, CO₂ and PM) and never re-derived in the app — the band edges
  live in firmware and are pending client sign-off. `AQILevel.warmingUp` became
  `.unknown`, rendering as "Warming up" only when status bit 2 is set and "—"
  otherwise.
- **Freshness** combines the device's own "fresh this tick" flag (status bit 1)
  with packet age, so a repeated cached sample reads as "Live — repeating last
  sample" rather than as a new reading.
- **History chart metric picker** is now a `.menu` picker: eight metrics
  (Temp/RH, VOC index, NOx index, CO₂, PM1.0, PM2.5, PM4.0, PM10) no longer fit a
  segmented control.
- **CSV export columns** follow log-record v2 field order — `voc_index`,
  `nox_index`, `co2_ppm`, `pm4_ugm3` and the new status bits replace `tvoc_ppb`,
  `eco2_ppm` and the AHT21/ENS160/BMV080 columns.
- **Scan list** refreshes a peripheral's advertised name on every advertisement,
  not just its RSSI, so a renamed unit updates in place. It reads
  `CBAdvertisementDataLocalNameKey` **only** — `peripheral.name` is deliberately
  not consulted, because iOS caches it and can keep showing a unit's *old*
  nickname for the lifetime of the app install. A peripheral advertising no local
  name falls back to the neutral product label; the row's identifier suffix
  disambiguates units.
- **Both parsers guard on exact length** (`== 52` live, `== 34` history) rather
  than a minimum, per the handoff note. An over-length payload is reported as a
  contract violation instead of being silently decoded from its first N bytes.
- **`0x0E` is range-checked client-side** (350–2000 ppm) so a reference the
  firmware would reject with an ATT error is never written.
- **Simulator** synthesises real 52-byte v2 live packets and 34-byte history
  packets through the production parsers, including a warm-up window, PM and
  over-range sentinels, and a fan-speed warning.

#### Removed
- `tvoc`/`eco2` from the history record — **removed, not renamed**: a VOC index is
  not a ppb concentration and SEN66 CO₂ is measured rather than equivalent.
- The eight fake advertising-header bytes that prefixed the v1 live payload;
  `sensorPayloadDecodeOffset` is now 0.
- The AHT21 / ENS160 / BMV080 status-bit labels, replaced by the v2 bit map.

#### Migration
- **Cached history is discarded.** The `ModelContainer` now points at a new store
  file (`history-v2.store`) and the pre-v2 store (plus its WAL/SHM sidecars) is
  deleted on first launch. The app is pre-1.0 with no production data, so there is
  no versioned SwiftData migration — the record's *semantics* changed, not just
  its shape.
- A firmware **log-record version change** additionally wipes every cached row on
  the first sync of a launch, tracked in `UserDefaults`.
- Firmware erases its own flash ring on first boot of the SEN66 build, so expect
  an empty history until records accumulate at ~1/min.

#### Tests
`G2-iOSTests` (Swift Testing), **51 tests in 6 suites, all passing**. Payloads are
hand-authored golden vectors written from the firmware byte tables — not produced
by the app's own encoders, which would pass even if both sides drifted together.

Covered: a fully valid 52-byte packet (every field, in display units) · all-invalid
sentinels · PM `0xFFFE` over-range (and that `0xFFFE` is *not* folded away for
non-PM fields) · warming state (bit 2 + aq_class 0) vs. plain unknown · rejection
of a 31-byte legacy packet, a legacy `0x02` marker, a stray history marker, an
unexpected payload version and an over-length payload · short and sliced payloads ·
the `0x0E` reference range and the three new opcodes · a 34-byte history packet
and its end-of-sync sentinel · rejection of 31-byte v1 history · 12-byte settings
encode/decode round-trip with brightness floor/ceiling clamping · threshold
monotonicity and 1–500 range · fan-mode wire mapping · device-name byte-length
validation with multi-byte UTF-8 and scalar-safe truncation · 40-byte Device Info
including a wrong contract version and an absent sensor.

Build: **BUILD SUCCEEDED**, **zero compiler warnings**, Swift 6 strict
concurrency, iOS 17.0 target. Verified running in Simulator: warm-up → live
transition, all nine metric tiles, mode picker mirroring, the naming sheet
appearing once and not again, the `.menu` metric picker, and VOC-index history
charting.

---

### History CSV export and branding update

#### Added
- **History CSV export** — tap the share icon in the History tab to export
  cached records as a `.csv` file. Choose scope: selected time range (24h/7d/30d/60d)
  or all cached history. File is streamed in 4000-row chunks to keep memory
  footprint flat even over a full 90-day cache. Exported file name includes
  device ID, scope, and export timestamp.

#### Fixed
- **CSV share reliability.** The original share flow generated the file lazily
  inside a Transferable provider *after* a share target was picked, which let
  targets (Mail especially) intermittently receive an unready file; it also
  wiped the whole export folder on every run (racing any still-open share
  sheet) and recomputed the filename per access. The export now fully writes
  the CSV first (toolbar spinner while it streams), into a unique per-export
  folder with hourly stale cleanup, then presents the system share sheet with
  the finished file; failures surface in an alert. Verified in Simulator:
  full export (5,760 rows), scoped 24h export (97 rows), and back-to-back
  exports leaving the earlier file intact.

#### Changed
- **Product branding** — renamed from "GEUE Air Quality" to "Smart Air System"
  throughout the UI (home screen, scan screen, Bluetooth permission strings,
  settings pane references). Internal identifiers and bundle ID are unchanged.

### Ionizer power/health state monitoring

#### Added
- **Ionizer health bit** (DeviceStatus bit 5) — read-only monitoring of ionizer
  operational status. Status byte bit 5 = 1 indicates the ionizer is healthy
  and operational.
- **Conditioning tab** (replaces Fan tab in MainTabView) — combines fan speed
  control with ionizer health display. Provides unified air-conditioning
  control and monitoring surface.
- **ConditioningView** — shows current fan speed, fan control modes (Auto,
  TVOC Auto, Manual), and ionizer health status card with visual indicators.
  Fan control is the same as the legacy FanView; ionizer is read-only per
  spec.

#### Changed
- **MainTabView** now shows "Conditioning" tab instead of "Fan" (SystemImage
  `air.purifier.fill`). The legacy FanView remains in Views/Fan/ for
  backward compatibility but is not used in the main UI.

### Incremental sync, per-device caching, background persistence

> Matches the firmware's reworked history protocol (`BLE_HISTORY_PROTOCOL.md`):
> u24 packet header, incremental newest-N sync, and the RTC-failure timestamp
> caveat. Also restructures the app's caching layer for multiple devices and
> smooth rendering over a full 90-day cache.

#### Added
- **Incremental sync (opcode `0x0C` + u32 LE count).** When a device already has a
  cache, the app requests only the newest N records (minutes-behind + a 30-record
  margin) instead of re-streaming the whole history; records are deduped by
  timestamp. Full dump (`0x01`) is used on first sync or when the cache is stale
  beyond retention. A `count 0` sentinel-only handshake is supported.
- **Per-device caching.** `HistoryRecord.deviceID` scopes every record to a monitor,
  keyed by the last two bytes of the peripheral's Bluetooth identifier (iOS hides
  the raw MAC; this matches the short ID in the scan list). Connected device wins;
  after disconnect the History tab keeps showing the last-synced device.
- **90-day rolling retention.** After every completed sync the cache is pruned to
  the trailing 90 days per device (~130k records ≈ < 3 MB) — oldest records fall
  off as new ones arrive.
- **Sync progress bar.** u24 `index`/`total` are sync-relative and reliable, so the
  History tab now shows a real transfer fraction (throttled to 1% steps), including
  during a long first full dump from the empty state.

#### Changed
- **History packet header widened u16 → u24** (`total` @2–4, `index` @5–7); the
  22-byte record moved to packet bytes 8–29. Validated against the protocol doc's
  test vectors (recent-5, count-0 handshake, >65k index/total, PM sentinels,
  live-packet rejection, `0C 05 00 00 00` command encoding).
- **All heavy persistence moved off the main thread** onto a new `HistoryDataStore`
  `@ModelActor`: batched inserts (500/batch), timestamp dedupe, pruning, and
  chunked chart aggregation. `HistoryStore` no longer keeps every record in memory
  — it holds precomputed chart series and a 200-row list page (header shows the
  true in-range count). Fixes UI lag when the cache holds weeks of 1/min data.
- **Unanchored timestamps skipped.** If the RTC was unreadable at log time the
  record's timestamp is seconds-since-boot; pre-2020 timestamps are rejected during
  caching so they can't corrupt time-keyed ordering/dedup.
- Mock data generation also runs through the actor (no more first-launch hitch) and
  is scoped under device ID `MOCK`.

### SYNC_HISTORY record layout corrected (superseded by the u24 rework above)

> An earlier spec draft had the flash record layout wrong; the firmware handoff
> (read from `ble_service.c` / `log_store.h`, validated against 6 golden rows)
> corrected it. Folded into the entry above, noted here for review context.

#### Fixed
- **Record byte order — timestamp is FIRST** in `geue_log_record_t` (then temp/
  humidity/TVOC/eCO₂/AQI/status/seq, then PM). The previous layout (temperature
  first, timestamp mid-record) mis-decoded **every** history field.
- **End-of-sync detection** is the **all-zero record sentinel**, never
  `index == total` — the old u16 fields wrapped past 65,535 records and would have
  truncated a 90-day sync roughly halfway.
- Live sensor packets (`payload[0] == 0x02`) interleaving during a history stream
  are rejected by the history parser (demux on byte 0).

### Live history sync by default

#### Changed
- **`historyDataSource` default is now platform-conditional** — `.ble` on device (the
  History tab syncs real records from the connected prototype), `.mock` in the
  Simulator (no BLE radio, so synthetic data keeps the history UI developable).
- **Switching sources clears stale rows.** The composition root remembers the active
  source in `UserDefaults`; when it changes between launches, `HistoryRecord`s from
  the previous source are wiped so leftover mock data can't masquerade as device data.
- A history sync now clears existing rows **and persists that clear up front**, so a
  full device snapshot always replaces whatever was there (mock or prior sync).

#### Added
- **History-sync inactivity timeout** (`BluetoothManager.historyInactivityTimeout`,
  ~6 s). A single poller ends the stream if no packet arrives, so firmware that
  doesn't answer `SYNC_HISTORY` produces an honest **`.noRecords`** result (new
  `HistorySyncResult` case, surfaced in the History sync-status row) instead of an
  endless spinner. A healthy sync refreshes the timer per packet and never trips it.

### History PM logging + sentinel fix — matches firmware changelog **2026-07-09**

> Firmware/embedded reviewers: the flash log record grew **16 → 22 bytes** ("PM Data
> in Flash Log"). iOS now decodes and charts PM history, and folds the shared PM
> over-range sentinel. Byte offsets are in [`BLE/GATT.swift`](G2-iOS/BLE/GATT.swift)
> and [`BLE/HistoryPacketParser.swift`](G2-iOS/BLE/HistoryPacketParser.swift).

#### Added
- **PM logged in history.** `HistoryPacketParser` now decodes the 22-byte record
  (PM1.0/PM2.5/PM10 at record bytes 16–21; packet framing unchanged at 31 bytes).
  `HistoryRecord` gains `pm1`/`pm25`/`pm10` (`Int?`, matching `SensorReading`'s
  live PM naming). `BLEHistoryRepository` maps them on insert; `MockHistoryRepository`
  generates plausible PM so `.mock` exercises the same UI paths as `.ble`.
- **PM in the History UI.** `HistoryMetric` splits the old single `.pm` placeholder
  into selectable `pm1`/`pm25`/`pm10` series; they chart and appear in the record
  drill-down. The "PM is not logged" placeholder is gone.

#### Fixed
- **Live `0xFFFE` PM bug.** PM has two invalid sentinels — `0xFFFF` (no reading)
  and `0xFFFE` (over-range). The live `SensorParser` previously only checked
  `0xFFFF`, so an over-range PM rendered as a bogus `65534 µg/m³`. Both are now
  folded to invalid (`—`) via a single shared `GATT.decodePM`, called from both the
  live and history parsers. (Sam's call: no distinct over-range UI.)

#### Changed
- **History chart metrics restructured.** Temperature and Humidity are now a single
  **dual-axis overlay** (`Temp/RH` — temperature °C on the left axis, humidity % on
  the right, color-coded with a legend) instead of two separate single-series picks.
  **AQI removed** as a chart metric (still shown on the Dashboard hero, history-row
  color dot, and record detail). Picker is now 6 items: Temp/RH · TVOC · eCO₂ ·
  PM1.0 · PM2.5 · PM10.
- **`DeviceStatus` bit 3** relabeled "TWAI (CAN) node initialised" → **"TWAI (CAN)
  node online"** to match firmware (initialised **and** not bus-off). Bits 5–7 remain
  unlabeled (firmware defines no meaning). Verify-only pass, no other bits changed.
- Simulator generator emits PM (including occasional sentinels) so Simulator runs
  exercise the same parser path as hardware.
- **No SwiftData migration** — pre-1.0, no production data; the new PM fields are
  optional (lightweight/additive). If a dev machine has a stale local store, delete
  the app from the simulator rather than writing a versioned migration.

### BLE ⇄ firmware command wiring — matches firmware changelog **2026-06-29**

> Firmware/embedded reviewers: this is the section for you. The iOS side now speaks
> the current GATT contract 1:1. Opcodes, byte offsets, and the demux rule below are
> mirrored from the firmware changelog and are the app's source of truth in
> [`BLE/GATT.swift`](G2-iOS/BLE/GATT.swift).

#### Added
- **`CMD_SYNC_HISTORY` (`0x01`) — real history streaming.**
  `BluetoothManager.startHistorySync()` sends the opcode and returns an
  `AsyncStream<HistoryStreamEvent>`. History records arrive as notifications on the
  **Sensor Data characteristic** (`7A3E4F5C-…`) and are demuxed from live data by
  `payload[0]` (`0x02` = live, `0xA5` = history). Streaming stops on the end-of-sync
  sentinel (`recordIndex == totalCount`) or when the link drops.
  - New file [`BLE/HistoryPacketParser.swift`](G2-iOS/BLE/HistoryPacketParser.swift)
    decodes the 31-byte history packet (`0xA5 0x48`, total-count, index,
    `geue_log_record_t` at bytes 6–27, timestamp `uint32` LE at record bytes 12–15).
    (Record grew 16 → 22 bytes for PM in the 2026-07-09 entry above.)
  - [`History/BLEHistoryRepository.swift`](G2-iOS/History/BLEHistoryRepository.swift)
    now **fully implemented**: clears stale rows, inserts each streamed record into
    SwiftData, returns `.completed(count:)` on the sentinel. A mid-sync disconnect
    saves what arrived and reports `.notConnected`.
- **`SET_TIME` (`0x0B`) — DS3231 RTC clock sync.**
  `BluetoothManager.setDeviceTime(_:)` writes the 8-byte payload
  `[0x0B, sec, min, hr, wday, mday, mon, yr2k]`, all **raw decimal** (firmware does
  the BCD encoding). Calendar's `1=Sunday` is mapped to firmware's `0=Sunday`;
  `yr2k` is clamped to 0–99. Wired to the **"Sync device clock"** button in
  [`Views/Settings/SettingsView.swift`](G2-iOS/Views/Settings/SettingsView.swift)
  (disabled while disconnected).
- **GATT constants** for the history demux (`historyPacketMarker 0xA5`,
  `historyHeaderMarker 0x48`, count/index/record offsets) and the `setTime` opcode
  in `GATT.Command`.

#### Changed
- `HistorySyncTransport` protocol replaced the fire-and-forget
  `sendSyncHistoryCommand()` with `startHistorySync() -> AsyncStream<HistoryStreamEvent>`.
- `handleValueUpdate` on the Sensor characteristic now branches on `payload[0]`
  before parsing, so live readings and history packets share one CCCD subscription.
- `teardownConnection` finishes any in-flight history stream continuation so a
  consumer's `for await` exits cleanly on disconnect.
- New `HistoryRecordFields` (`Sendable` struct) and `HistoryStreamEvent` enum carry
  parsed values across the stream boundary without touching `@Model` objects.

#### Removed
- `HistorySyncResult.notSupportedByFirmware`. History is now supported by firmware,
  so the case and its UI branches in `HistoryView` are gone. **Behavior change for
  the app team:** syncing against firmware that ships this changelog returns
  `.completed(count:)`; older firmware simply streams nothing and reports
  `.notConnected`/empty rather than a "not supported" message.

---

### Full app rebuild — "G2" (from scratch)

The client was **reimplemented from scratch** against the GATT contract (not a port
of the previous app). SwiftUI-only, MVVM with `@Observable` view models, a single
BLE manager that owns all `CBPeripheral` state, and defensive length-checked parsing
with no force-unwraps on BLE data.

#### Added
- **BLE layer** ([`BLE/`](G2-iOS/BLE)) — `BluetoothManager`
  (`@MainActor @Observable`, CoreBluetooth on a dedicated dispatch queue, `nonisolated`
  delegate shims that marshal `Sendable` values to the main actor), `GATT` contract,
  `SensorParser` (31-byte payload, decode offset 8), `ConnectionState`.
- **Models** ([`Models/`](G2-iOS/Models)) — `Metric<Value>`
  (valid / invalid-sentinel), `AQILevel`, `SensorReading`, `DeviceStatus` (byte-24
  bitfield), `TVOCThresholds` (monotonic validation + LE encode/decode), `FanMode`,
  `DiscoveredDevice`.
- **History layer** ([`History/`](G2-iOS/History)) — SwiftData
  `HistoryRecord` (@Model, flash-record shape; PM added in the 2026-07-09 entry above),
  `HistoryRepository` protocol with a `HistoryDataSource` DI switch,
  `MockHistoryRepository` (60 days of realistic data) and `BLEHistoryRepository`,
  `HistoryStore` view model (bucketed chart aggregation), `HistoryMetric`.
- **Views** ([`Views/`](G2-iOS/Views)) — `ScanView`, connected
  `MainTabView` (Dashboard · Fan · History · Settings, each in its own
  `NavigationStack` with a persistent connection chip), `DashboardView` (live
  freshness via `TimelineView`), `FanView` (debounced slider + presets),
  `HistoryView` (Swift Charts time-series + drill-down list), `SettingsView`
  (TVOC threshold editor + diagnostics + clock sync), shared components
  (command-feedback toast, signal strength, connection chip).
- **App shell** ([`App/`](G2-iOS/App)) — `RootView` (phase-gated
  Scan ⇄ connected), `Theme` (true-dark, cyan accent), SwiftData `ModelContainer`
  wiring in `G2_iOSApp`.
- **Simulator support** — `#if targetEnvironment(simulator)` path in
  `BluetoothManager` synthesizes devices/readings through the **real** parser (no
  Bluetooth radio in Simulator); compiled out of device builds.
- **Docs** — [`README.md`](README.md) documenting the DI switch, stubs/TODOs, and
  the full GATT parser mapping.

#### Changed
- Project settings: deployment target **26.x → 17.0**, `SWIFT_VERSION` **5.0 → 6.0**,
  Bluetooth usage-string typo fixed. Bundle id kept as `GEUE.Smart-Air-Monitor`.
- Xcode 26 filesystem-synchronized groups (`objectVersion 77`): new Swift files are
  picked up from disk automatically — **no `.pbxproj` edits needed** to add files.

#### Removed
- Legacy sources: `AirQualityData.swift`, root-level `BluetoothManager.swift`,
  `ContentView.swift`, root-level `DiscoveredDevice.swift`. Replaced by the layered
  structure above.

---

## Action items for the team

- **Pull and open in Xcode 26+.** Build target is iOS 17.0, Swift 6 strict
  concurrency. Latest clean build: **BUILD SUCCEEDED**, zero warnings
  (iPhone 17 Pro simulator, Debug).
- **Firmware dependency:** live history sync and clock sync require firmware carrying
  the **2026-06-29** changelog (`CMD_SYNC_HISTORY` streaming + `CMD_SET_TIME`).
  Against older firmware the app degrades gracefully (empty history, no clock write).
- **History data source is a one-line DI switch** in
  [`G2_iOSApp.swift`](G2-iOS/G2_iOSApp.swift):
  `historyDataSource = .mock` (default, fully populated UI for design/dev) vs `.ble`
  (real device streaming). Flip to `.ble` for on-hardware testing.
- **Simulator:** everything is exercisable without hardware; readings are synthetic
  but flow through the production parser. History streaming is device-only.
- **Not yet committed.** This is the first rebuild drop — review, then squash/merge
  over `Initial Commit` as `1.0.0`.
