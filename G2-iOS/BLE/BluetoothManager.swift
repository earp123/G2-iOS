//
//  BluetoothManager.swift
//  G2-iOS
//
//  Single owner of all CoreBluetooth state (§1 architecture). Views never touch
//  CBPeripheral directly — they read this @Observable model and call its methods.
//
//  Threading (§1 concurrency rules):
//   • CoreBluetooth runs on a dedicated serial dispatch queue (`bleQueue`).
//   • Delegate callbacks are `nonisolated`; each extracts only Sendable data and
//     hops to the @MainActor before mutating any observable state.
//   • No force-unwraps on BLE-derived data; short/odd payloads become non-fatal
//     states, never crashes (§7).
//

import Foundation
import CoreBluetooth
import Observation

/// Bridges a non-Sendable CoreBluetooth peripheral across the
/// bleQueue → MainActor boundary. CBPeripheral is internally thread-safe and we
/// only ever *use* it from the MainActor, so this hand-off is safe.
private nonisolated struct PeripheralBox: @unchecked Sendable {
    let peripheral: CBPeripheral
}

@MainActor
@Observable
final class BluetoothManager: NSObject {

    // MARK: - Observable state (read by views)

    private(set) var availability: BluetoothAvailability = .unknown
    private(set) var scanState: ScanState = .idle
    private(set) var discoveredDevices: [DiscoveredDevice] = []   // sorted strongest-first (§3/§5)

    private(set) var phase: ConnectionPhase = .disconnected
    private(set) var connectedDevice: DiscoveredDevice?
    private(set) var lastDisconnectReason: DisconnectReason?

    /// Last successfully parsed reading (last-good; the view marks it stale by age).
    private(set) var latestReading: SensorReading?
    /// Set when a malformed/short packet arrives — non-fatal (§7).
    private(set) var lastParseError: String?

    /// READ from the Settings characteristic — the full 12-byte payload (§1.3).
    private(set) var settings: DeviceSettings?
    /// READ from the Device Name characteristic; the effective name, which is the
    /// saved nickname or the firmware default (§1.4).
    private(set) var deviceName: String?
    /// READ once after discovery from the Device Info characteristic (§1.5).
    private(set) var deviceInfo: DeviceInfo?
    private(set) var liveRSSI: Int?
    private(set) var mtu: Int?

    /// What the device last reported from the 60-byte Thresholds characteristic
    /// (thresholds-v3 §2.2). Read on connect, and re-read after every Save and
    /// every Restore defaults, so it is always the device's own stored copy —
    /// never an optimistic local echo. `nil` while disconnected, so a reconnect
    /// always reloads from the device.
    private(set) var thresholds: ThresholdsBlob?
    /// Bumped on every completed Thresholds read, even one that returns the same
    /// bytes, so the editor can refresh after Restore defaults on a unit that was
    /// already at its defaults.
    private(set) var thresholdsRevision = 0
    /// True from a Thresholds write (or `0x10`) until its result and the re-read
    /// that follows it are in — the editor holds Save while it is set.
    private(set) var isWritingThresholds = false

    /// Set when Device Info reports a contract or log-record version this build
    /// does not implement (`DeviceInfo.requiresUpdate`). Live packets are then
    /// refused rather than decoded — the firmware handoff note's "cheapest guard
    /// against an old device meeting a new app" (notes §7 / §9.3). A v2 unit
    /// (2 / 2) lands here on a v3 build.
    private(set) var unsupportedContract: DeviceInfo?

    /// True when the device says no SEN66 is attached (status bit 0 clear). Every
    /// measurement is at its sentinel; the UI says "disconnected", not zeros
    /// (notes §2).
    var sensorDisconnected: Bool {
        guard let reading = latestReading else { return false }
        return !reading.status.sen66Present
    }

    /// True while the SEN66 is warming (status bit 2). Fan cleaning is refused by
    /// firmware during this window, so the button is disabled (notes §4).
    var sensorIsWarming: Bool { latestReading?.status.sen66Warming ?? false }

    /// The live packet is 52 bytes, so ATT MTU must be at least 55 (notes §8).
    static let minimumUsableMTU = 55
    var mtuIsTooSmall: Bool {
        guard let mtu else { return false }
        return mtu < Self.minimumUsableMTU
    }

    /// True when the device reports Manual mode at 0 %. Firmware restores that
    /// state exactly as saved, so the fan stays off across the next ignition
    /// cycle — the app surfaces it as a persistent warning and a tab badge (§5).
    var showsManualOffWarning: Bool {
        guard let reading = latestReading else { return false }
        return reading.fanMode == .manual && reading.fanSpeedPct == 0
    }

    /// Transient command result for a toast; the view clears it after showing.
    var commandFeedback: CommandFeedback?

    enum ScanState: Equatable, Sendable { case idle, scanning, noResults }

    // MARK: - CoreBluetooth internals (not observed)

    @ObservationIgnored private var central: CBCentralManager?
    @ObservationIgnored private let bleQueue = DispatchQueue(label: "com.geue.airquality.ble", qos: .userInitiated)
    @ObservationIgnored private var peripheralsByID: [UUID: CBPeripheral] = [:]
    @ObservationIgnored private var connectedPeripheral: CBPeripheral?
    @ObservationIgnored private var sensorChar: CBCharacteristic?
    @ObservationIgnored private var commandChar: CBCharacteristic?
    @ObservationIgnored private var settingsChar: CBCharacteristic?
    @ObservationIgnored private var deviceNameChar: CBCharacteristic?
    @ObservationIgnored private var deviceInfoChar: CBCharacteristic?
    @ObservationIgnored private var thresholdsChar: CBCharacteristic?
    /// Set while a `0x10` write-with-response is in flight; its success triggers
    /// the Thresholds re-read (§3).
    @ObservationIgnored private var awaitingThresholdsRestore = false
    /// A Settings READ that arrived before Device Info had cleared the contract
    /// guard. It is decoded only once the guard passes: a v2 unit's byte 9 can
    /// still hold the retired Custom value 1, and an incompatible unit's
    /// Settings are not parsed at all (gatt-v3 notes §1).
    @ObservationIgnored private var pendingSettingsData: Data?

    @ObservationIgnored private var scanWatchdog: Task<Void, Never>?
    @ObservationIgnored private var connectWatchdog: Task<Void, Never>?
    @ObservationIgnored private var writeWatchdog: Task<Void, Never>?
    @ObservationIgnored private var rssiPoller: Task<Void, Never>?
    @ObservationIgnored private var historyStreamContinuation: AsyncStream<HistoryStreamEvent>.Continuation?
    @ObservationIgnored private var historyWatchdog: Task<Void, Never>?
    @ObservationIgnored private var lastHistoryActivity: Date = .distantPast

    private static let scanTimeout: Duration = .seconds(15)
    private static let connectTimeout: Duration = .seconds(15)
    private static let writeTimeout: Duration = .seconds(5)
    /// End a history sync if no packet arrives for this long — covers firmware that
    /// doesn't implement/answer SYNC_HISTORY, so the UI never spins forever.
    private static let historyInactivityTimeout: TimeInterval = 6

    // MARK: - Simulation (Simulator only — there is no CoreBluetooth radio in the
    // iOS Simulator). This makes the whole app exercisable in the Simulator and is
    // never compiled into device builds. Readings are fed through the REAL parser,
    // and it is clearly surfaced as synthetic in the UI (honest — see isSimulated).
    #if targetEnvironment(simulator)
    let isSimulated = true
    @ObservationIgnored private var simLoop: Task<Void, Never>?
    @ObservationIgnored private var simSequence: UInt16 = 0
    @ObservationIgnored private var simFanSpeed: Int = 25
    @ObservationIgnored private var simSettings: DeviceSettings = .defaults
    @ObservationIgnored private var simDeviceName: String = GATT.advertisedName
    /// The synthetic unit's Thresholds blob — written by Save, reset by `0x10`,
    /// and used to classify the synthetic readings, like the firmware would.
    @ObservationIgnored private var simThresholds: ThresholdsBlob = .defaults
    /// Synthetic SEN66 device status register (bytes 36–39), cleared by the
    /// maintenance commands so their effect is visible in the Simulator.
    @ObservationIgnored private var simSen66Status: UInt32 = 0
    @ObservationIgnored private var simHistoryTask: Task<Void, Never>?
    #else
    let isSimulated = false
    #endif

    override init() {
        super.init()
        #if targetEnvironment(simulator)
        availability = .ready   // pretend the radio is ready; startScan() yields synthetic units
        #else
        // Dedicated queue — delegate callbacks arrive off the main actor (§1).
        central = CBCentralManager(delegate: self, queue: bleQueue, options: nil)
        #endif
    }

    // MARK: - Scanning (§3 Phase A)

    func startScan() {
        #if targetEnvironment(simulator)
        startSimulatedScan()
        #else
        guard availability.isReady else { return }
        guard scanState != .scanning else { return }

        discoveredDevices.removeAll()
        peripheralsByID.removeAll()
        scanState = .scanning

        // Filter on the service UUID (§2.1); allow duplicates so RSSI updates in place (§3).
        central?.scanForPeripherals(
            withServices: [GATT.serviceUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        )

        scanWatchdog?.cancel()
        scanWatchdog = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.scanTimeout)
            guard let self, !Task.isCancelled, self.scanState == .scanning else { return }
            if self.discoveredDevices.isEmpty {
                self.stopScan()
                self.scanState = .noResults   // retry affordance (§7)
            }
        }
        #endif
    }

    func stopScan() {
        scanWatchdog?.cancel()
        central?.stopScan()
        if scanState == .scanning { scanState = .idle }
    }

    // MARK: - Connection (§3)

    func connect(to id: UUID) {
        #if targetEnvironment(simulator)
        connectSimulated(to: id)
        #else
        guard let peripheral = peripheralsByID[id] else { return }
        stopScan()
        clearDisconnectReason()
        phase = .connecting
        peripheral.delegate = self
        connectedPeripheral = peripheral
        connectedDevice = discoveredDevices.first { $0.id == id }
        central?.connect(peripheral, options: nil)

        connectWatchdog?.cancel()
        connectWatchdog = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.connectTimeout)
            guard let self, !Task.isCancelled,
                  self.phase == .connecting || self.phase == .discovering else { return }
            self.central?.cancelPeripheralConnection(peripheral)
            self.teardownConnection(reason: .connectFailed("timed out"))
        }
        #endif
    }

    /// Cancel an in-flight connection attempt (the connecting spinner's cancel button).
    func cancelConnect() {
        #if targetEnvironment(simulator)
        simLoop?.cancel()
        teardownConnection(reason: .userInitiated)
        #else
        guard phase == .connecting || phase == .discovering, let p = connectedPeripheral else { return }
        central?.cancelPeripheralConnection(p)
        teardownConnection(reason: .userInitiated)
        #endif
    }

    /// User-initiated disconnect → returns to ScanView with no alarming banner (§3/§6.4).
    func disconnect() {
        #if targetEnvironment(simulator)
        simLoop?.cancel()
        teardownConnection(reason: .userInitiated)
        #else
        guard let p = connectedPeripheral else {
            teardownConnection(reason: .userInitiated)
            return
        }
        central?.cancelPeripheralConnection(p)
        teardownConnection(reason: .userInitiated)
        #endif
    }

    private func teardownConnection(reason: DisconnectReason) {
        connectWatchdog?.cancel()
        writeWatchdog?.cancel()
        rssiPoller?.cancel()
        historyWatchdog?.cancel()
        historyStreamContinuation?.finish()   // abort any in-flight sync
        historyStreamContinuation = nil

        connectedPeripheral?.delegate = nil
        connectedPeripheral = nil
        sensorChar = nil
        commandChar = nil
        settingsChar = nil
        deviceNameChar = nil
        deviceInfoChar = nil
        thresholdsChar = nil
        awaitingThresholdsRestore = false
        pendingSettingsData = nil

        phase = .disconnected
        connectedDevice = nil
        latestReading = nil
        lastParseError = nil
        settings = nil
        deviceName = nil
        deviceInfo = nil
        thresholds = nil
        isWritingThresholds = false
        unsupportedContract = nil
        liveRSSI = nil
        mtu = nil
        lastDisconnectReason = reason
    }

    func clearDisconnectReason() { lastDisconnectReason = nil }
    func clearCommandFeedback() { commandFeedback = nil }

    // MARK: - Commands (§2.4 / §6.2)

    /// Writes an opcode (+ optional parameter byte) to the Command characteristic.
    /// Uses WRITE-with-response so the firmware can surface ATT errors (e.g. 0x0E).
    func sendCommand(_ command: GATT.Command, parameter: UInt8? = nil) {
        #if targetEnvironment(simulator)
        simulateCommand(command, parameter: parameter)
        #else
        var payload = Data([command.rawValue])
        if let parameter { payload.append(parameter) }
        writeToCommand(payload)
        #endif
    }

    /// Raw multi-byte write to the Command characteristic (SET_TIME, SYNC_RECENT).
    /// No-op in the Simulator, which has no radio. Returns whether the write
    /// expects a response — `nil` when nothing was written.
    @discardableResult
    private func writeToCommand(_ payload: Data) -> Bool? {
        #if targetEnvironment(simulator)
        _ = payload
        return nil
        #else
        guard phase == .connected, let p = connectedPeripheral, let c = commandChar else {
            commandFeedback = .rejected("Not connected")
            return nil
        }
        let type: CBCharacteristicWriteType = c.properties.contains(.write) ? .withResponse : .withoutResponse
        p.writeValue(payload, for: c, type: type)
        if type == .withResponse { startWriteWatchdog() }
        return type == .withResponse
        #endif
    }

    func setFanAuto()   { sendCommand(.fanAuto) }
    func setFanPreset(_ preset: FanPreset) { sendCommand(preset.command) }
    func refreshNow()   { sendCommand(.getStatus) }      // 0x09 (§1.6 / §5)

    // MARK: - SEN66 maintenance commands (§1.6)

    /// 0x0D — runs the SEN66's fan-cleaning cycle (~10 s; PM readings pause).
    func sendFanCleaning() {
        sendCommand(.fanCleaning)
        commandFeedback = .succeeded("Fan cleaning started — PM readings pause for about 10 seconds.")
    }

    /// 0x0F — read-and-clear the SEN66 device status register, dropping any
    /// latched (sticky) error flags.
    func sendClearSensorErrors() {
        sendCommand(.clearErrors)
        commandFeedback = .succeeded("Sensor errors cleared.")
    }

    /// 0x0E — forced CO₂ recalibration against a reference concentration. The
    /// app sends 400 ppm (clean outdoor air); firmware rejects anything outside
    /// 350–2000 ppm. The sensor must have been outdoors for at least 3 minutes.
    func sendCO2Recalibration(ppm: UInt16 = GATT.co2RecalibrationReferencePpm) {
        // Firmware rejects anything outside this window with an ATT error, so the
        // write is never attempted with a value it would refuse (notes §4).
        guard GATT.co2RecalibrationRange.contains(ppm) else {
            commandFeedback = .rejected(
                "CO₂ reference must be between \(GATT.co2RecalibrationRange.lowerBound) and "
                + "\(GATT.co2RecalibrationRange.upperBound) ppm.")
            return
        }
        #if targetEnvironment(simulator)
        commandFeedback = .succeeded("CO₂ recalibrated to \(ppm) ppm.")
        #else
        writeToCommand(Data([
            GATT.Command.co2Recal.rawValue,
            UInt8(ppm & 0x00FF),
            UInt8((ppm >> 8) & 0x00FF),
        ]))
        commandFeedback = .succeeded("CO₂ recalibration sent (\(ppm) ppm reference).")
        #endif
    }

    /// Exact fan speed 0–100% via the manual slider — 2-byte write (§2.4 / §6.2).
    func setFanManual(percent: Int) {
        let clamped = UInt8(min(100, Swift.max(0, percent)))
        sendCommand(.fanManual, parameter: clamped)
    }

    /// Sets the DS3231 RTC to the given date (default: now). Sends opcode 0x0B with
    /// 7 raw-decimal bytes: sec min hr wday mday mon yr2k. Not routed through
    /// sendCommand() because the payload is 8 bytes total, not 1–2 (§2.4 / §6.4).
    func setDeviceTime(_ date: Date = .now) {
        #if targetEnvironment(simulator)
        return   // No RTC in Simulator; SettingsView shows the confirmation note itself.
        #else
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        let dc = cal.dateComponents([.second, .minute, .hour, .weekday, .day, .month, .year], from: date)
        writeToCommand(Data([
            GATT.Command.setTime.rawValue,
            UInt8(dc.second  ?? 0),
            UInt8(dc.minute  ?? 0),
            UInt8(dc.hour    ?? 0),
            UInt8((dc.weekday ?? 1) - 1),                        // Calendar 1=Sun → firmware 0=Sun
            UInt8(dc.day     ?? 1),
            UInt8(dc.month   ?? 1),
            UInt8(max(0, min(99, (dc.year ?? 2000) - 2000))),   // years since 2000
        ]))
        #endif
    }

    // MARK: - Settings, name and info (§1.3 / §1.4 / §1.5)

    func readSettings() {
        #if targetEnvironment(simulator)
        settings = simSettings
        #else
        guard phase == .connected, let p = connectedPeripheral, let c = settingsChar else { return }
        p.readValue(for: c)
        #endif
    }

    /// Writes the full 12-byte Settings payload, bytes 0–7 zero (thresholds-v3
    /// §2.3). There is nothing left to pre-validate: brightness and the manual %
    /// are clamped by `DeviceSettings`, and `FanMode` cannot encode the retired 1.
    @discardableResult
    func writeSettings(_ newSettings: DeviceSettings) -> Bool {
        guard unsupportedContract == nil else {
            commandFeedback = .rejected(Self.updateRequiredMessage)
            return false
        }
        #if targetEnvironment(simulator)
        simSettings = newSettings
        settings = newSettings
        simFanSpeed = newSettings.fanMode == .manual ? Int(newSettings.fanManualPct) : simFanSpeed
        return true
        #else
        guard phase == .connected, let p = connectedPeripheral, let c = settingsChar else {
            commandFeedback = .rejected("Not connected")
            return false
        }
        p.writeValue(newSettings.encoded, for: c, type: .withResponse)
        startWriteWatchdog()
        // Optimistic local echo so the editor doesn't snap back before the next
        // READ; a rejected write surfaces through handleWriteResult.
        settings = newSettings
        return true
        #endif
    }

    /// Writes only the LED brightness, preserving every other settings field (§6).
    @discardableResult
    func writeLEDBrightness(_ percent: UInt8) -> Bool {
        var updated = settings ?? .defaults
        updated.ledBrightnessPct = DeviceSettings.clampBrightness(percent)
        return writeSettings(updated)
    }

    // MARK: - Thresholds (thresholds-v3 §2.2 / §3)

    func readThresholds() {
        #if targetEnvironment(simulator)
        handleValueUpdate(.thresholds, data: simThresholds.pack(), error: nil)
        #else
        guard phase == .connected, let p = connectedPeripheral, let c = thresholdsChar else { return }
        p.readValue(for: c)
        #endif
    }

    /// Writes the whole 60-byte blob. Runs the firmware's own rules first and
    /// writes nothing if any fails, so the user is told which field is wrong
    /// instead of getting a bare ATT error (§1.2). On success the characteristic
    /// is re-read, so the editor shows what the device actually stored.
    @discardableResult
    func writeThresholds(_ blob: ThresholdsBlob) -> Bool {
        guard unsupportedContract == nil else {
            commandFeedback = .rejected(Self.updateRequiredMessage)
            return false
        }
        if let problem = blob.validate() {
            commandFeedback = .rejected(problem.message)
            return false
        }
        #if targetEnvironment(simulator)
        simThresholds = blob
        readThresholds()
        commandFeedback = .succeeded("Thresholds saved.")
        return true
        #else
        guard phase == .connected, let p = connectedPeripheral, let c = thresholdsChar else {
            commandFeedback = .rejected("Not connected")
            return false
        }
        isWritingThresholds = true
        p.writeValue(blob.pack(), for: c, type: .withResponse)
        startWriteWatchdog()
        return true
        #endif
    }

    /// Opcode `0x10` — the device puts its Thresholds blob back to the §2.2
    /// defaults (Settings and the nickname are untouched), then the
    /// characteristic is re-read so the editor shows the restored values.
    func restoreThresholdDefaults() {
        guard unsupportedContract == nil else {
            commandFeedback = .rejected(Self.updateRequiredMessage)
            return
        }
        #if targetEnvironment(simulator)
        simulateCommand(.restoreThresholds, parameter: nil)
        #else
        guard let awaitsResponse = writeToCommand(Data([GATT.Command.restoreThresholds.rawValue])) else { return }
        if awaitsResponse {
            isWritingThresholds = true
            awaitingThresholdsRestore = true   // re-read once the write is acknowledged
        } else {
            // No acknowledgement to wait for. ATT requests are serialised on the
            // link, so this read is answered after the command has been applied.
            readThresholds()
        }
        #endif
    }

    func readDeviceName() {
        #if targetEnvironment(simulator)
        deviceName = simDeviceName
        #else
        guard phase == .connected, let p = connectedPeripheral, let c = deviceNameChar else { return }
        p.readValue(for: c)
        #endif
    }

    /// Writes the Device Name characteristic. The device accepts 1–20 **UTF-8
    /// bytes** with no NUL and no surrounding whitespace, so the same rules are
    /// enforced here before the write (§1.4).
    @discardableResult
    func writeDeviceName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let encoded = Self.encodedDeviceName(trimmed) else {
            commandFeedback = .rejected(
                "Name must be 1–\(GATT.deviceNameMaxBytes) bytes of text (currently \(trimmed.utf8.count)).")
            return false
        }
        #if targetEnvironment(simulator)
        simDeviceName = trimmed
        deviceName = trimmed
        updateConnectedDeviceName(trimmed)
        commandFeedback = .succeeded("Name saved.")
        return true
        #else
        guard phase == .connected, let p = connectedPeripheral, let c = deviceNameChar else {
            commandFeedback = .rejected("Not connected")
            return false
        }
        p.writeValue(encoded, for: c, type: .withResponse)
        startWriteWatchdog()
        deviceName = trimmed
        updateConnectedDeviceName(trimmed)
        commandFeedback = .succeeded("Name saved.")
        return true
        #endif
    }

    /// Validates a candidate name against the wire rules and returns its UTF-8
    /// encoding, or nil when it would be rejected (§1.4).
    nonisolated static func encodedDeviceName(_ name: String) -> Data? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("\0") else { return nil }
        let bytes = Array(trimmed.utf8)
        guard bytes.count <= GATT.deviceNameMaxBytes else { return nil }
        return Data(bytes)
    }

    /// Keeps the connection chip and the scan entry in step with a renamed unit.
    private func updateConnectedDeviceName(_ name: String) {
        connectedDevice?.name = name
        if let id = connectedDevice?.id, let idx = discoveredDevices.firstIndex(where: { $0.id == id }) {
            discoveredDevices[idx].name = name
        }
    }

    /// Refuses a device whose reported contract or log-record version this build
    /// does not implement — `DeviceInfo.requiresUpdate`, which needs exactly
    /// 3 / 3 (gatt-v3 notes §1).
    private func applyContractGuard(_ info: DeviceInfo) {
        guard info.requiresUpdate else {
            unsupportedContract = nil
            return
        }
        unsupportedContract = info
        latestReading = nil          // nothing already on screen stays trustworthy
        lastParseError = nil
        settings = nil               // decoded under another contract — not shown
        thresholds = nil
        isWritingThresholds = false
    }

    /// Shown when a write is attempted on a unit the contract guard refused.
    private static let updateRequiredMessage =
        "This monitor needs a firmware update before its settings can be changed."

    func readDeviceInfo() {
        #if targetEnvironment(simulator)
        deviceInfo = Self.simDeviceInfo
        #else
        guard phase == .connected, let p = connectedPeripheral, let c = deviceInfoChar else { return }
        p.readValue(for: c)
        #endif
    }

    private func startWriteWatchdog() {
        writeWatchdog?.cancel()
        writeWatchdog = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.writeTimeout)
            guard let self, !Task.isCancelled else { return }
            self.commandFeedback = .timedOut   // never spin forever on a pending write (§7)
            // Release the editor's Save, and show whatever the device now holds.
            if self.isWritingThresholds {
                self.awaitingThresholdsRestore = false
                self.isWritingThresholds = false
                self.readThresholds()
            }
        }
    }

    // MARK: - MainActor handlers (called from the nonisolated delegate shims)

    private func handleStateChange(_ state: CBManagerState) {
        switch state {
        case .poweredOn:    availability = .ready
        case .poweredOff:   availability = .poweredOff
        case .unauthorized: availability = .unauthorized
        case .unsupported:  availability = .unsupported
        default:            availability = .unknown
        }
        if !availability.isReady, phase != .disconnected {
            teardownConnection(reason: .linkLoss(availability.guidance))
        }
        if !availability.isReady { stopScan() }
    }

    private func handleDiscovery(_ box: PeripheralBox, name: String, rssi: Int) {
        let p = box.peripheral
        peripheralsByID[p.identifier] = p

        let device = DiscoveredDevice(id: p.identifier, name: name, rssi: rssi)
        if let idx = discoveredDevices.firstIndex(where: { $0.id == device.id }) {
            // Update in place. The name is refreshed too, not just the RSSI: a
            // unit renamed through the Device Name characteristic re-advertises
            // under its new local name (§2).
            discoveredDevices[idx].rssi = rssi
            discoveredDevices[idx].name = name
        } else {
            discoveredDevices.append(device)
        }
        discoveredDevices.sort { $0.rssi > $1.rssi }   // strongest-first (§3)
        if scanState == .scanning, !discoveredDevices.isEmpty {
            // results present — leave .scanning so RSSI keeps refreshing.
        }
    }

    private func handleConnected(_ box: PeripheralBox) {
        let p = box.peripheral
        phase = .discovering
        p.discoverServices([GATT.serviceUUID])
        // MTU is deliberately NOT sampled here. iOS performs the ATT MTU exchange
        // asynchronously after the connection completes, so at this instant
        // `maximumWriteValueLength` still reports the 23-byte default and would
        // pin a wrong value in the UI. It is read once the link is fully up, and
        // refreshed by the RSSI poller until it settles (notes §8).
    }

    private func handleDisconnect(error: String?) {
        // Distinguish user-initiated (already torn down) from an unexpected drop.
        if phase == .disconnected { return }
        teardownConnection(reason: .linkLoss(error))
    }

    private func handleConnectFailed(error: String?) {
        teardownConnection(reason: .connectFailed(error))
    }

    private func handleServicesDiscovered(_ box: PeripheralBox, error: String?) {
        let p = box.peripheral
        if let error { teardownConnection(reason: .discoveryFailed(error)); return }
        guard let service = p.services?.first(where: { $0.uuid == GATT.serviceUUID }) else {
            teardownConnection(reason: .discoveryFailed("service not found"))
            return
        }
        p.discoverCharacteristics(GATT.allCharacteristicUUIDs, for: service)
    }

    private func handleCharacteristicsDiscovered(_ box: PeripheralBox, error: String?) {
        let p = box.peripheral
        if let error { teardownConnection(reason: .discoveryFailed(error)); return }
        guard let chars = p.services?.first(where: { $0.uuid == GATT.serviceUUID })?.characteristics else {
            teardownConnection(reason: .discoveryFailed("characteristics not found"))
            return
        }
        for c in chars {
            switch GATT.Characteristic(c.uuid) {
            case .sensor:     sensorChar = c
            case .command:    commandChar = c
            case .settings:   settingsChar = c
            case .deviceName: deviceNameChar = c
            case .deviceInfo: deviceInfoChar = c
            case .thresholds: thresholdsChar = c
            case .unknown:    break
            }
        }
        guard let sensor = sensorChar else {
            teardownConnection(reason: .discoveryFailed("sensor characteristic missing"))
            return
        }
        // Subscribe to the CCCD; the `.connected` transition happens once notifying (§3).
        p.setNotifyValue(true, for: sensor)
        if sensor.properties.contains(.read) { p.readValue(for: sensor) }

        // Settings, Device Name, Device Info and Thresholds are read once after
        // discovery (§2 / thresholds-v3 §2 item 5). The reads are issued directly
        // rather than through the public accessors, which gate on
        // `phase == .connected` — that transition happens later, on the CCCD
        // callback. A v2 unit has no Thresholds characteristic, so nothing is read.
        if let c = settingsChar   { p.readValue(for: c) }
        if let c = deviceNameChar { p.readValue(for: c) }
        if let c = deviceInfoChar { p.readValue(for: c) }
        if let c = thresholdsChar { p.readValue(for: c) }
    }

    private func handleNotificationStateChanged(_ kind: GATT.Characteristic, isNotifying: Bool, error: String?) {
        guard kind == .sensor else { return }
        if isNotifying, phase == .discovering {
            phase = .connected          // connect + discovery + CCCD subscription complete (§3)
            refreshMTU()
            startRSSIPolling()
        }
    }

    private func handleValueUpdate(_ kind: GATT.Characteristic, data: Data?, error: String?) {
        switch kind {
        case .sensor:
            guard let data else { return }
            // History sync packets share this characteristic; demux by payload[0] (§2).
            if data.first == GATT.historyPacketMarker {
                handleHistoryPacket(data)
                return
            }
            // A device on another contract version is refused outright rather
            // than decoded into plausible-looking numbers (notes §7 / §9.3).
            if unsupportedContract != nil { return }
            switch SensorParser.parse(data) {
            case .success(let reading):
                latestReading = reading
                lastParseError = nil
            case .failure(let err):
                lastParseError = err.message   // non-fatal (§7)
            }
        case .settings:
            guard let data else { return }
            // Decoded only after Device Info has cleared the contract guard; a
            // READ that lands first waits for it (see `pendingSettingsData`).
            guard deviceInfo != nil else {
                pendingSettingsData = data
                return
            }
            guard unsupportedContract == nil, let parsed = DeviceSettings(data: data) else { return }
            settings = parsed
        case .deviceName:
            guard let data else { return }
            // 1–20 bytes UTF-8, no NUL, trimmed (§1.4).
            let decoded = String(decoding: data.prefix { $0 != 0 }, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !decoded.isEmpty else { return }
            deviceName = decoded
            updateConnectedDeviceName(decoded)
        case .deviceInfo:
            guard let data, let parsed = DeviceInfo(data: data) else { return }
            deviceInfo = parsed
            applyContractGuard(parsed)
            if let pending = pendingSettingsData {
                pendingSettingsData = nil
                handleValueUpdate(.settings, data: pending, error: nil)
            }
        case .thresholds:
            // The read that closes a Save or a Restore defaults (or the one on
            // connect). Taken as-is — not validated — so the editor shows exactly
            // what the device holds (§3).
            isWritingThresholds = false
            guard unsupportedContract == nil, let data, let parsed = ThresholdsBlob.unpack(data) else { return }
            thresholds = parsed
            thresholdsRevision &+= 1
        default:
            break
        }
    }

    private func handleHistoryPacket(_ data: Data) {
        // History from a unit on another contract is refused like its live data.
        guard unsupportedContract == nil, let packet = HistoryPacketParser.parse(data) else { return }
        lastHistoryActivity = Date()   // progress — keep the inactivity watchdog at bay
        switch packet {
        case .record(let fields, let index, let total):
            historyStreamContinuation?.yield(.record(fields, index: index, total: total))
        case .endOfSync:
            historyWatchdog?.cancel()
            historyStreamContinuation?.yield(.endOfSync)
            historyStreamContinuation?.finish()
            historyStreamContinuation = nil
        }
    }

    private func handleWriteResult(_ kind: GATT.Characteristic, error: String?, attCode: Int?) {
        writeWatchdog?.cancel()
        let closesRestore = kind == .command && awaitingThresholdsRestore
        if closesRestore { awaitingThresholdsRestore = false }

        guard let error else {
            // Success. A Thresholds write or a `0x10` is followed by a re-read, so
            // the editor shows what the device actually stored (§3).
            if kind == .thresholds {
                commandFeedback = .succeeded("Thresholds saved.")
                readThresholds()
            } else if closesRestore {
                commandFeedback = .succeeded("Thresholds restored to defaults.")
                readThresholds()
            }
            return
        }
        // Firmware answers a rejected Thresholds or Settings write with ATT 0x0E
        // (`BLE_ATT_ERR_UNLIKELY`) too, so the opcode message is reserved for the
        // Command characteristic; every other kind gets its own message and re-read.
        switch kind {
        case .command where attCode == Int(GATT.attErrorUnknownOpcode):
            commandFeedback = .rejected("Command rejected by device (unknown opcode 0x0E).")
            if closesRestore { readThresholds() }
        case .settings:
            commandFeedback = .rejected("Settings rejected by device: \(error)")
            readSettings()      // re-read so the editor reflects what the device kept
        case .deviceName:
            commandFeedback = .rejected("Name rejected by device: \(error)")
            readDeviceName()
        case .thresholds:
            // Not expected — `validate()` mirrors every firmware rule — but if it
            // happens nothing was applied; re-read to show what the device kept.
            commandFeedback = .rejected("Thresholds rejected by device: \(error)")
            readThresholds()
        default:
            commandFeedback = .rejected("Command rejected: \(error)")
            if closesRestore { readThresholds() }
        }
    }

    private func handleRSSIRead(_ rssi: Int) { liveRSSI = rssi }

    /// Reads the negotiated ATT MTU. CoreBluetooth exposes no MTU property, so it
    /// is inferred from the largest write-without-response payload, which is
    /// `ATT_MTU - 3`. The exchange completes asynchronously after connecting, so
    /// this is sampled once the link is up and then refreshed on the RSSI tick
    /// until it stops changing — a single early read reports the 23-byte default
    /// and never corrects itself (notes §8).
    private func refreshMTU() {
        guard let p = connectedPeripheral else { return }
        let sampled = p.maximumWriteValueLength(for: .withoutResponse) + 3
        if mtu != sampled { mtu = sampled }
    }

    private func startRSSIPolling() {
        rssiPoller?.cancel()
        rssiPoller = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, let p = self.connectedPeripheral else { return }
                p.readRSSI()
                self.refreshMTU()   // converges once the ATT exchange settles
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }
}

// MARK: - HistorySyncTransport (§4)

extension BluetoothManager: HistorySyncTransport {
    /// A unit the contract guard refused is not offered for history sync, so its
    /// records are never parsed and the cache is never wiped on its account.
    var isConnected: Bool { phase == .connected && unsupportedContract == nil }

    /// Short per-device cache key: the last two bytes of the peripheral's
    /// Bluetooth identifier (iOS hides the raw MAC; CoreBluetooth's stable UUID
    /// is the platform equivalent). Matches DiscoveredDevice.shortIdentifier.
    var connectedDeviceID: String? {
        guard phase == .connected else { return nil }
        return connectedDevice?.shortIdentifier
    }

    /// Log-record version the device reports in Device Info byte 35 (§1.5).
    var deviceLogRecordVersion: UInt8? { deviceInfo?.logRecordVersion }

    /// Sends the sync command (0x01 full dump / 0x0C recent-N), then yields one
    /// HistoryStreamEvent per received history packet. Finishes on the end-of-sync
    /// sentinel, on link loss, or if no packet arrives within
    /// `historyInactivityTimeout` (firmware that doesn't stream).
    func startHistorySync(mode: HistorySyncMode) -> AsyncStream<HistoryStreamEvent> {
        let (stream, continuation) = AsyncStream<HistoryStreamEvent>.makeStream()
        historyStreamContinuation?.finish()   // cancel any in-flight sync
        historyStreamContinuation = continuation
        #if targetEnvironment(simulator)
        // No radio: stream synthetic 34-byte packets through the real parser (§2).
        startSimulatedHistoryStream(mode: mode)
        return stream
        #else
        switch mode {
        case .full:
            writeToCommand(Data([GATT.Command.syncHistory.rawValue]))
        case .recent(let count):
            writeToCommand(Data([
                GATT.Command.syncRecent.rawValue,
                UInt8(count & 0xFF),
                UInt8((count >> 8) & 0xFF),
                UInt8((count >> 16) & 0xFF),
                UInt8((count >> 24) & 0xFF),
            ]))
        }
        startHistoryWatchdog()
        return stream
        #endif
    }

    /// A single poller that ends the stream once no history packet has arrived for
    /// `historyInactivityTimeout`. `lastHistoryActivity` is refreshed per packet, so
    /// a long, healthy sync never trips it — only a stalled/absent one does.
    private func startHistoryWatchdog() {
        historyWatchdog?.cancel()
        lastHistoryActivity = Date()
        historyWatchdog = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self, !Task.isCancelled, self.historyStreamContinuation != nil else { return }
                if Date().timeIntervalSince(self.lastHistoryActivity) > Self.historyInactivityTimeout {
                    self.historyStreamContinuation?.finish()   // no records / no response
                    self.historyStreamContinuation = nil
                    return
                }
            }
        }
    }
}

// MARK: - CBCentralManagerDelegate (nonisolated shims → MainActor handlers)

extension BluetoothManager: CBCentralManagerDelegate {

    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let state = central.state
        Task { @MainActor [weak self] in self?.handleStateChange(state) }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any],
                                    rssi RSSI: NSNumber) {
        // Advertised local name only — it is fresh per advertisement. Deliberately
        // NOT `peripheral.name`: iOS caches that, and it can keep showing a unit's
        // OLD nickname for the lifetime of the app install (notes §6 / §9). When a
        // peripheral advertises no local name we show the neutral product label;
        // the row also carries the identifier suffix to tell units apart.
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 }
            ?? GATT.advertisedName
        let box = PeripheralBox(peripheral: peripheral)
        let rssi = RSSI.intValue
        Task { @MainActor [weak self] in self?.handleDiscovery(box, name: name, rssi: rssi) }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        let box = PeripheralBox(peripheral: peripheral)
        Task { @MainActor [weak self] in self?.handleConnected(box) }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didDisconnectPeripheral peripheral: CBPeripheral,
                                    error: Error?) {
        let desc = error?.localizedDescription
        Task { @MainActor [weak self] in self?.handleDisconnect(error: desc) }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didFailToConnect peripheral: CBPeripheral,
                                    error: Error?) {
        let desc = error?.localizedDescription
        Task { @MainActor [weak self] in self?.handleConnectFailed(error: desc) }
    }
}

// MARK: - CBPeripheralDelegate (nonisolated shims → MainActor handlers)

extension BluetoothManager: CBPeripheralDelegate {

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        let box = PeripheralBox(peripheral: peripheral)
        let desc = error?.localizedDescription
        Task { @MainActor [weak self] in self?.handleServicesDiscovered(box, error: desc) }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didDiscoverCharacteristicsFor service: CBService,
                                error: Error?) {
        let box = PeripheralBox(peripheral: peripheral)
        let desc = error?.localizedDescription
        Task { @MainActor [weak self] in self?.handleCharacteristicsDiscovered(box, error: desc) }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didUpdateValueFor characteristic: CBCharacteristic,
                                error: Error?) {
        let kind = GATT.Characteristic(characteristic.uuid)
        let value = characteristic.value
        let desc = error?.localizedDescription
        Task { @MainActor [weak self] in self?.handleValueUpdate(kind, data: value, error: desc) }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didUpdateNotificationStateFor characteristic: CBCharacteristic,
                                error: Error?) {
        let kind = GATT.Characteristic(characteristic.uuid)
        let isNotifying = characteristic.isNotifying
        let desc = error?.localizedDescription
        Task { @MainActor [weak self] in
            self?.handleNotificationStateChanged(kind, isNotifying: isNotifying, error: desc)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didWriteValueFor characteristic: CBCharacteristic,
                                error: Error?) {
        let kind = GATT.Characteristic(characteristic.uuid)
        let desc = error?.localizedDescription
        let attCode = (error as NSError?)?.code
        Task { @MainActor [weak self] in self?.handleWriteResult(kind, error: desc, attCode: attCode) }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        let rssi = RSSI.intValue
        Task { @MainActor [weak self] in self?.handleRSSIRead(rssi) }
    }
}

// MARK: - Simulation (Simulator only)
//
// Synthetic transport used because the iOS Simulator has no Bluetooth radio.
// Readings are built into real 52-byte contract-v3 packets and history into real
// 34-byte packets, then decoded by the production SensorParser and
// HistoryPacketParser — so this exercises the same wire path as live hardware
// (§2). The Thresholds blob round-trips through the real pack/unpack, and the
// synthetic unit classifies its readings against it the way firmware does, so
// editing an edge visibly moves a tile. Compiled only for the Simulator; never
// present in device builds.

#if targetEnvironment(simulator)
extension BluetoothManager {

    // Two fixed synthetic units so the multi-device scan list (§5) is exercisable.
    private static let simIDs: [UUID] = [
        UUID(uuidString: "11111111-1111-1111-1111-1111111111AB")!,
        UUID(uuidString: "22222222-2222-2222-2222-2222222222CD")!,
    ]

    /// Device Info a synthetic unit reports — a plausible SEN66 serial and the
    /// contract/record versions this build implements (§1.5).
    static let simDeviceInfo = DeviceInfo(
        serial: "SEN66-0A1B2C3D4E5F",
        firmwareMajor: 1,
        firmwareMinor: 4,
        contractVersion: GATT.contractVersion,
        logRecordVersion: GATT.historyRecordVersion
    )

    /// Ticks the synthetic unit spends warming up after connecting, so the
    /// "Warming up" treatment (status bit 2, class byte 0) is exercisable (§2).
    private static let simWarmupTicks: UInt16 = 4

    /// Test hook: skip the scan and land directly in a connected session.
    func debugAutoConnect() {
        let id = Self.simIDs[0]
        discoveredDevices = [DiscoveredDevice(id: id, name: simDeviceName, rssi: -47)]
        connectSimulated(to: id)
    }

    func startSimulatedScan() {
        scanState = .scanning
        discoveredDevices = []
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard let self, self.scanState == .scanning else { return }
            self.discoveredDevices = [
                DiscoveredDevice(id: Self.simIDs[0], name: self.simDeviceName, rssi: -47),
                DiscoveredDevice(id: Self.simIDs[1], name: GATT.advertisedName, rssi: -68),
            ]
            // Jitter RSSI in place so the live-update behaviour is visible (§3/§5).
            while !Task.isCancelled, self.scanState == .scanning {
                try? await Task.sleep(for: .seconds(2))
                guard self.scanState == .scanning else { break }
                for i in self.discoveredDevices.indices {
                    self.discoveredDevices[i].rssi += Int.random(in: -3...3)
                }
                self.discoveredDevices.sort { $0.rssi > $1.rssi }
            }
        }
    }

    func connectSimulated(to id: UUID) {
        stopScan()
        clearDisconnectReason()
        connectedDevice = discoveredDevices.first { $0.id == id }
            ?? DiscoveredDevice(id: id, name: simDeviceName, rssi: -50)
        phase = .connecting
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard let self, self.phase == .connecting else { return }
            self.phase = .discovering
            try? await Task.sleep(for: .milliseconds(400))
            guard self.phase == .discovering else { return }
            self.phase = .connected
            self.simSequence = 0
            self.settings = self.simSettings
            self.deviceName = self.simDeviceName
            self.deviceInfo = Self.simDeviceInfo
            self.readThresholds()
            self.liveRSSI = self.connectedDevice?.rssi ?? -50
            self.mtu = 185
            self.startSimulatedReadings()
        }
    }

    private func startSimulatedReadings() {
        simLoop?.cancel()
        simLoop = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, self.phase == .connected else { return }
                self.emitSimulatedReading()
                try? await Task.sleep(for: .seconds(2))   // matches the 2 s notify cadence
            }
        }
    }

    private func simulateCommand(_ command: GATT.Command, parameter: UInt8?) {
        switch command {
        case .fanOff:  simFanSpeed = 0;   simSettings.fanMode = .manual; simSettings.fanManualPct = 0
        case .fanLow:  simFanSpeed = 25;  simSettings.fanMode = .manual; simSettings.fanManualPct = 25
        case .fanMed:  simFanSpeed = 50;  simSettings.fanMode = .manual; simSettings.fanManualPct = 50
        case .fanHigh: simFanSpeed = 75;  simSettings.fanMode = .manual; simSettings.fanManualPct = 75
        case .fanMax:  simFanSpeed = 100; simSettings.fanMode = .manual; simSettings.fanManualPct = 100
        case .fanManual:
            simFanSpeed = Int(parameter ?? 0)
            simSettings.fanMode = .manual
            simSettings.fanManualPct = UInt8(simFanSpeed)
        case .fanAuto:
            simSettings.fanMode = .auto
            simFanSpeed = 50        // pretend the controller settled here
        case .restoreThresholds:
            simThresholds = .defaults
            readThresholds()
            commandFeedback = .succeeded("Thresholds restored to defaults.")
        case .getStatus: break      // forces an immediate emit below
        case .fanCleaning, .clearErrors, .co2Recal:
            simSen66Status = 0      // maintenance clears the synthetic fault register
        case .syncHistory, .syncRecent: return  // handled by the simulated history stream
        case .setTime: return                   // setDeviceTime() short-circuits before sendCommand
        }
        settings = simSettings
        liveRSSI = (connectedDevice?.rssi ?? -50) + Int.random(in: -2...2)
        emitSimulatedReading()
    }

    /// Builds a realistic 52-byte v2 packet and feeds it through the production
    /// parser, on the same path a live notification takes.
    private func emitSimulatedReading() {
        let warming = simSequence < Self.simWarmupTicks

        let t = Date()
        let hour = Double(Calendar.current.component(.hour, from: t))
        let dayPhase = sin((hour - 9.0) / 24.0 * 2 * .pi)
        let temp = 22.0 + dayPhase * 3 + Double.random(in: -0.3...0.3)
        let humidity = 46.0 - dayPhase * 6 + Double.random(in: -1...1)

        var vocIndex = 95.0 + dayPhase * 25 + Double.random(in: -12...30)
        if Double.random(in: 0...1) < 0.05 { vocIndex += Double.random(in: 120...300) }
        vocIndex = min(500, max(1, vocIndex))
        let noxIndex = min(500, max(1, 6.0 + dayPhase * 3 + Double.random(in: -3...6)))
        let co2 = 430 + Int((vocIndex - 95) * 1.6) + Int.random(in: -20...40)

        let pm1  = 4.0 + Double.random(in: 0...6)
        let pm25 = pm1 + Double.random(in: 2...8)
        let pm4  = pm25 + Double.random(in: 0.5...3)
        let pm10 = pm4 + Double.random(in: 0.5...5)

        // Occasionally inject a sentinel so the "—" handling is visible (§4).
        let injectSentinel = !warming && Double.random(in: 0...1) < 0.06
        // Occasionally raise the SEN66 fan-speed warning so its yellow row shows.
        if !warming, Double.random(in: 0...1) < 0.03 { simSen66Status = 1 << 21 }

        var status: UInt8 = 0x01            // bit0 SEN66 present
        status |= 0x02                      // bit1 fresh reading this tick
        if warming { status |= 0x04 }       // bit2 SEN66 warming
        status |= 0x08                      // bit3 TWAI online
        if simSen66Status & 0x00000AD0 != 0 { status |= 0x10 }   // bit4 sticky error
        status |= 0x40                      // bit6 ionizer powered
        if Double.random(in: 0...1) < 0.03 { status |= 0x20 }    // bit5 ionizer fault

        let pmValid = !warming && !injectSentinel
        let classes = warming ? AirClasses.unknown : Self.simClasses(
            vocIndex: vocIndex, noxIndex: noxIndex, co2: co2,
            pm1: pmValid ? pm1 : nil, pm25: pmValid ? pm25 : nil, pm10: pmValid ? pm10 : nil,
            thresholds: simThresholds)

        let packet = Self.makeSimPacket(
            sequence: simSequence,
            tempC: injectSentinel ? nil : temp,
            humidity: humidity,
            vocIndex: warming ? nil : vocIndex,
            noxIndex: warming ? nil : noxIndex,
            co2: warming ? nil : co2,
            pm1:  warming || injectSentinel ? nil : pm1,   // nil → 0xFFFF, exercises the "—" path
            pm25: warming || injectSentinel ? nil : pm25,
            pm4:  warming || injectSentinel ? nil : pm4,
            pm10: warming || injectSentinel ? nil : pm10,
            classByte: classes.byte,
            fan: simFanSpeed,
            fanMode: simSettings.fanMode ?? .auto,
            status: status,
            sen66Status: simSen66Status
        )
        simSequence = simSequence &+ 1
        handleValueUpdate(.sensor, data: packet, error: nil)   // same path as live notifications
    }

    /// Classifies a synthetic reading the way firmware does (thresholds-v3 §2.2,
    /// without hysteresis): per gas, at or below C1 → 1 … above C4 → 5, worst of
    /// the three; per PM channel, at or below attention → 1, at or below hazard →
    /// 2, else 3, worst of PM1 / PM2.5 / PM10. The Simulator stands in for the
    /// device here — the app itself never derives a class from raw values.
    private static func simClasses(
        vocIndex: Double?, noxIndex: Double?, co2: Int?,
        pm1: Double?, pm25: Double?, pm10: Double?,
        thresholds t: ThresholdsBlob
    ) -> AirClasses {
        func gasClass(_ value: Double?, _ edges: [UInt16]) -> UInt8 {
            // Firmware compares whole index values (live bytes 8–11 ÷ 10, truncated).
            guard let whole = value?.rounded(.towardZero) else { return 0 }
            return UInt8((edges.firstIndex { whole <= Double($0) } ?? edges.count) + 1)
        }
        func pmClass(_ value: Double?, _ channel: ThresholdsBlob.PMChannel) -> UInt8 {
            guard let value else { return 0 }
            if value <= Double(t.attention(channel)) / 10 { return 1 }
            return value <= Double(t.hazard(channel)) / 10 ? 2 : 3
        }
        let gas = Swift.max(gasClass(vocIndex, t.edges(.voc)),
                            gasClass(noxIndex, t.edges(.nox)),
                            gasClass(co2.map(Double.init), t.edges(.co2)))
        let pm = Swift.max(pmClass(pm1, .pm1), pmClass(pm25, .pm25), pmClass(pm10, .pm10))
        return AirClasses(gas: gas, pm: pm)
    }

    /// Encodes values into the authoritative 52-byte v3 layout (§1.1).
    private static func makeSimPacket(
        sequence: UInt16,
        tempC: Double?, humidity: Double?, vocIndex: Double?, noxIndex: Double?, co2: Int?,
        pm1: Double?, pm25: Double?, pm4: Double?, pm10: Double?,
        classByte: UInt8, fan: Int, fanMode: FanMode, status: UInt8, sen66Status: UInt32
    ) -> Data {
        var b = [UInt8](repeating: 0, count: GATT.sensorPayloadLength)
        let o = GATT.SensorOffset.self

        func putU16(_ v: UInt16, _ i: Int) { b[i] = UInt8(v & 0xFF); b[i + 1] = UInt8(v >> 8) }
        func putI16(_ v: Int16, _ i: Int)  { putU16(UInt16(bitPattern: v), i) }
        func putU32(_ v: UInt32, _ i: Int) {
            b[i]     = UInt8(v & 0xFF)
            b[i + 1] = UInt8((v >> 8) & 0xFF)
            b[i + 2] = UInt8((v >> 16) & 0xFF)
            b[i + 3] = UInt8((v >> 24) & 0xFF)
        }
        /// Encodes a ×10 display value, or the invalid sentinel for nil. Valid
        /// values cap at 65533 so 0xFFFE/0xFFFF stay reserved.
        func putX10(_ v: Double?, _ i: Int) {
            putU16(v.map { UInt16(min(65533, max(0, ($0 * 10).rounded()))) } ?? GATT.u16Sentinel, i)
        }

        b[o.marker] = GATT.livePacketMarker
        b[o.payloadVersion] = GATT.livePayloadVersion
        putU16(sequence, o.sequence)
        putI16(tempC.map { Int16((max(-320, min(320, $0)) * 100).rounded()) } ?? GATT.i16Sentinel, o.temperature)
        putU16(humidity.map { UInt16(max(0, min(655, $0)) * 100) } ?? GATT.u16Sentinel, o.humidity)
        putX10(vocIndex, o.vocIndex)
        putX10(noxIndex, o.noxIndex)
        putU16(co2.map { UInt16(min(65533, max(0, $0))) } ?? GATT.u16Sentinel, o.co2)
        putX10(pm1,  o.pm1)
        putX10(pm25, o.pm25)
        putX10(pm4,  o.pm4)
        putX10(pm10, o.pm10)
        // Number concentrations track PM with plausible ordering.
        putX10(pm1.map  { $0 * 1.6 }, o.nc05)
        putX10(pm1.map  { $0 * 1.1 }, o.nc1)
        putX10(pm25.map { $0 * 0.6 }, o.nc25)
        putX10(pm4.map  { $0 * 0.4 }, o.nc4)
        putX10(pm10.map { $0 * 0.3 }, o.nc10)
        b[o.classByte]  = classByte
        b[o.fanPercent] = UInt8(max(0, min(100, fan)))
        b[o.fanMode]    = fanMode.wire
        b[o.status]     = status
        putU32(sen66Status, o.sen66Status)
        putU16(vocIndex.map { UInt16(min(65533, $0 * 40)) } ?? GATT.u16Sentinel, o.rawVOCTicks)
        putU16(noxIndex.map { UInt16(min(65533, $0 * 35)) } ?? GATT.u16Sentinel, o.rawNOxTicks)
        putU16(co2.map { UInt16(min(65533, max(0, $0 + Int.random(in: -8...8)))) } ?? GATT.u16Sentinel, o.rawCO2)
        putI16(humidity.map { Int16(($0 * 100).rounded()) } ?? GATT.i16Sentinel, o.rawHumidity)
        putI16(tempC.map { Int16(((($0) + 1.2) * 200).rounded()) } ?? GATT.i16Sentinel, o.rawTemperature)
        b[o.deviceState] = DeviceState.enabled.rawValue
        b[o.reserved]    = 0
        return Data(b)
    }

    // MARK: - Simulated history stream (§2)

    /// Streams synthetic 34-byte history packets through `HistoryPacketParser`,
    /// finishing with the all-zero sentinel, so the BLE history path is
    /// exercisable without hardware.
    func startSimulatedHistoryStream(mode: HistorySyncMode) {
        let count: Int
        switch mode {
        case .full:              count = 720          // ~12 h at 1/min
        case .recent(let n):     count = Int(min(n, 2_000))
        }
        simHistoryTask?.cancel()
        simHistoryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let now = Date()
            for i in 0..<count {
                if Task.isCancelled || self.historyStreamContinuation == nil { return }
                let timestamp = now.addingTimeInterval(-Double(count - i) * 60)
                self.handleHistoryPacket(Self.makeSimHistoryPacket(
                    index: i, total: count, timestamp: timestamp, sequence: UInt16(truncatingIfNeeded: i),
                    thresholds: self.simThresholds))
                if i % 120 == 119 { try? await Task.sleep(for: .milliseconds(8)) }  // yield to the UI
            }
            if Task.isCancelled || self.historyStreamContinuation == nil { return }
            self.handleHistoryPacket(Self.makeSimHistorySentinel(total: count))
        }
    }

    /// Encodes one 34-byte history packet carrying a 26-byte log record v3 (§1.2).
    private static func makeSimHistoryPacket(
        index: Int, total: Int, timestamp: Date, sequence: UInt16, thresholds: ThresholdsBlob
    ) -> Data {
        var b = [UInt8](repeating: 0, count: GATT.historyPacketLength)
        func putU16(_ v: UInt16, _ i: Int) { b[i] = UInt8(v & 0xFF); b[i + 1] = UInt8(v >> 8) }
        func putU24(_ v: UInt32, _ i: Int) {
            b[i] = UInt8(v & 0xFF); b[i + 1] = UInt8((v >> 8) & 0xFF); b[i + 2] = UInt8((v >> 16) & 0xFF)
        }
        func putU32(_ v: UInt32, _ i: Int) {
            putU24(v, i); b[i + 3] = UInt8((v >> 24) & 0xFF)
        }

        b[0] = GATT.historyPacketMarker
        b[1] = GATT.historyHeaderMarker
        putU24(UInt32(total), GATT.historyTotalCountOffset)
        putU24(UInt32(index), GATT.historyRecordIndexOffset)

        let r = GATT.historyRecordOffset
        let f = GATT.HistoryRecordOffset.self
        let phase = sin(Double(index) / 90.0)
        let vocIndex = min(500.0, max(1.0, 95 + phase * 30 + Double.random(in: -8...8)))
        let noxIndex = min(500.0, max(1.0, 6 + phase * 3 + Double.random(in: -2...4)))
        let co2 = 430 + Int((vocIndex - 95) * 1.6)
        let pm25 = 9 + phase * 5 + Double.random(in: -2...2)

        func putX10(_ v: Double, _ i: Int) {
            putU16(UInt16(min(65533, max(0, (v * 10).rounded()))), r + i)
        }

        putU32(UInt32(timestamp.timeIntervalSince1970), r + f.timestamp)
        putU16(UInt16(bitPattern: Int16(((22 + phase * 3) * 100).rounded())), r + f.temperature)
        putU16(UInt16((46 - phase * 6) * 100), r + f.humidity)
        putX10(vocIndex, f.vocIndex)
        putX10(noxIndex, f.noxIndex)
        putU16(UInt16(co2), r + f.co2)
        putX10(max(0, pm25 - 4), f.pm1)
        putX10(max(0, pm25), f.pm25)
        putX10(max(0, pm25 + 2), f.pm4)
        putX10(max(0, pm25 + 5), f.pm10)
        b[r + f.classByte] = simClasses(
            vocIndex: vocIndex, noxIndex: noxIndex, co2: co2,
            pm1: max(0, pm25 - 4), pm25: max(0, pm25), pm10: max(0, pm25 + 5),
            thresholds: thresholds).byte
        b[r + f.status]  = 0x4B          // present · fresh · TWAI online · ionizer on
        putU16(sequence, r + f.sequence)
        return Data(b)
    }

    /// The end-of-sync sentinel: framing intact, all 26 record bytes zero (§1.2).
    private static func makeSimHistorySentinel(total: Int) -> Data {
        var b = [UInt8](repeating: 0, count: GATT.historyPacketLength)
        b[0] = GATT.historyPacketMarker
        b[1] = GATT.historyHeaderMarker
        func putU24(_ v: UInt32, _ i: Int) {
            b[i] = UInt8(v & 0xFF); b[i + 1] = UInt8((v >> 8) & 0xFF); b[i + 2] = UInt8((v >> 16) & 0xFF)
        }
        putU24(UInt32(total), GATT.historyTotalCountOffset)
        putU24(UInt32(total), GATT.historyRecordIndexOffset)
        return Data(b)
    }
}
#endif
