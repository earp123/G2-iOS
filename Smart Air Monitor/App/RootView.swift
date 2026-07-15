//
//  RootView.swift
//  Smart Air Monitor
//
//  Two top-level phases gated on connection state (§3): pre-connection ScanView
//  and the connected TabView interface.
//

import SwiftUI

struct RootView: View {
    @Environment(BluetoothManager.self) private var bluetooth

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            switch bluetooth.phase {
            case .connected:
                MainTabView()
                    .transition(.opacity)
            case .disconnected, .connecting, .discovering:
                ScanView()
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: bluetooth.phase)
        .task {
            #if targetEnvironment(simulator)
            if ProcessInfo.processInfo.environment["GEUE_SIM_AUTOCONNECT"] == "1",
               bluetooth.phase == .disconnected {
                bluetooth.debugAutoConnect()
            }
            #endif
        }
    }
}
