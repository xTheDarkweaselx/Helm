//
//  SnapshotStore.swift
//  HelmWidget (STAGED — add to the widget target in Xcode; see README.md)
//
//  Reads the shared HelmSnapshot the app wrote into the App Group container
//  (JSON file first, UserDefaults mirror as a fallback). Pure read side of
//  HelmAppGroup; the app's SnapshotWriter is the write side.
//

import Foundation
import HelmDomain

enum SnapshotStore {
    static func load() -> HelmSnapshot {
        if let url = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: HelmAppGroup.identifier)?
            .appendingPathComponent(HelmAppGroup.snapshotFilename),
           let data = try? Data(contentsOf: url),
           let snapshot = try? JSONDecoder().decode(HelmSnapshot.self, from: data) {
            return snapshot
        }
        if let data = UserDefaults(suiteName: HelmAppGroup.defaultsSuite)?.data(forKey: HelmAppGroup.snapshotDefaultsKey),
           let snapshot = try? JSONDecoder().decode(HelmSnapshot.self, from: data) {
            return snapshot
        }
        return .empty
    }
}
