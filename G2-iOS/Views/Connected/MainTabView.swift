//
//  MainTabView.swift
//  G2-iOS
//
//  Connected interface (§3 Phase B): Dashboard · Conditioning · History · Settings, each in
//  its own NavigationStack with the persistent connection chip. The command-feedback
//  toast is hosted once over the whole tab view. Conditioning combines fan control
//  with ionizer health monitoring, and carries a warning badge while the device
//  is parked in Manual 0 % (§5).
//

import SwiftUI

struct MainTabView: View {
    @Environment(BluetoothManager.self) private var bluetooth
    @State private var selection = Self.initialSelection
    @State private var showNamingSheet = false

    /// Simulator-only: `GEUE_SIM_TAB` (0–3) opens straight onto a tab, so any
    /// screen can be reached without hardware. Sibling of `GEUE_SIM_AUTOCONNECT`
    /// in RootView; compiled out of device builds.
    private static var initialSelection: Int {
        #if targetEnvironment(simulator)
        if let raw = ProcessInfo.processInfo.environment["GEUE_SIM_TAB"],
           let tab = Int(raw), (0...3).contains(tab) {
            return tab
        }
        #endif
        return 0
    }

    var body: some View {
        TabView(selection: $selection) {
            DashboardView()
                .connectedTab("Dashboard")
                .tabItem { Label("Dashboard", systemImage: "gauge.with.dots.needle.50percent") }
                .tag(0)

            ConditioningView()
                .connectedTab("Conditioning")
                .tabItem { Label("Conditioning", systemImage: "air.purifier.fill") }
                // Manual 0 % keeps the fan off across the next start (§5).
                .badge(bluetooth.showsManualOffWarning ? Text("!") : nil)
                .tag(1)

            HistoryView()
                .connectedTab("History")
                .tabItem { Label("History", systemImage: "chart.xyaxis.line") }
                .tag(2)

            SettingsView()
                .connectedTab("Settings")
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
                .tag(3)
        }
        .tint(Theme.accent)
        .commandFeedbackToast()
        // One-time naming prompt for a unit still on its factory default name.
        // Hosted here rather than in the Settings tab so it fires on connect
        // regardless of which tab is showing (§6).
        .sheet(isPresented: $showNamingSheet) {
            DeviceNamingSheet()
        }
        // Both an initial check and change observers: the name is usually already
        // read by the time this view first appears (so no `onChange` ever fires),
        // but on a slower link it can land afterwards.
        .task { offerNamingIfDefault() }
        .onChange(of: bluetooth.deviceName) { _, _ in offerNamingIfDefault() }
        .onChange(of: bluetooth.phase) { _, _ in offerNamingIfDefault() }
    }

    /// Shows the naming sheet once per peripheral, and only while the device is
    /// still reporting a factory default name (§6).
    private func offerNamingIfDefault() {
        guard !showNamingSheet,
              bluetooth.phase == .connected,
              let name = bluetooth.deviceName,
              GATT.factoryDefaultDeviceNames.contains(name),
              let id = bluetooth.connectedDevice?.id,
              !DeviceNamingPrompt.hasPrompted(id) else { return }
        DeviceNamingPrompt.markPrompted(id)
        showNamingSheet = true
    }
}

extension View {
    /// Wraps a tab's content in a NavigationStack with the inline title, dark nav
    /// bar, and the persistent connection chip (§3).
    func connectedTab(_ title: String) -> some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                self
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { ConnectionChip() }
            }
        }
    }
}
