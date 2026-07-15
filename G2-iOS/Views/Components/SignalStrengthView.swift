//
//  SignalStrengthView.swift
//  G2-iOS
//
//  RSSI signal-strength glyph used in the scan list and diagnostics (§3/§5).
//

import SwiftUI

struct SignalStrengthView: View {
    let rssi: Int

    private var bars: Int {
        switch rssi {
        case ..<(-90): 0
        case ..<(-75): 1
        case ..<(-60): 2
        default:       3
        }
    }

    private var tint: Color {
        switch bars {
        case 0: Theme.aqiUnhealthy
        case 1: Theme.aqiPoor
        case 2: Theme.aqiModerate
        default: Theme.aqiExcellent
        }
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<4, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(i <= bars ? tint : Theme.hairline)
                    .frame(width: 3, height: 5 + CGFloat(i) * 4)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Signal strength")
        .accessibilityValue("\(rssi) dBm, \(bars + 1) of 4 bars")
    }
}
