//
//  ThresholdsFormTests.swift
//  G2-iOSTests
//
//  The Air quality thresholds editor's input rules (thresholds-v3 §3): integer
//  cells reject decimals, PM cells take one decimal and round to it (wire =
//  value × 10), and Save is allowed only when every firmware rule passes and
//  something changed.
//

import Foundation
import Testing
@testable import G2_iOS

@Suite("ThresholdsForm — editor input rules")
struct ThresholdsFormTests {

    private typealias Field = ThresholdsBlob.Field

    // MARK: - Loading

    @Test("Loading the defaults shows integers plainly and PM with one decimal")
    func loadsDeviceValues() {
        let form = ThresholdsForm(.defaults)
        #expect(form[.gasEdge(.voc, 0)] == "100")
        #expect(form[.gasEdge(.co2, 3)] == "2000")
        #expect(form[.pmAttention(.pm1)] == "7.0")
        #expect(form[.pmHazard(.pm10)] == "150.0")
        #expect(form[.fanGas(1)] == "25")
        #expect(form[.fanPM(0)] == "20")
        #expect(form[.ionizerRunOn] == "60")
        #expect(form[.hysteresisPM] == "0.0")
    }

    @Test("An untouched form drafts back to exactly the device blob")
    func untouchedDraftEqualsDevice() {
        for device in [ThresholdsBlob.defaults, nonDefault] {
            let form = ThresholdsForm(device)
            #expect(form.draft(over: device) == device)
            #expect(!form.isEdited(against: device))
            #expect(!form.canSave(against: device))   // nothing changed
        }
    }

    // MARK: - Sanitising

    @Test("Integer cells keep digits only — a decimal point is rejected", arguments: [
        ("12.5", "125"), ("1,000", "1000"), ("-40", "40"), ("abc", ""), ("0042", "0042"),
    ])
    func integerCellsRejectDecimals(input: String, expected: String) {
        #expect(ThresholdsForm.sanitized(input, for: .gasEdge(.voc, 0)) == expected)
    }

    @Test("Integer cells are capped at the digits their wire field can carry")
    func integerDigitCaps() {
        #expect(ThresholdsForm.sanitized("1234567", for: .gasEdge(.co2, 3)) == "12345")   // u16
        #expect(ThresholdsForm.sanitized("12345", for: .fanGas(0)) == "123")             // u8
    }

    @Test("PM cells take one decimal, either separator, and round to it", arguments: [
        ("7.0", "7.0"), ("7", "7"), ("7.", "7."), ("7,5", "7.5"), (".5", ".5"),
        ("7.25", "7.3"), ("7.24", "7.2"), ("7.249", "7.2"), ("9.95", "10.0"), ("1.2.3", "1.2"),
    ])
    func pmCellsRoundToOneDecimal(input: String, expected: String) {
        #expect(ThresholdsForm.sanitized(input, for: .pmAttention(.pm25)) == expected)
    }

    @Test("PM wire value is the displayed value × 10")
    func pmWireIsTimesTen() {
        var form = ThresholdsForm(.defaults)
        form[.pmAttention(.pm25)] = "12.3"
        #expect(form.value(.pmAttention(.pm25)) == 123)
        form[.pmAttention(.pm25)] = "12"
        #expect(form.value(.pmAttention(.pm25)) == 120)
        form[.pmAttention(.pm25)] = "12."
        #expect(form.value(.pmAttention(.pm25)) == 120)
        form[.pmAttention(.pm25)] = ".5"
        #expect(form.value(.pmAttention(.pm25)) == 5)
        form[.hysteresisPM] = "1.25"   // rounds to 1.3
        #expect(form.value(.hysteresisPM) == 13)
    }

    // MARK: - Cell problems

    @Test("An empty cell is reported and blocks the draft")
    func emptyCell() {
        var form = ThresholdsForm(.defaults)
        form[.gasEdge(.nox, 2)] = ""
        #expect(form.problem(.gasEdge(.nox, 2)) == .empty)
        #expect(form.draft(over: .defaults) == nil)
        #expect(!form.canSave(against: .defaults))
        #expect(form.messages(for: .gasEdges(.nox), against: .defaults) == ["C3: enter a value."])
    }

    @Test("A value the wire field cannot hold is reported as too large")
    func tooLargeCell() {
        var form = ThresholdsForm(.defaults)
        form[.fanGas(0)] = "300"          // > u8
        #expect(form.problem(.fanGas(0)) == .tooLarge)
        form[.gasEdge(.co2, 3)] = "70000" // > u16
        #expect(form.problem(.gasEdge(.co2, 3)) == .tooLarge)
        form[.pmHazard(.pm10)] = "6553.6" // > 6553.5
        #expect(form.problem(.pmHazard(.pm10)) == .tooLarge)
        form[.pmHazard(.pm10)] = "6553.5"
        #expect(form.problem(.pmHazard(.pm10)) == nil)
    }

    // MARK: - Save gating and inline errors

    @Test("A valid change enables Save; reverting it disables Save again")
    func saveFollowsChange() {
        var form = ThresholdsForm(.defaults)
        form[.gasEdge(.voc, 0)] = "90"
        #expect(form.isEdited(against: .defaults))
        #expect(form.canSave(against: .defaults))
        #expect(form.draft(over: .defaults)?.vocEdges == [90, 150, 250, 350])
        form[.gasEdge(.voc, 0)] = "100"
        #expect(!form.canSave(against: .defaults))
    }

    @Test("Every firmware rule failure disables Save and shows under its row")
    func ruleFailuresDisableSave() {
        let cases: [(Field, String, ThresholdsBlob.ValidationError.Row)] = [
            (.gasEdge(.voc, 1), "100", .gasEdges(.voc)),        // not strictly increasing
            (.gasEdge(.nox, 3), "501", .gasEdges(.nox)),        // C4 above 500
            (.gasEdge(.co2, 3), "40001", .gasEdges(.co2)),      // C4 above 40000
            (.pmAttention(.pm1), "25.0", .pmEdges(.pm1)),       // attention not below hazard
            (.fanGas(4), "101", .fanGas),
            (.fanPM(2), "101", .fanPM),
            (.fanDownDelay, "3601", .fanDownDelay),
            (.ionizerRunOn, "1441", .ionizerRunOn),
            (.hysteresis(.voc), "50", .hysteresis(.voc)),       // smallest VOC gap is 50
            (.hysteresis(.nox), "20", .hysteresis(.nox)),       // NOx C1 is 20 (gap 30)
            (.hysteresisPM, "7.0", .hysteresisPM),              // lowest PM attention is 7.0
        ]
        for (field, text, row) in cases {
            var form = ThresholdsForm(.defaults)
            form[field] = text
            #expect(!form.canSave(against: .defaults), "\(field) = \(text)")
            #expect(form.messages(for: row, against: .defaults).count == 1, "\(field) = \(text)")
            // The error sits under its own row only.
            let elsewhere = [ThresholdsBlob.ValidationError.Row.gasEdges(.voc), .fanPM, .ionizerRunOn]
                .filter { $0 != row }
            for other in elsewhere {
                #expect(form.messages(for: other, against: .defaults).isEmpty, "\(field) leaked into \(other)")
            }
        }
    }

    @Test("The acceptance-test edges VOC 5/6/7/8 are saveable")
    func acceptanceEdgesSaveable() {
        var form = ThresholdsForm(.defaults)
        for (i, text) in ["5", "6", "7", "8"].enumerated() { form[.gasEdge(.voc, i)] = text }
        #expect(form.canSave(against: .defaults))
        let draft = form.draft(over: .defaults)
        #expect(draft?.vocEdges == [5, 6, 7, 8])
        #expect(draft?.validate() == nil)
    }

    @Test("A device blob in another format is shown but cannot be saved over")
    func unsupportedVersionBlocksSave() {
        var device = ThresholdsBlob.defaults
        device.version = 2
        var form = ThresholdsForm(device)
        form[.ionizerRunOn] = "30"
        #expect(form.draft(over: device)?.version == 2)   // the device's byte goes back as-is…
        #expect(!form.canSave(against: device))            // …so validate() refuses it
        #expect(form.messages(for: .version, against: device).count == 1)
    }

    // MARK: - Fixtures

    private var nonDefault: ThresholdsBlob {
        var blob = ThresholdsBlob.defaults
        blob.vocEdges = [5, 16, 27, 38]
        blob.pm25Attention = 123
        blob.fanPM = [0, 60, 99]
        blob.hysteresisPM = 71
        return blob
    }
}
