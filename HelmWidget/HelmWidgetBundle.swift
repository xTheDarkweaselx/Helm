//
//  HelmWidgetBundle.swift
//  HelmWidget
//
//  @main entry point for the widget extension. Registers the Home/lock-screen
//  widget and (on iOS) the on-shift Live Activity.
//

import WidgetKit
import SwiftUI

@main
struct HelmWidgetBundle: WidgetBundle {
    var body: some Widget {
        NextShiftWidget()
        WeekOverviewWidget()
        HoursGaugeWidget()
        #if os(iOS)
        ShiftLiveActivity()
        #endif
    }
}
