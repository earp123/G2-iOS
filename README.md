# GEUE Smart Air Monitor — iOS App

SwiftUI rebuild of the GEUE Air Quality (G2) iOS client.  
Target: **iOS 17.0+**, **Swift 6 strict concurrency**, zero third-party dependencies.

---

## 1. Repository layout

```
G2-iOS/
├── App/                   Entry point, root view, theme
│   ├── G2_iOSApp.swift   DI switch (see §2)
│   ├── RootView.swift
│   └── Theme.swift
├── BLE/                   CoreBluetooth layer
│   ├── GATT.swift          UUIDs, opcodes, payload constants
│   ├── SensorParser.swift  31-byte payload decoder
│   ├── BluetoothManager.swift
│   └── ConnectionState.swift
├── Models/                Value types shared across layers
│   ├── Metric.swift        Metric<Value> (valid / invalid sentinel)
│   ├── AQILevel.swift
│   ├── SensorReading.swift
│   ├── DeviceStatus.swift
│   ├── DiscoveredDevice.swift
│   └── TVOCThresholds.swift
├── History/               SwiftData persistence + repository layer
│   ├── HistoryRecord.swift       @Model — one logged reading
│   ├── HistoryRepository.swift   Protocol + HistorySyncTransport
│   ├── MockHistoryRepository.swift
│   ├── BLEHistoryRepository.swift  (stub — see §3)
│   ├── HistoryMetric.swift
│   └── HistoryStore.swift
└── Views/
    ├── Scan/              Pre-connection device scanner
    ├── Connected/         Tab shell + connection chip
    ├── Dashboard/         Live readings
    ├── Fan/               Fan control
    ├── History/           Chart + drill-down list
    └── Settings/          TVOC threshold editor + diagnostics
```

The project uses `PBXFileSystemSynchronizedRootGroup` (Xcode 26, objectVersion 77).  
New Swift files dropped into any group folder are compiled automatically — no pbxproj edits required.

---

## 2. History data-source DI switch

**File:** [`G2-iOS/App/G2_iOSApp.swift`](G2-iOS/App/G2_iOSApp.swift)

```swift
#if targetEnvironment(simulator)
private static let historyDataSource: HistoryDataSource = .mock   // no BLE radio in the Simulator
#else
private static let historyDataSource: HistoryDataSource = .ble    // live device sync
#endif
```

Default is platform-conditional: **`.ble` on device**, **`.mock` in the Simulator** (which has no BLE radio). Override either branch to force a source.

| Value | Behaviour |
|-------|-----------|
| `.ble` **(device default)** | `BLEHistoryRepository` — incremental sync (opcode `0x0C` newest-N) when a cache exists, full dump (opcode `0x01`) on first sync or when the cache is stale beyond retention. Records stream via `HistoryStreamEvent` and persist through the `HistoryDataStore` actor. |
| `.mock` **(Simulator default)** | `MockHistoryRepository` — 60 days × ~4 samples/hour of synthetic data with diurnal variation and cooking/cleaning spikes, generated under device ID `MOCK`. Works offline and in Simulator. |

Switching the constant is the **only** change needed to flip data sources; views, `HistoryStore`, and SwiftData are unchanged.

**Switching sources clears stale rows.** The composition root records the active source + cache generation in `UserDefaults`; when either changes between launches, persisted `HistoryRecord`s are wiped so old rows never masquerade as fresh history.

**Sync robustness.** A history sync ends on the end-of-sync sentinel, on link loss, or after ~6 s with no packet (`historyInactivityTimeout`) — so firmware that doesn't answer a sync command yields an honest `.noRecords` result instead of an endless spinner. On the live device, the History tab starts empty until you pull-to-refresh / tap **Sync**; the live **Dashboard** is unaffected (always live BLE, no mock path on-device).

## 2b. Per-device caching & memory model

- **Multi-device:** every `HistoryRecord` carries a `deviceID` — the last two bytes of the peripheral's Bluetooth identifier (e.g. `"9A2B"`, matching the short ID in the scan list). iOS hides the real BLE MAC, so this is derived from CoreBluetooth's stable per-device UUID. All queries and syncs are scoped to the connected device; after disconnect the History tab keeps showing the most recently synced one.
- **Retention:** after every completed sync the cache is pruned to the trailing **90 days** per device (`HistoryDataStore.retention`) — bounded at ~130k records ≈ < 3 MB.
- **Memory/UI:** heavy work lives on the `HistoryDataStore` `@ModelActor` — batched inserts (500/batch), timestamp dedupe, pruning, and chunked chart aggregation all run off the main thread; only small `Sendable` value arrays cross to the UI. The drill-down list fetches at most 200 rows (`HistoryStore.listLimit`); the header shows the true in-range total.
- **Unanchored timestamps:** if the device's RTC was unreadable at log time, the record's timestamp is seconds-since-boot; anything before 2020-01-01 is treated as unanchored and skipped during caching so it can't corrupt time-keyed sorting/dedup.

---

## 3. Stubs and firmware TODOs

### 3.1 History sync — `BLEHistoryRepository`

**File:** [`G2-iOS/History/BLEHistoryRepository.swift`](G2-iOS/History/BLEHistoryRepository.swift)

**Implemented.** `BLEHistoryRepository.syncHistory()` picks the mode from the device's cached high-water mark: empty/stale cache → **full dump** (`0x01`); otherwise **incremental** (`0x0C` + u32 LE count), where count = minutes-behind + a 30-record safety margin (records are ~1/min but gaps happen). `BluetoothManager.handleValueUpdate` demuxes notifications on the Sensor characteristic by `payload[0]`: `0x02` = live → `SensorParser`; `0xA5` = history → `HistoryPacketParser` → the `AsyncStream`. Live packets keep arriving during a stream and are handled normally. Batches of 500 records go to the `HistoryDataStore` actor, which **dedupes by timestamp** (re-syncing is idempotent), skips unanchored timestamps, and saves incrementally. The stream finalizes on the **all-zero-record end-of-sync sentinel** (always sent, even for a count-0 handshake); u24 `index`/`total` drive the progress bar. After completion the cache is pruned to 90 days and `.completed(count:)` reports the true store count. A dropped stream has no resume/ACK — the next sync just picks up incrementally.

### 3.2 Time synchronisation — `SettingsView`

**File:** [`G2-iOS/Views/Settings/SettingsView.swift`](G2-iOS/Views/Settings/SettingsView.swift)

**Implemented.** "Sync device clock" calls `BluetoothManager.setDeviceTime()`, which builds the 8-byte opcode `0x0B SET_TIME` payload and writes it to the Command characteristic. All 7 date fields are raw decimal (not BCD); `wday` is mapped from Calendar's 1=Sun convention to firmware's 0=Sun convention. The button is disabled when not connected.

### 3.3 Simulator BLE stub — `BluetoothManager`

**File:** [`G2-iOS/BLE/BluetoothManager.swift`](G2-iOS/BLE/BluetoothManager.swift)

iOS Simulator has no CoreBluetooth radio. The `#if targetEnvironment(simulator)` extension provides:

- `startSimulatedScan()` — emits two synthetic `DiscoveredDevice` entries with jittered RSSI
- `connectSimulated(to:)` — 750 ms connecting + 400 ms discovering delays, then `.connected`
- `emitSimulatedReading()` — builds a real 31-byte packet and feeds it through production `SensorParser`
- `debugAutoConnect()` — called from `RootView.task` when `GEUE_SIM_AUTOCONNECT=1`

This code is **excluded from device builds** at compile time; it adds zero overhead on real hardware.

---

## 4. GATT sensor payload mapping

**Source of truth:** [`G2-iOS/BLE/GATT.swift`](G2-iOS/BLE/GATT.swift) and [`G2-iOS/BLE/SensorParser.swift`](G2-iOS/BLE/SensorParser.swift)

### Sensor characteristic (`0x7A3E4F5C-…`)

READ + NOTIFY, **31-byte** payload, little-endian multi-byte fields.

> Bytes 0–7 are embedded BLE advertising-header bytes carried inside the GATT payload.  
> Decoding begins at **byte 8** (`GATT.sensorPayloadDecodeOffset = 8`).

| Byte offset (abs) | Offset from byte 8 | Field | Type | Scale | Sentinel → `Metric.invalid` |
|---|---|---|---|---|---|
| 8–9 | +0 | Temperature | `Int16` LE | ÷ 100 → °C | `0x8000` (INT16_MIN) |
| 10–11 | +2 | Relative Humidity | `UInt16` LE | ÷ 100 → % | `0xFFFF` |
| 12–13 | +4 | TVOC | `UInt16` LE | raw ppb | `0xFFFF` |
| 14–15 | +6 | eCO₂ | `UInt16` LE | raw ppm | `0xFFFF` |
| 16–17 | +8 | PM1.0 | `UInt16` LE | raw µg/m³ | `0xFFFF` / `0xFFFE` (via `GATT.decodePM`) |
| 18–19 | +10 | PM2.5 | `UInt16` LE | raw µg/m³ | `0xFFFF` / `0xFFFE` (via `GATT.decodePM`) |
| 20–21 | +12 | PM10 | `UInt16` LE | raw µg/m³ | `0xFFFF` / `0xFFFE` (via `GATT.decodePM`) |
| 22 | +14 | AQI level | `UInt8` | `AQILevel(raw:)` 0–5 | n/a |
| 23 | +15 | Fan speed | `UInt8` | raw 0–100 % | n/a |
| 24 | +16 | Device status | `UInt8` | `DeviceStatus(raw:)` bitmask | n/a |
| 25–26 | +17 | Sequence number | `UInt16` LE | raw counter | n/a |
| 27–30 | +19 | Reserved | — | ignored | — |

The parser length-guards the entire payload before touching any byte:
```swift
guard data.count >= GATT.sensorPayloadLength else { return .failure(.malformedPacket(...)) }
```
A short packet returns `.failure` rather than crashing.

### Command characteristic (`0x7A3E4F5D-…`)

WRITE + WRITE_NO_RSP.

| Opcode | Bytes | Description |
|--------|-------|-------------|
| `0x01` | 1 | `SYNC_HISTORY` — triggers history streaming on the Sensor characteristic |
| `0x02` | 2 | `FAN_MANUAL [pct: u8]` — exact speed 0–100 % |
| `0x03` | 1 | `FAN_AUTO` — AQI-driven |
| `0x04` | 1 | `FAN_OFF` (manual 0 %) |
| `0x05` | 1 | `FAN_LOW` (manual 25 %) |
| `0x06` | 1 | `FAN_MED` (manual 50 %) |
| `0x07` | 1 | `FAN_HIGH` (manual 75 %) |
| `0x08` | 1 | `FAN_MAX` (manual 100 %) |
| `0x09` | 1 | `GET_STATUS` — force an immediate sensor notification |
| `0x0A` | 1 | `FAN_TVOC_AUTO` — setpoint-driven auto (uses Settings thresholds) |
| `0x0B` | 8 | `SET_TIME [sec min hr wday mday mon yr2k]` — set DS3231 RTC; all raw decimal |
| `0x0C` | 5 | `SYNC_RECENT [count: u32 LE]` — stream the newest N records; `count 0` = sentinel-only handshake |

ATT error `0x0E` = unknown opcode. Surfaced in the UI via `CommandFeedback.rejected`.

### Settings characteristic (`0x7A3E4F5E-…`)

READ + WRITE, **8-byte** payload: four `UInt16` LE TVOC thresholds in ppb.

| Bytes | Field | Default (ppb) |
|-------|-------|-------------|
| 0–1 | `lo` threshold | 150 |
| 2–3 | `med` threshold | 350 |
| 4–5 | `hi` threshold | 650 |
| 6–7 | `max` threshold | 1000 |

Thresholds must be strictly increasing (`lo < med < hi < max`); the app validates this before writing and disables the Save button otherwise.

### History sync packet (31 bytes, on Sensor characteristic)

After a sync command (`0x01` full dump, or `0x0C` + u32 LE count for the newest N records), the device streams records as notifications on the **Sensor characteristic** (same UUID, same CCCD subscription — subscribe **before** writing the command or the firmware silently ignores it). Framing per `BLE_HISTORY_PROTOCOL.md`:

**Demux rule:** `payload[0] == 0x02` → live sensor data; `payload[0] == 0xA5` → history packet.

| Bytes | Field | Notes |
|-------|-------|-------|
| 0 | `0xA5` marker | — |
| 1 | `0x48` marker | ASCII `'H'` |
| 2–4 | Total | **u24 LE** — record count in **this** sync (recent-N → N) |
| 5–7 | Index | **u24 LE** — 0-based position within this sync |
| 8–29 | `geue_log_record_t` | 22-byte flash record (see below) |
| 30 | Reserved `0x00` | — |

u24 `total`/`index` are sync-relative and don't wrap for any realistic buffer, so `index/total` is a reliable progress fraction. **End-of-sync is still the packet whose 22 record bytes (8–29) are all `0x00`** — always sent, even for a count-0 handshake. Records are cached in arrival order, keyed per device by the record's own timestamp.

### History flash record (22 bytes, `geue_log_record_t` at packet bytes 8–29)

**Flash struct order — timestamp FIRST** (this differs from the live sensor payload):

| Record bytes | Packet bytes | Field | Notes |
|-------|-------|-------|-------|
| 0–3 | 8–11 | Timestamp `UInt32` LE | Unix epoch seconds; may be seconds-since-boot if the RTC read failed — pre-2020 values are treated as unanchored and skipped |
| 4–5 | 12–13 | Temperature `Int16` LE | ÷ 100 → °C; `0x8000` = sentinel |
| 6–7 | 14–15 | Humidity `UInt16` LE | ÷ 100 → %; `0xFFFF` = sentinel |
| 8–9 | 16–17 | TVOC `UInt16` LE | ppb; `0xFFFF` = sentinel |
| 10–11 | 18–19 | eCO₂ `UInt16` LE | ppm; `0xFFFF` = sentinel |
| 12 | 20 | AQI `UInt8` | UBA 1–5; `0` = warming up |
| 13 | 21 | Status `UInt8` | bitfield |
| 14–15 | 22–23 | Sequence `UInt16` LE | cross-ref only, **not** an ordering key |
| 16–17 | 24–25 | PM1.0 `UInt16` LE | µg/m³; `0xFFFF` (no reading) / `0xFFFE` (over-range) = sentinel |
| 18–19 | 26–27 | PM2.5 `UInt16` LE | µg/m³; `0xFFFF` / `0xFFFE` = sentinel |
| 20–21 | 28–29 | PM10 `UInt16` LE | µg/m³; `0xFFFF` / `0xFFFE` = sentinel |

PM is logged and charts as real PM1.0/PM2.5/PM10 series in the History tab.
Both PM sentinels (`0xFFFF` no-reading, `0xFFFE` over-range) are decoded to
"invalid" (`—`) by the single shared `GATT.decodePM`, used by the live and history
parsers alike. Records synced from firmware older than 2026-07-09 simply carry no
PM and render `—`.

---

## 5. Swift 6 concurrency notes

- `BluetoothManager` is `@MainActor @Observable`. All view-visible state lives here.
- CoreBluetooth callbacks are `nonisolated`; they extract `Sendable` values, then `Task { @MainActor in … }` to marshal.
- `CBUUID` constants in `GATT` carry `nonisolated(unsafe)` because CBUUID is immutable after init.
- `PeripheralBox` is `@unchecked Sendable` to cross the queue boundary; the only property is the `CBPeripheral` reference, which CoreBluetooth requires you to call from any queue.
- `HistoryRepository` and `HistorySyncTransport` protocols are `@MainActor`-bound.
