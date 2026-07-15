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

    /// Repository DI switch (§4.1). Default `.mock` so the history UI is fully
    /// populated in development. `.ble` exercises the (stubbed) firmware path.
    private static let historyDataSource: HistoryDataSource = .mock

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
