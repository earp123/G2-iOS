//
//  HistoryCSVExport.swift
//  G2-iOS
//
//  CSV export support: the finished-file descriptor plus the system share sheet
//  that presents it. The CSV is fully written by HistoryDataStore.exportCSV
//  *before* the sheet appears — an earlier revision generated it lazily inside a
//  Transferable FileRepresentation, which let share targets (Mail especially)
//  intermittently receive an unready file.
//

import SwiftUI
import UIKit

/// A finished, on-disk CSV export ready to hand to the share sheet.
struct HistoryCSVFile: Identifiable, Sendable {
    let url: URL
    var id: URL { url }
    var filename: String { url.lastPathComponent }

    /// Stable name computed once per export:
    /// SmartAirSystem_<device>_<scope>_<local timestamp>.csv
    static func filename(deviceID: String, scopeLabel: String, date: Date = Date()) -> String {
        let sanitized = deviceID.filter { $0.isLetter || $0.isNumber }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        return "SmartAirSystem_\(sanitized)_\(scopeLabel)_\(formatter.string(from: date)).csv"
    }
}

/// System share sheet (UIActivityViewController) for a finished file. Receives a
/// real URL, so every target — Mail, Files, AirDrop — gets a complete attachment
/// with the proper filename.
struct HistoryShareSheet: UIViewControllerRepresentable {
    let file: HistoryCSVFile

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [file.url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
