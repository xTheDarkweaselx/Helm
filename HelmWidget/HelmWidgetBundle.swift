//
//  HelmWidgetBundle.swift
//  HelmWidget (STAGED — add to the widget target in Xcode; see README.md)
//
//  The widget extension's entry point. Replace Xcode's auto-generated bundle
//  file with this one (Target Membership: HelmWidget only).
//

import WidgetKit
import SwiftUI

@main
struct HelmWidgetBundle: WidgetBundle {
    var body: some Widget {
        NextShiftWidget()
        #if os(iOS)
        ShiftLiveActivity()
        #endif
    }
}
