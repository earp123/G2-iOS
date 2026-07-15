//
//  Smart_Air_MonitorApp.swift
//  Smart Air Monitor — GEUE Air Quality (G2) client
//
//  Composition root: builds the SwiftData container, the single BluetoothManager,
//  and the history layer behind a DI switch (mock vs BLE, §4.1).
//

import SwiftUI
import SwiftData

@main
struct Smart_Air_MonitorApp: App {

    /// Repository DI switch (§4.1). On device, `.ble` streams real history from the
    /// connected prototype (CMD_SYNC_HISTORY). The Simulator has no BLE radio, so it
    /// falls back to `.mock` synthetic data to keep the history UI developable.
    /// Override either branch to force a source.
    #if targetEnvironment(simulator)
    private static let historyDataSource: HistoryDataSource = .mock
    #else
    private static let historyDataSource: HistoryDataSource = .ble
    #endif

    @State private var bluetooth: BluetoothManager
    @State private var history: HistoryStore
    private let container: ModelContainer

    init() {
        let container: ModelContainer
        do {
            container = try ModelContainer(for: HistoryRecord.self)
        } catch {
            fatalError("Failed to create SwiftData container: \(error)")
        }
        self.container = container

        let manager = BluetoothManager()
        let context = container.mainContext

        // Discard records left by a different source (e.g. leftover mock data when
        // switching to live BLE) so stale rows never masquerade as device history.
        Self.clearHistoryIfSourceChanged(in: context)

        let repository: HistoryRepository
        switch Self.historyDataSource {
        case .mock:
            repository = MockHistoryRepository(context: context)
        case .ble:
            repository = BLEHistoryRepository(context: context, transport: manager)
        }

        _bluetooth = State(initialValue: manager)
        _history = State(initialValue: HistoryStore(repository: repository))
    }

    /// Wipes persisted history when the DI source differs from the last launch.
    private static func clearHistoryIfSourceChanged(in context: ModelContext) {
        let key = "historyDataSource"
        let current = String(describing: historyDataSource)   // "mock" / "ble"
        let defaults = UserDefaults.standard
        guard defaults.string(forKey: key) != current else { return }
        try? context.delete(model: HistoryRecord.self)
        try? context.save()
        defaults.set(current, forKey: key)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(bluetooth)
                .environment(history)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
        }
        .modelContainer(container)
    }
}
