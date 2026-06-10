//
//  ShiftLiveActivity.swift
//  HelmWidget (STAGED — add to the widget target in Xcode; see README.md)
//
//  The "on shift now" Live Activity: lock-screen banner + Dynamic Island. The
//  attributes type is shared (HelmDomain.ShiftActivityAttributes); the
//  ActivityKit conformance is added retroactively (the app target adds its own).
//

#if os(iOS)
import ActivityKit
import WidgetKit
import SwiftUI
import HelmDomain

extension ShiftActivityAttributes: @retroactive ActivityAttributes {}

struct ShiftLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ShiftActivityAttributes.self) { context in
            // Lock screen / banner.
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color(helmHex: context.attributes.colorHex) ?? .accentColor)
                    .frame(width: 5)
                VStack(alignment: .leading, spacing: 2) {
                    Text("On shift").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                    Text(context.state.title).font(.headline).lineLimit(1)
                    if let location = context.state.location, !location.isEmpty {
                        Text(location).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                VStack(alignment: .trailing) {
                    Text("ends").font(.caption2).foregroundStyle(.secondary)
                    Text(context.state.end, style: .timer)
                        .font(.title3.weight(.semibold).monospacedDigit())
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 80)
                }
            }
            .padding()
            .activityBackgroundTint(Color.black.opacity(0.4))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(context.state.title, systemImage: "briefcase.fill").lineLimit(1)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.state.end, style: .timer)
                        .monospacedDigit()
                        .frame(maxWidth: 64)
                        .multilineTextAlignment(.trailing)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if let location = context.state.location, !location.isEmpty {
                        Label(location, systemImage: "mappin.and.ellipse").font(.caption)
                    }
                }
            } compactLeading: {
                Image(systemName: "briefcase.fill")
            } compactTrailing: {
                Text(context.state.end, style: .timer).monospacedDigit().frame(maxWidth: 44)
            } minimal: {
                Image(systemName: "briefcase.fill")
            }
        }
    }
}
#endif
