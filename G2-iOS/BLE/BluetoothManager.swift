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

    private(set) var thresholds: TVOCThresholds?     // READ from the Settings characteristic
    private(set) var liveRSSI: Int?
    private(set) var mtu: Int?

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
    @ObservationIgnored private var simThresholds: TVOCThresholds = .defaults
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

        phase = .disconnected
        connectedDevice = nil
        latestReading = nil
        lastParseError = nil
        thresholds = nil
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
    /// No-op in the Simulator, which has no radio.
    private func writeToCommand(_ payload: Data) {
        #if targetEnvironment(simulator)
        _ = payload
        #else
        guard phase == .connected, let p = connectedPeripheral, let c = commandChar else {
            commandFeedback = .rejected("Not connected")
            return
        }
        let type: CBCharacteristicWriteType = c.properties.contains(.write) ? .withResponse : .withoutResponse
        p.writeValue(payload, for: c, type: type)
        if type == .withResponse { startWriteWatchdog() }
        #endif
    }

    func setFanAuto()      { sendCommand(.fanAuto) }
    func setFanTVOCAuto()  { sendCommand(.fanTVOCAuto) }
    func setFanPreset(_ preset: FanPreset) { sendCommand(preset.command) }
    func refreshNow()      { sendCommand(.getStatus) }   // 0x09 (§2.4 / §6.2)

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

    // MARK: - Settings (§2.5 / §6.4)

    func readSettings() {
        #if targetEnvironment(simulator)
        thresholds = simThresholds
        #else
        guard phase == .connected, let p = connectedPeripheral, let c = settingsChar else { return }
        p.readValue(for: c)
        #endif
    }

    /// Validates strict-increasing thresholds client-side, then writes 8 bytes (§2.5).
    /// Returns false (without writing) if non-monotonic.
    @discardableResult
    func writeSettings(_ thresholds: TVOCThresholds) -> Bool {
        guard thresholds.isMonotonic else {
            commandFeedback = .rejected("Thresholds must be strictly increasing (lo < med < hi < max).")
            return false
        }
        #if targetEnvironment(simulator)
        simThresholds = thresholds
        self.thresholds = thresholds
        return true
        #else
        guard phase == .connected, let p = connectedPeripheral, let c = settingsChar else {
            commandFeedback = .rejected("Not connected")
            return false
        }
        p.writeValue(thresholds.encoded, for: c, type: .withResponse)
        startWriteWatchdog()
        return true
        #endif
    }

    private func startWriteWatchdog() {
        writeWatchdog?.cancel()
        writeWatchdog = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.writeTimeout)
            guard let self, !Task.isCancelled else { return }
            self.commandFeedback = .timedOut   // never spin forever on a pending write (§7)
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
            discoveredDevices[idx].rssi = rssi   // update in place (§3/§5)
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
        mtu = p.maximumWriteValueLength(for: .withoutResponse) + 3   // ATT MTU ≈ payload + 3
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
        p.discoverCharacteristics(
            [GATT.sensorCharacteristicUUID, GATT.commandCharacteristicUUID, GATT.settingsCharacteristicUUID],
            for: service
        )
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
            case .sensor:   sensorChar = c
            case .command:  commandChar = c
            case .settings: settingsChar = c
            case .unknown:  break
            }
        }
        guard let sensor = sensorChar else {
            teardownConnection(reason: .discoveryFailed("sensor characteristic missing"))
            return
        }
        // Subscribe to the CCCD; the `.connected` transition happens once notifying (§3).
        p.setNotifyValue(true, for: sensor)
        if sensor.properties.contains(.read) { p.readValue(for: sensor) }
        readSettings()
    }

    private func handleNotificationStateChanged(_ kind: GATT.Characteristic, isNotifying: Bool, error: String?) {
        guard kind == .sensor else { return }
        if isNotifying, phase == .discovering {
            phase = .connected          // connect + discovery + CCCD subscription complete (§3)
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
            switch SensorParser.parse(data) {
            case .success(let reading):
                latestReading = reading
                lastParseError = nil
            case .failure(let err):
                if case let .malformedPacket(length) = err {
                    lastParseError = "Malformed packet (\(length) bytes)"  // non-fatal (§7)
                }
            }
        case .settings:
            guard let data, let parsed = TVOCThresholds(data: data) else { return }
            thresholds = parsed
        default:
            break
        }
    }

    private func handleHistoryPacket(_ data: Data) {
        guard let packet = HistoryPacketParser.parse(data) else { return }
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
        guard let error else { return }   // success
        if attCode == Int(GATT.attErrorUnknownOpcode) {
            commandFeedback = .rejected("Command rejected by device (unknown opcode 0x0E).")
        } else if kind == .settings {
            commandFeedback = .rejected("Settings rejected by device: \(error)")
        } else {
            commandFeedback = .rejected("Command rejected: \(error)")
        }
    }

    private func handleRSSIRead(_ rssi: Int) { liveRSSI = rssi }

    private func startRSSIPolling() {
        rssiPoller?.cancel()
        rssiPoller = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, let p = self.connectedPeripheral else { return }
                p.readRSSI()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }
}

// MARK: - HistorySyncTransport (§4)

extension BluetoothManager: HistorySyncTransport {
    var isConnected: Bool { phase == .connected }

    /// Short per-device cache key: the last two bytes of the peripheral's
    /// Bluetooth identifier (iOS hides the raw MAC; CoreBluetooth's stable UUID
    /// is the platform equivalent). Matches DiscoveredDevice.shortIdentifier.
    var connectedDeviceID: String? {
        guard phase == .connected else { return nil }
        return connectedDevice?.shortIdentifier
    }

    /// Sends the sync command (0x01 full dump / 0x0C recent-N), then yields one
    /// HistoryStreamEvent per received history packet. Finishes on the end-of-sync
    /// sentinel, on link loss, or if no packet arrives within
    /// `historyInactivityTimeout` (firmware that doesn't stream).
    func startHistorySync(mode: HistorySyncMode) -> AsyncStream<HistoryStreamEvent> {
        let (stream, continuation) = AsyncStream<HistoryStreamEvent>.makeStream()
        historyStreamContinuation?.finish()   // cancel any in-flight sync
        historyStreamContinuation = continuation
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
        // Prefer the advertised local name; fall back to the GATT device name.
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
            ?? peripheral.name
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
// Readings are built into real 31-byte packets and decoded by the production
// SensorParser, so this exercises the same parsing path as live hardware.
// Compiled only for the Simulator; never present in device builds.

#if targetEnvironment(simulator)
extension BluetoothManager {

    // Two fixed synthetic units so the multi-device scan list (§5) is exercisable.
    private static let simIDs: [UUID] = [
        UUID(uuidString: "11111111-1111-1111-1111-1111111111AB")!,
        UUID(uuidString: "22222222-2222-2222-2222-2222222222CD")!,
    ]

    /// Test hook: skip the scan and land directly in a connected session.
    func debugAutoConnect() {
        let id = Self.simIDs[0]
        discoveredDevices = [DiscoveredDevice(id: id, name: GATT.advertisedName, rssi: -47)]
        connectSimulated(to: id)
    }

    func startSimulatedScan() {
        scanState = .scanning
        discoveredDevices = []
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard let self, self.scanState == .scanning else { return }
            self.discoveredDevices = [
                DiscoveredDevice(id: Self.simIDs[0], name: "\(GATT.advertisedName)", rssi: -47),
                DiscoveredDevice(id: Self.simIDs[1], name: "\(GATT.advertisedName)", rssi: -68),
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
            ?? DiscoveredDevice(id: id, name: GATT.advertisedName, rssi: -50)
        phase = .connecting
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard let self, self.phase == .connecting else { return }
            self.phase = .discovering
            try? await Task.sleep(for: .milliseconds(400))
            guard self.phase == .discovering else { return }
            self.phase = .connected
            self.thresholds = self.simThresholds
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
        case .fanOff:  simFanSpeed = 0
        case .fanLow:  simFanSpeed = 25
        case .fanMed:  simFanSpeed = 50
        case .fanHigh: simFanSpeed = 75
        case .fanMax:  simFanSpeed = 100
        case .fanManual: simFanSpeed = Int(parameter ?? 0)
        case .fanAuto, .fanTVOCAuto: simFanSpeed = 50   // pretend the controller settled here
        case .getStatus: break                          // forces an immediate emit below
        case .syncHistory, .syncRecent: return           // history is handled by the repository
        case .setTime: return                           // setDeviceTime() short-circuits before sendCommand
        }
        liveRSSI = (connectedDevice?.rssi ?? -50) + Int.random(in: -2...2)
        emitSimulatedReading()
    }

    /// Builds a realistic 31-byte packet and feeds it through the production parser.
    private func emitSimulatedReading() {
        let t = Date()
        let hour = Double(Calendar.current.component(.hour, from: t))
        let dayPhase = sin((hour - 9.0) / 24.0 * 2 * .pi)
        let temp = 22.0 + dayPhase * 3 + Double.random(in: -0.3...0.3)
        let hum = 46.0 - dayPhase * 6 + Double.random(in: -1...1)
        let tvoc = max(0, Int((120 + dayPhase * 40 + Double.random(in: -25...60)).rounded()))
        let eco2 = 420 + Int(Double(tvoc) * 0.5) + Int.random(in: -20...40)
        let pm1 = Int.random(in: 4...12), pm25 = Int.random(in: 8...20), pm10 = Int.random(in: 12...30)
        let aqi: UInt8 = tvoc < 150 ? 2 : tvoc < 350 ? 3 : tvoc < 650 ? 4 : 5

        // Occasionally inject a sentinel so the "—" handling is visible (§6.1).
        let injectSentinel = Double.random(in: 0...1) < 0.06

        let packet = Self.makeSimPacket(
            tempC: injectSentinel ? nil : temp,
            humidity: hum,
            tvoc: tvoc,
            eco2: eco2,
            pm1:  injectSentinel ? nil : pm1,   // nil → 0xFFFF, exercises PM "—" path
            pm25: injectSentinel ? nil : pm25,
            pm10: injectSentinel ? nil : pm10,
            aqi: injectSentinel ? 0 : aqi,
            fan: simFanSpeed,
            status: 0x1F,                 // all sensors healthy
            sequence: simSequence
        )
        simSequence = simSequence &+ 1
        handleValueUpdate(.sensor, data: packet, error: nil)   // same path as live notifications
    }

    /// Encodes values into the authoritative 31-byte layout (§2.3), including the
    /// embedded header bytes 0–7 that the parser must skip.
    private static func makeSimPacket(
        tempC: Double?, humidity: Double?, tvoc: Int?, eco2: Int?,
        pm1: Int?, pm25: Int?, pm10: Int?, aqi: UInt8, fan: Int, status: UInt8, sequence: UInt16
    ) -> Data {
        var b = [UInt8](repeating: 0, count: GATT.sensorPayloadLength)
        b.replaceSubrange(0..<3, with: [0x02, 0x01, 0x06])               // AD flags
        b.replaceSubrange(3..<8, with: [0x1A, 0xFF, 0x8E, 0x8E, 0x01])   // mfr-specific
        func putU16(_ v: UInt16, _ i: Int) { b[i] = UInt8(v & 0xFF); b[i + 1] = UInt8(v >> 8) }

        let tRaw = tempC.map { Int16(max(-320, min(320, $0)) * 100) } ?? Int16(bitPattern: 0x8000)
        putU16(UInt16(bitPattern: tRaw), 8)
        putU16(humidity.map { UInt16(max(0, min(655, $0)) * 100) } ?? 0xFFFF, 10)
        putU16(tvoc.map { UInt16(min(65534, $0)) } ?? 0xFFFF, 12)
        putU16(eco2.map { UInt16(min(65534, $0)) } ?? 0xFFFF, 14)
        // Cap valid PM at 65533; 0xFFFE (over-range) and 0xFFFF (no-reading) are
        // reserved sentinels. nil encodes as no-reading.
        putU16(pm1.map  { UInt16(min(65533, $0)) } ?? GATT.pmSentinelNoReading, 16)
        putU16(pm25.map { UInt16(min(65533, $0)) } ?? GATT.pmSentinelNoReading, 18)
        putU16(pm10.map { UInt16(min(65533, $0)) } ?? GATT.pmSentinelNoReading, 20)
        b[22] = aqi
        b[23] = UInt8(max(0, min(100, fan)))
        b[24] = status
        putU16(sequence, 25)
        return Data(b)
    }
}
#endif
