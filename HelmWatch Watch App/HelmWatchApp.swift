//
//  HelmWatchApp.swift
//  HelmWatch (STAGED — add to the watch APP target in Xcode; see README.md)
//
//  Entry point for the Helm watch companion. The watch is read-only in v7.5:
//  it shows the snapshot the iPhone pushes (next shift / today / week) — all
//  editing stays on iPhone/Mac.
//

import SwiftUI

@main
struct HelmWatchApp: App {
    @State private var link = PhoneLink.shared

    var body: some Scene {
        WindowGroup {
            WatchRootView()
                .environment(link)
                .task { link.activate() }
        }
    }
}
