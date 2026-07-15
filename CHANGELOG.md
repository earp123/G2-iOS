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

### BLE ⇄ firmware command wiring — matches firmware changelog **2026-06-29**

> Firmware/embedded reviewers: this is the section for you. The iOS side now speaks
> the current GATT contract 1:1. Opcodes, byte offsets, and the demux rule below are
> mirrored from the firmware changelog and are the app's source of truth in
> [`BLE/GATT.swift`](Smart%20Air%20Monitor/BLE/GATT.swift).

#### Added
- **`CMD_SYNC_HISTORY` (`0x01`) — real history streaming.**
  `BluetoothManager.startHistorySync()` sends the opcode and returns an
  `AsyncStream<HistoryStreamEvent>`. History records arrive as notifications on the
  **Sensor Data characteristic** (`7A3E4F5C-…`) and are demuxed from live data by
  `payload[0]` (`0x02` = live, `0xA5` = history). Streaming stops on the end-of-sync
  sentinel (`recordIndex == totalCount`) or when the link drops.
  - New file [`BLE/HistoryPacketParser.swift`](Smart%20Air%20Monitor/BLE/HistoryPacketParser.swift)
    decodes the 31-byte history packet (`0xA5 0x48`, total-count, index, 16-byte
    `geue_log_record_t` at bytes 6–21, timestamp `uint32` LE at record bytes 12–15).
  - [`History/BLEHistoryRepository.swift`](Smart%20Air%20Monitor/History/BLEHistoryRepository.swift)
    now **fully implemented**: clears stale rows, inserts each streamed record into
    SwiftData, returns `.completed(count:)` on the sentinel. A mid-sync disconnect
    saves what arrived and reports `.notConnected`.
- **`SET_TIME` (`0x0B`) — DS3231 RTC clock sync.**
  `BluetoothManager.setDeviceTime(_:)` writes the 8-byte payload
  `[0x0B, sec, min, hr, wday, mday, mon, yr2k]`, all **raw decimal** (firmware does
  the BCD encoding). Calendar's `1=Sunday` is mapped to firmware's `0=Sunday`;
  `yr2k` is clamped to 0–99. Wired to the **"Sync device clock"** button in
  [`Views/Settings/SettingsView.swift`](Smart%20Air%20Monitor/Views/Settings/SettingsView.swift)
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
- **BLE layer** ([`BLE/`](Smart%20Air%20Monitor/BLE)) — `BluetoothManager`
  (`@MainActor @Observable`, CoreBluetooth on a dedicated dispatch queue, `nonisolated`
  delegate shims that marshal `Sendable` values to the main actor), `GATT` contract,
  `SensorParser` (31-byte payload, decode offset 8), `ConnectionState`.
- **Models** ([`Models/`](Smart%20Air%20Monitor/Models)) — `Metric<Value>`
  (valid / invalid-sentinel), `AQILevel`, `SensorReading`, `DeviceStatus` (byte-24
  bitfield), `TVOCThresholds` (monotonic validation + LE encode/decode), `FanMode`,
  `DiscoveredDevice`.
- **History layer** ([`History/`](Smart%20Air%20Monitor/History)) — SwiftData
  `HistoryRecord` (@Model, 16-byte flash-record shape; PM intentionally absent),
  `HistoryRepository` protocol with a `HistoryDataSource` DI switch,
  `MockHistoryRepository` (60 days of realistic data) and `BLEHistoryRepository`,
  `HistoryStore` view model (bucketed chart aggregation), `HistoryMetric`.
- **Views** ([`Views/`](Smart%20Air%20Monitor/Views)) — `ScanView`, connected
  `MainTabView` (Dashboard · Fan · History · Settings, each in its own
  `NavigationStack` with a persistent connection chip), `DashboardView` (live
  freshness via `TimelineView`), `FanView` (debounced slider + presets),
  `HistoryView` (Swift Charts time-series + drill-down list), `SettingsView`
  (TVOC threshold editor + diagnostics + clock sync), shared components
  (command-feedback toast, signal strength, connection chip).
- **App shell** ([`App/`](Smart%20Air%20Monitor/App)) — `RootView` (phase-gated
  Scan ⇄ connected), `Theme` (true-dark, cyan accent), SwiftData `ModelContainer`
  wiring in `Smart_Air_MonitorApp`.
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
  [`Smart_Air_MonitorApp.swift`](Smart%20Air%20Monitor/Smart_Air_MonitorApp.swift):
  `historyDataSource = .mock` (default, fully populated UI for design/dev) vs `.ble`
  (real device streaming). Flip to `.ble` for on-hardware testing.
- **Simulator:** everything is exercisable without hardware; readings are synthetic
  but flow through the production parser. History streaming is device-only.
- **Not yet committed.** This is the first rebuild drop — review, then squash/merge
  over `Initial Commit` as `1.0.0`.
