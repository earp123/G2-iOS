//
//  HistoryCSVExport.swift
//  G2-iOS
//
//  Transferable descriptor for CSV export via the system share sheet.
//

import Foundation
import CoreTransferable
import UniformTypeIdentifiers

nonisolated struct HistoryCSVExport: Transferable, Sendable {
    let dataStore: HistoryDataStore
    let deviceID: String
    let cutoff: Date?
    let scopeLabel: String

    var filename: String {
        let sanitized = deviceID.filter { $0.isLetter || $0.isNumber }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmm"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        let timestamp = formatter.string(from: Date())
        return "SmartAirSystem_\(sanitized)_\(scopeLabel)_\(timestamp).csv"
    }

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .commaSeparatedText) { export in
            let url = try await export.dataStore.exportCSV(
                deviceID: export.deviceID,
                cutoff: export.cutoff,
                filename: export.filename
            )
            return SentTransferredFile(url)
        }
    }
}
