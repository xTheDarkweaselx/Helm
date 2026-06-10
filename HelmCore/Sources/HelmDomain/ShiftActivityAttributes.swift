//
//  ShiftActivityAttributes.swift
//  HelmDomain
//
//  v7 Live Activity: the shared attributes type for the "on shift now" Live
//  Activity. Defined PURE here (Codable/Hashable/Sendable, NO ActivityKit
//  import — HelmDomain stays UI/framework-free and macOS-buildable). Both the
//  app (which starts/updates the Activity) and the staged widget (which renders
//  it) add the ActivityKit conformance retroactively behind
//  `#if canImport(ActivityKit)`:
//
//      extension ShiftActivityAttributes: @retroactive ActivityAttributes {}
//
//  The nested `ContentState` already satisfies ActivityAttributes' requirement.
//

import Foundation

public struct ShiftActivityAttributes: Codable, Hashable, Sendable {
    /// The live-updating part of the activity.
    public struct ContentState: Codable, Hashable, Sendable {
        public let title: String
        public let start: Date
        public let end: Date
        public let location: String?

        public init(title: String, start: Date, end: Date, location: String?) {
            self.title = title
            self.start = start
            self.end = end
            self.location = location
        }
    }

    /// Fixed for the activity's lifetime.
    public let shiftID: String
    public let colorHex: String?

    public init(shiftID: String, colorHex: String?) {
        self.shiftID = shiftID
        self.colorHex = colorHex
    }
}
