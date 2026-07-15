# Changelog

All notable changes to the **GEUE Smart Air Monitor** iOS client.
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
