# GEUE Smart Air Monitor — iOS App

SwiftUI rebuild of the GEUE Air Quality (G2) iOS client.  
Target: **iOS 17.0+**, **Swift 6 strict concurrency**, zero third-party dependencies.

---

## 1. Repository layout

```
Smart Air Monitor/
├── App/                   Entry point, root view, theme
│   ├── Smart_Air_MonitorApp.swift   DI switch (see §2)
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

**File:** [`Smart Air Monitor/App/Smart_Air_MonitorApp.swift`](Smart%20Air%20Monitor/App/Smart_Air_MonitorApp.swift)

```swift
private static let historyDataSource: HistoryDataSource = .mock   // ← change to .ble
```

| Value | Behaviour |
|-------|-----------|
| `.mock` | `MockHistoryRepository` — 60 days × ~4 samples/hour of synthetic data with diurnal variation and cooking/cleaning spikes. Works offline and in Simulator. Use this for UI development and design review. |
| `.ble` | `BLEHistoryRepository` — sends opcode `0x01`, then streams each 16-byte flash record as it arrives via `HistoryStreamEvent`. Inserts records into SwiftData and returns `.completed(count:)` on the end-of-sync sentinel. Use this on real hardware. |

Switching the constant is the **only** change needed to flip data sources; views, `HistoryStore`, and SwiftData are unchanged.

---

## 3. Stubs and firmware TODOs

### 3.1 History sync — `BLEHistoryRepository`

**File:** [`Smart Air Monitor/History/BLEHistoryRepository.swift`](Smart%20Air%20Monitor/History/BLEHistoryRepository.swift)

**Implemented.** `BLEHistoryRepository.syncHistory()` calls `BluetoothManager.startHistorySync()`, which sends opcode `0x01` and returns an `AsyncStream<HistoryStreamEvent>`. `BluetoothManager.handleValueUpdate` demuxes incoming notifications on the Sensor characteristic by `payload[0]`: `0x02` = live data → `SensorParser`; `0xA5` = history packet → `HistoryPacketParser` → `historyStreamContinuation.yield(...)`. `BLEHistoryRepository` iterates the stream, inserts each `HistoryRecord` into the SwiftData context, and returns `.completed(count:)` on the end-of-sync sentinel.

### 3.2 Time synchronisation — `SettingsView`

**File:** [`Smart Air Monitor/Views/Settings/SettingsView.swift`](Smart%20Air%20Monitor/Views/Settings/SettingsView.swift)

**Implemented.** "Sync device clock" calls `BluetoothManager.setDeviceTime()`, which builds the 8-byte opcode `0x0B SET_TIME` payload and writes it to the Command characteristic. All 7 date fields are raw decimal (not BCD); `wday` is mapped from Calendar's 1=Sun convention to firmware's 0=Sun convention. The button is disabled when not connected.

### 3.3 Simulator BLE stub — `BluetoothManager`

**File:** [`Smart Air Monitor/BLE/BluetoothManager.swift`](Smart%20Air%20Monitor/BLE/BluetoothManager.swift)

iOS Simulator has no CoreBluetooth radio. The `#if targetEnvironment(simulator)` extension provides:

- `startSimulatedScan()` — emits two synthetic `DiscoveredDevice` entries with jittered RSSI
- `connectSimulated(to:)` — 750 ms connecting + 400 ms discovering delays, then `.connected`
- `emitSimulatedReading()` — builds a real 31-byte packet and feeds it through production `SensorParser`
- `debugAutoConnect()` — called from `RootView.task` when `GEUE_SIM_AUTOCONNECT=1`

This code is **excluded from device builds** at compile time; it adds zero overhead on real hardware.

---

## 4. GATT sensor payload mapping

**Source of truth:** [`Smart Air Monitor/BLE/GATT.swift`](Smart%20Air%20Monitor/BLE/GATT.swift) and [`Smart Air Monitor/BLE/SensorParser.swift`](Smart%20Air%20Monitor/BLE/SensorParser.swift)

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
| 16–17 | +8 | PM1.0 | `UInt16` LE | raw µg/m³ | `0xFFFF` |
| 18–19 | +10 | PM2.5 | `UInt16` LE | raw µg/m³ | `0xFFFF` |
| 20–21 | +12 | PM10 | `UInt16` LE | raw µg/m³ | `0xFFFF` |
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

After `0x01 SYNC_HISTORY` is written, the device streams records as notifications on the **Sensor characteristic** (same UUID, same CCCD subscription).

**Demux rule:** `payload[0] == 0x02` → live sensor data; `payload[0] == 0xA5` → history packet.

| Bytes | Field | Notes |
|-------|-------|-------|
| 0 | `0xA5` marker | — |
| 1 | `0x48` marker | ASCII `'H'` |
| 2–3 | Total record count | uint16 LE — constant across a sync |
| 4–5 | Record index | uint16 LE — 0 = oldest; `index == totalCount` → end-of-sync sentinel |
| 6–21 | `geue_log_record_t` | 16-byte flash record (see below) |
| 22–30 | Reserved `0x00` | — |

End-of-sync sentinel: `index == totalCount` and bytes 6–21 all `0x00`.

### History flash record (16 bytes, `geue_log_record_t` at bytes 6–21)

Each synced record matches `HistoryRecord` field-for-field:

| Bytes | Field | Notes |
|-------|-------|-------|
| 0–1 | Temperature `Int16` LE | ÷ 100 → °C; `0x8000` = sentinel |
| 2–3 | Humidity `UInt16` LE | ÷ 100 → %; `0xFFFF` = sentinel |
| 4–5 | TVOC `UInt16` LE | ppb; `0xFFFF` = sentinel |
| 6–7 | eCO₂ `UInt16` LE | ppm; `0xFFFF` = sentinel |
| 8 | AQI `UInt8` | 0–5 |
| 9 | Status `UInt8` | bitmask |
| 10–11 | Sequence `UInt16` LE | monotonic counter |
| 12–15 | Timestamp `UInt32` LE | Unix epoch seconds |

PM is **not** logged in the flash record. The PM chart metric in the History tab shows a placeholder explaining this rather than fabricating data.

---

## 5. Swift 6 concurrency notes

- `BluetoothManager` is `@MainActor @Observable`. All view-visible state lives here.
- CoreBluetooth callbacks are `nonisolated`; they extract `Sendable` values, then `Task { @MainActor in … }` to marshal.
- `CBUUID` constants in `GATT` carry `nonisolated(unsafe)` because CBUUID is immutable after init.
- `PeripheralBox` is `@unchecked Sendable` to cross the queue boundary; the only property is the `CBPeripheral` reference, which CoreBluetooth requires you to call from any queue.
- `HistoryRepository` and `HistorySyncTransport` protocols are `@MainActor`-bound.
