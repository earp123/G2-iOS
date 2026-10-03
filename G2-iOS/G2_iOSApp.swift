//
//  G2_iOSApp.swift
//  G2-iOS — Smart Air System (G2) client
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
        // Contract v2 replaced the log record outright — TVOC ppb and eCO2 became
        // a VOC index and measured CO2, and PM4/NOx/aq_class joined (§1.2). The app
        // is pre-1.0 with no production data, so the store is re-pointed at a new
        // file and the old one deleted, rather than carrying a versioned migration
        // for records whose semantics changed (§3 / §9.4).
        Self.deleteLegacyStoreIfPresent()

        let container: ModelContainer
        do {
            container = try ModelContainer(
                for: HistoryRecord.self,
                configurations: ModelConfiguration(url: Self.storeURL)
            )
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

    /// Store file for log record v2 (§3). Sits beside the default SwiftData
    /// location; naming it explicitly is what makes the old store dead weight
    /// rather than something SwiftData would try to migrate.
    private static let storeURL: URL = {
        let base = URL.applicationSupportDirectory
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appending(path: "history-v2.store")
    }()

    /// Removes the pre-v2 SwiftData store (and its SQLite sidecars) once. Runs on
    /// every launch but is a no-op after the first — the files are gone (§3).
    private static func deleteLegacyStoreIfPresent() {
        let fm = FileManager.default
        let base = URL.applicationSupportDirectory
        // SwiftData's default store, plus the WAL/SHM sidecars SQLite leaves next
        // to it. Removing the .store alone would strand uncheckpointed pages.
        for name in ["default.store", "default.store-shm", "default.store-wal"] {
            let url = base.appending(path: name)
            if fm.fileExists(atPath: url.path) { try? fm.removeItem(at: url) }
        }
    }

    /// Wipes persisted history when the DI source (or cache schema generation)
    /// differs from the last launch. Bump the suffix on breaking cache changes.
    private static func clearHistoryIfSourceChanged(in context: ModelContext) {
        let key = "historyDataSource"
        let current = "\(String(describing: historyDataSource))-v3"   // v3: SEN66 log record v2
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
