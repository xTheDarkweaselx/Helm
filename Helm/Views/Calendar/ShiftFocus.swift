//
//  ShiftFocus.swift
//  Helm
//
//  v9 Shift Focus: narrow the calendar to a single shift type or tag (e.g. "just
//  show my Nights"). Persisted as a small string in @AppStorage; the match runs
//  inside ShiftBucketer so the month grid and day agenda filter from one place.
//

import Foundation

enum ShiftFocus: Equatable {
    case all
    case type(id: String)
    case tag(String)

    /// Stable @AppStorage encoding ("" = all).
    var rawValue: String {
        switch self {
        case .all: ""
        case .type(let id): "type:\(id)"
        case .tag(let name): "tag:\(name)"
        }
    }

    init(rawValue: String) {
        if rawValue.hasPrefix("type:") { self = .type(id: String(rawValue.dropFirst(5))) }
        else if rawValue.hasPrefix("tag:") { self = .tag(String(rawValue.dropFirst(4))) }
        else { self = .all }
    }

    var isActive: Bool { self != .all }

    /// Whether a shift instance is in focus (always true when `.all`).
    func matches(_ instance: ShiftInstance) -> Bool {
        switch self {
        case .all:
            return true
        case .type(let id):
            return instance.shiftType?.id == id
        case .tag(let name):
            return instance.shiftType?.tags.contains { $0.caseInsensitiveCompare(name) == .orderedSame } ?? false
        }
    }
}
