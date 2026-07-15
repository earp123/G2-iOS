//
//  MainTabView.swift
//  Smart Air Monitor
//
//  Connected interface (§3 Phase B): Dashboard · Fan · History · Settings, each in
//  its own NavigationStack with the persistent connection chip. The command-feedback
//  toast is hosted once over the whole tab view.
//

import SwiftUI

struct MainTabView: View {
    @State private var selection = 0

    var body: some View {
        TabView(selection: $selection) {
            DashboardView()
                .connectedTab("Dashboard")
                .tabItem { Label("Dashboard", systemImage: "gauge.with.dots.needle.50percent") }
                .tag(0)

            FanView()
                .connectedTab("Fan")
                .tabItem { Label("Fan", systemImage: "fan.fill") }
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
