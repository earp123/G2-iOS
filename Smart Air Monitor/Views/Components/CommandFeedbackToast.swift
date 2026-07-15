//
//  CommandFeedbackToast.swift
//  Smart Air Monitor
//
//  Transient toast for command/settings rejections and write timeouts (§7).
//  Surfaces ATT 0x0E rejections and non-monotonic Settings rejections honestly.
//

import SwiftUI

private struct CommandFeedbackToast: ViewModifier {
    @Environment(BluetoothManager.self) private var bluetooth

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if let feedback = bluetooth.commandFeedback {
                toast(for: feedback)
                    .padding(.horizontal, Theme.spacing)
                    .padding(.bottom, 92)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .task(id: feedback) {
                        try? await Task.sleep(for: .seconds(3.5))
                        if !Task.isCancelled { bluetooth.clearCommandFeedback() }
                    }
            }
        }
        .animation(.spring(duration: 0.3), value: bluetooth.commandFeedback)
    }

    private func toast(for feedback: CommandFeedback) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.aqiPoor)
            Text(message(for: feedback))
                .font(.footnote.weight(.medium))
                .foregroundStyle(Theme.textPrimary)
            Spacer(minLength: 0)
        }
        .padding()
        .background(Theme.surfaceHi, in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.4), radius: 12, y: 4)
    }

    private func message(for feedback: CommandFeedback) -> String {
        switch feedback {
        case .rejected(let text): text
        case .timedOut:           "The device didn’t respond to that write. Please try again."
        }
    }
}

extension View {
    func commandFeedbackToast() -> some View { modifier(CommandFeedbackToast()) }
}
