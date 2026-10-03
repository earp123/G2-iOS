# Task: Thresholds v3 — settings UI for adjustable bands, fan tables, timers, hysteresis

**Branch:** `SEN66` (never `main`). Confirm with `git branch --show-current` before touching anything.
**Origin:** client request 2026-10-02. **The firmware document owns the contract:** `G2-Air-Quality-Monitor/docs/thresholds-v3.md` §2 — read it first and treat the byte tables below as a copy, not a source. If they disagree, the firmware doc wins and this file gets fixed.
**Status:** READY once firmware lands `docs/gatt-v3-ios-notes.md`. Phase A (decode + guard) can start now against the tables here; Phase B (settings screens) ships only against a firmware build reporting contract version 3.

---

## 0. Read before writing

- `docs/sen66-migration.md` (this repo) — current v2 decode and the file map
- The BLE layer: GATT constants, `SensorPacket` parser, `HistoryPacketParser`, settings read/write, Device Info guard
- The existing Settings view (brightness slider, fan mode picker, Manual-0 % warning)
- `FanMode` enum and every switch over it

## 1. What changes for the app

| Area | v2 | **v3** |
|---|---|---|
| Device Info bytes 34 / 35 | 2 / 2 | **3 / 3** — refuse to parse otherwise |
| Live packet byte 1 (payload version) | `0x02` | **`0x03`** — firmware packs the contract version here (firmware §5) |
| Live packet byte 32 | `aq_class` 0–5 (PM folded in) | **packed:** low nibble gas class 0–5, high nibble PM class 0–3 |
| Log record byte 22 | `aq_class` 0–5 | same packed byte |
| Live packet byte 34 `fan_mode` | 0 / 1 / 2 | **0 Auto · 2 Manual** (1 never sent) |
| Settings bytes 0–7 | VOC lo/med/hi/max | **retired** — read 0, write 0 |
| Settings byte 9 | 0 / 1 / 2 | **0 or 2 only**; 1 is rejected by firmware |
| Opcode `0x0A` (Custom) | valid | **removed** — never send |
| Opcode `0x10` | — | **new:** restore thresholds to defaults |
| Thresholds characteristic `7A3E4F61-8C2D-4E9A-B1F6-0D3C5E7F9A2B` | — | **new**, 60 B READ + WRITE |

### 1.1 Packed class byte

```swift
struct AirClasses {
    let gas: UInt8   // 0 unknown/warming, 1–5
    let pm:  UInt8   // 0 unknown/warming, 1 good, 2 attention, 3 hazard
    init(byte: UInt8) { gas = byte & 0x0F; pm = byte >> 4 }
}
```

Two LEDs on the device, two tiles in the app. Gas tile colour: 0 grey, 1–2 green, 3 orange, 4–5 red. PM tile colour: 0 grey, 1 green, 2 orange, 3 red. Do not re-derive either class from raw values — firmware is the source of truth and the edges are user-editable.

### 1.2 Thresholds blob — 60 bytes, little-endian

| Byte | Field | Type | Units shown in UI | Default | App-side pre-check |
|---|---|---|---|---|---|
| 0 | `version` | u8 | — | 1 | always write 1 |
| 1 | reserved | u8 | — | 0 | write 0 |
| 2–9 | VOC C1..C4 | 4 × u16 | index (integer) | 100 / 150 / 250 / 350 | strictly increasing, ≤ 500 |
| 10–17 | NOx C1..C4 | 4 × u16 | index (integer) | 20 / 50 / 100 / 200 | strictly increasing, ≤ 500 |
| 18–25 | CO2 C1..C4 | 4 × u16 | ppm (integer) | 800 / 1000 / 1500 / 2000 | strictly increasing, ≤ 40000 |
| 26–27 | PM1 attention | u16 | µg/m³, **one decimal** (wire = value × 10) | 7.0 | < hazard |
| 28–29 | PM1 hazard | u16 | µg/m³ | 25.0 | |
| 30–31 | PM2.5 attention | u16 | µg/m³ | 9.0 | < hazard |
| 32–33 | PM2.5 hazard | u16 | µg/m³ | 35.0 | |
| 34–35 | PM10 attention | u16 | µg/m³ | 45.0 | < hazard |
| 36–37 | PM10 hazard | u16 | µg/m³ | 150.0 | |
| 38–42 | fan % for gas class 1..5 | 5 × u8 | % | 0 / 25 / 50 / 75 / 100 | 0–100 |
| 43–45 | fan % for PM class 1..3 | 3 × u8 | % | 20 / 50 / 100 | 0–100 |
| 46–47 | fan-down delay | u16 | seconds | 0 | 0–3600 |
| 48–49 | ionizer run-on | u16 | minutes | 60 | 0–1440 |
| 50–51 | VOC hysteresis | u16 | index | 0 | < smallest gap between adjacent VOC edges |
| 52–53 | NOx hysteresis | u16 | index | 0 | < smallest gap between adjacent NOx edges |
| 54–55 | CO2 hysteresis | u16 | ppm | 0 | < smallest gap between adjacent CO2 edges |
| 56–57 | PM hysteresis | u16 | µg/m³, one decimal | 0 | < smallest (hazard − attention) across PM1 / PM2.5 / PM10 |
| 58–59 | reserved | u16 | — | 0 | write 0 |

Firmware validates the whole blob and rejects the write with an ATT error if any rule fails — nothing is applied. The app must run the same checks **before** writing so the user sees which field is wrong instead of a generic Bluetooth error.

Behaviour the UI should explain in one line each (help text, not a wall):

- Fan in Auto runs at the **higher** of the gas-class % and the PM-class %.
- Fan-down delay: the fan holds its speed this long after the air improves. 0 = immediate.
- Hysteresis: the class only steps down once the value falls this far below the edge. 0 = none.
- Ionizer run-on: stays on this long after demand clears. 0 = none.

## 2. Phase A — decode and guard (no UI yet)

1. Device Info guard requires 3 / 3. On 2 / 2 show the existing "update required" state (reuse whatever v2 does for a mismatch).
2. `SensorPacket`: replace `aqClass: UInt8` with `classes: AirClasses` from byte 32. `fanMode` decoding treats 1 as `.auto` with an assertion in debug (it should never arrive).
3. `LogRecord`: same packed decode at byte 22. Older records with high nibble 0 render the PM tile grey.
4. `FanMode`: remove `.custom` and every UI path to it; the picker is Auto / Manual. Remove the `0x0A` send. Remove the VOC lo/med/hi/max editor and the 8-byte settings write; the 12-byte write always sends bytes 0–7 as zero.
5. Add `ThresholdsBlob` (struct + `pack()` / `unpack(Data)` + `validate() -> ValidationError?`) and the characteristic read on connect.
6. Add opcode `0x10` to the command enum.

## 3. Phase B — settings screens

A new **Air quality thresholds** section in Settings, read on connect, written as a whole on **Save**. Layout:

1. **Gas classes** — a 3 × 4 grid of integer fields: rows VOC / NOx / CO2, columns C1 / C2 / C3 / C4, unit label per row. Inline error under a row if not strictly increasing.
2. **Particulate** — a 3 × 2 grid: rows PM1 / PM2.5 / PM10, columns Attention / Hazard, one-decimal fields in µg/m³. Inline error if attention ≥ hazard.
3. **Fan response** — two rows of percent fields: gas class 1–5, PM class 1–3. One-line note: higher of the two wins.
4. **Timing** — fan-down delay (s), ionizer run-on (min).
5. **Hysteresis** — VOC, NOx, CO2 (integer), PM (one decimal).
6. **Save** (disabled until `validate()` passes and something changed) and **Restore defaults** (confirm sheet → opcode `0x10` → re-read the characteristic and refresh the form).

Rules:

- Numeric keyboards; integer fields reject decimals; PM fields accept one decimal and round to it.
- Validation runs on every edit; the Save button state and the inline errors follow `validate()`.
- After a successful write, re-read the characteristic and show what the device actually stored (defensive — catches any firmware clamp).
- Keep the existing Manual-0 % warning. It applies unchanged.
- The Custom-mode UI, the VOC threshold editor and their strings are deleted, not hidden.

## 4. Test / acceptance

Against a firmware build reporting Device Info 3 / 3 (the firmware task's §4 bench unit is fine).

1. Connect to a v2 firmware → update-required state, no crash, no parse.
2. Connect to v3 → both tiles update independently (blow on the sensor: gas tile changes, PM tile does not; dust: the reverse).
3. Thresholds section loads the defaults from the device byte for byte.
4. Set VOC C1..C4 = 5/6/7/8, Save → device gas tile goes red within ~2 s; Restore defaults → recovers and the form shows the defaults again.
5. Every validation rule in §1.2 produces an inline error and disables Save; the write is never attempted.
6. Enter a value the app allows but firmware would reject (there should be none — if one is found, fix `validate()` and note it in the changelog).
7. Fan mode picker shows only Auto / Manual; Manual 0 % warning still appears.
8. History sync after the upgrade renders new records with both classes and any older records with a grey PM tile.
9. Kill the app mid-edit and reconnect → form reloads from the device, no stale local values.

## 5. Zero-change files

History packet framing, the Device Name flow, the share/export feature, the scan list and service-UUID filter, bundle identifier, CI workflow.

## 6. Deliverables

- Code per sections 2–3, on `SEN66`.
- `CHANGELOG.md` entry: contract v3 adoption, the packed class decode, the Thresholds screen, removed Custom mode, test results.
- Update `docs/sen66-migration.md`'s decode notes (or add a "superseded for byte 32 / 22 by thresholds-v3" line) so the two docs do not contradict each other.
