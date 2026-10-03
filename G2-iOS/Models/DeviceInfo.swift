//
//  DeviceInfo.swift
//  G2-iOS
//
//  The Device Info characteristic — READ only, 40 bytes, new in contract v2 (§1.5):
//    [0–31] SEN66 serial, ASCII NUL-padded
//    [32]   SEN66 firmware major
//    [33]   SEN66 firmware minor
//    [34]   contract version (expect 3 — thresholds-v3 §2.5)
//    [35]   log record version (expect 3)
//    [36–39] reserved
//
//  Values are cached by firmware at sensor init; a unit that booted without a
//  SEN66 attached reports zeros in bytes 0–33 only. Bytes 34–35 always carry the
//  versions (firmware gatt-v3-ios-notes §1 — corrects the v2 note, which said
//  the whole payload was zero).
//

import Foundation

/// Static identity and version info read once per connection (§1.5).
struct DeviceInfo: Equatable, Sendable {
    /// SEN66 serial number, NUL padding stripped. Empty when the sensor was
    /// absent at boot.
    let serial: String
    let firmwareMajor: UInt8
    let firmwareMinor: UInt8
    /// Wire-contract version the device implements. Anything other than
    /// `GATT.contractVersion` is surfaced as an error, not worked around (§9.3).
    let contractVersion: UInt8
    /// Flash log-record version. A change wipes the local history cache (§2).
    let logRecordVersion: UInt8

    /// Parses the 40-byte payload, or `nil` if malformed (§7).
    init?(data: Data) {
        guard data.count >= GATT.deviceInfoPayloadLength else { return nil }
        let b = [UInt8](data)

        let serialBytes = b[
            GATT.DeviceInfoOffset.serial
            ..< (GATT.DeviceInfoOffset.serial + GATT.DeviceInfoOffset.serialLength)
        ]
        // ASCII, NUL-padded: stop at the first NUL, then trim any stray padding.
        let trimmed = Array(serialBytes.prefix { $0 != 0 })
        self.serial = String(decoding: trimmed, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        self.firmwareMajor    = b[GATT.DeviceInfoOffset.firmwareMajor]
        self.firmwareMinor    = b[GATT.DeviceInfoOffset.firmwareMinor]
        self.contractVersion  = b[GATT.DeviceInfoOffset.contractVersion]
        self.logRecordVersion = b[GATT.DeviceInfoOffset.logRecordVersion]
    }

    init(serial: String, firmwareMajor: UInt8, firmwareMinor: UInt8,
         contractVersion: UInt8, logRecordVersion: UInt8) {
        self.serial = serial
        self.firmwareMajor = firmwareMajor
        self.firmwareMinor = firmwareMinor
        self.contractVersion = contractVersion
        self.logRecordVersion = logRecordVersion
    }

    /// `true` when the device speaks the contract this build implements.
    var isContractSupported: Bool { contractVersion == GATT.contractVersion }

    /// The contract guard (thresholds-v3 §2 item 1, firmware gatt-v3 notes §1):
    /// `true` unless the device reports exactly the contract and log-record
    /// versions implemented here (3 / 3). A v2 unit reports 2 / 2 and lands in
    /// the update-required state; its Sensor Data, history and Settings are never
    /// parsed.
    ///
    /// There is no exemption for zeros: firmware always populates bytes 34–35,
    /// even when the SEN66 was absent at boot, so 0 / 0 is not a v3 device.
    var requiresUpdate: Bool {
        !(contractVersion == GATT.contractVersion && logRecordVersion == GATT.historyRecordVersion)
    }

    /// `"1.4"` — the SEN66's own firmware version.
    var firmwareVersionText: String { "\(firmwareMajor).\(firmwareMinor)" }

    /// Serial for display; a unit that booted without a SEN66 reports nothing.
    var serialText: String { serial.isEmpty ? "—" : serial }
}
