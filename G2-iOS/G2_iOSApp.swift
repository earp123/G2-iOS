//
//  G2_iOSApp.swift
//  G2-iOS — GEUE Air Quality (G2) client
//
//  Composition root: builds the SwiftData container, the single BluetoothManager,
//  and the history layer behind a DI switch (mock vs BLE, §4.1).
//

import SwiftUI
import SwiftData

@main
struct G2_iOSApp: App {

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

        // Discard records left by a different source or cache generation (e.g.
        // leftover mock data when switching to live BLE, or pre-device-scoped rows
        // after an upgrade) so stale rows never masquerade as device history.
        Self.clearHistoryIfSourceChanged(in: context)

        let dataStore = HistoryDataStore(modelContainer: container)

        let repository: HistoryRepository
        switch Self.historyDataSource {
        case .mock:
            repository = MockHistoryRepository(dataStore: dataStore)
        case .ble:
            repository = BLEHistoryRepository(dataStore: dataStore, transport: manager)
        }

        _bluetooth = State(initialValue: manager)
        _history = State(initialValue: HistoryStore(
            repository: repository, dataStore: dataStore, modelContext: context))
    }

    /// Wipes persisted history when the DI source (or cache schema generation)
    /// differs from the last launch. Bump the `-v2` suffix on breaking cache changes.
    private static func clearHistoryIfSourceChanged(in context: ModelContext) {
        let key = "historyDataSource"
        let current = "\(String(describing: historyDataSource))-v2"   // v2: per-device scoping
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
