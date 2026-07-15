//
//  Theme.swift
//  Smart Air Monitor
//
//  Deliberate, non-templated dark aesthetic (§6): near-black background, restrained
//  accent palette, generous spacing, consistent AQI color semantics. Carries over
//  the prior app's feel (true-dark, cyan accent, rounded bold numerics).
//

import SwiftUI

enum Theme {

    // MARK: - Surfaces (true / near-black)
    static let background = Color(red: 0.04, green: 0.05, blue: 0.06)
    static let surface    = Color.white.opacity(0.05)
    static let surfaceHi  = Color.white.opacity(0.08)
    static let hairline   = Color.white.opacity(0.10)

    // MARK: - Text
    static let textPrimary   = Color.white
    static let textSecondary = Color.white.opacity(0.55)

    // MARK: - Accents (restrained)
    static let accent       = Color.cyan           // brand accent (carried over)
    static let accentCool   = Color(red: 0.30, green: 0.62, blue: 0.95)  // humidity
    static let accentWarm   = Color(red: 0.98, green: 0.62, blue: 0.34)  // temperature
    static let accentViolet = Color(red: 0.66, green: 0.52, blue: 0.96)  // TVOC
    static let accentTeal   = Color(red: 0.25, green: 0.83, blue: 0.74)  // eCO2

    // MARK: - AQI semantics (green → red, used consistently §6)
    static let aqiExcellent = Color(red: 0.30, green: 0.82, blue: 0.55)
    static let aqiGood      = Color(red: 0.55, green: 0.80, blue: 0.35)
    static let aqiModerate  = Color(red: 0.95, green: 0.78, blue: 0.30)
    static let aqiPoor      = Color(red: 0.96, green: 0.55, blue: 0.28)
    static let aqiUnhealthy = Color(red: 0.93, green: 0.36, blue: 0.36)

    // MARK: - Spacing
    static let spacing: CGFloat = 16
    static let corner: CGFloat = 16
}

/// Card container used across the app (§6 — generous spacing, soft surfaces).
struct CardModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(Theme.spacing)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
                    .strokeBorder(Theme.hairline, lineWidth: 1)
            )
    }
}

extension View {
    func card() -> some View { modifier(CardModifier()) }
}
