//
//  Metric.swift
//  Smart Air Monitor
//
//  A typed measurement that is either a valid value or an explicit `.invalid`
//  (sentinel / warming-up). The UI renders `.invalid` as "—", never as a number.
//

import Foundation

/// A sensor measurement of `Value` that may be invalid (sentinel present).
enum Metric<Value: Equatable & Sendable>: Equatable, Sendable {
    case valid(Value)
    case invalid

    var value: Value? {
        if case let .valid(v) = self { return v }
        return nil
    }

    var isValid: Bool { value != nil }
}

extension Metric where Value == Double {
    /// Formats the value with `decimals` fractional digits, or "—" when invalid.
    func formatted(decimals: Int) -> String {
        guard let v = value else { return "—" }
        return String(format: "%.\(decimals)f", v)
    }
}

extension Metric where Value == Int {
    /// Formats the value as an integer string, or "—" when invalid.
    var formatted: String {
        guard let v = value else { return "—" }
        return String(v)
    }
}
