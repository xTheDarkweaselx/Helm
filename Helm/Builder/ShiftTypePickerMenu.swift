//
//  ShiftTypePickerMenu.swift
//  Helm
//
//  v7: the in-window replacement for the old ShiftTypePickerSheet. A Menu
//  (a native dropdown on macOS, an action menu on iOS — never a modal sheet)
//  whose label is the caller's own row content. Reused by the rotation-cycle
//  editor, the explicit-day editor and the exception editor.
//

import SwiftUI
import SwiftData

struct ShiftTypePickerMenu<LabelContent: View>: View {
    @Query(sort: [SortDescriptor(\ShiftType.sortIndex), SortDescriptor(\ShiftType.code)])
    private var types: [ShiftType]

    var allowOff: Bool = true
    let onPick: (ShiftType?) -> Void
    @ViewBuilder var label: LabelContent

    var body: some View {
        Menu {
            if allowOff {
                Button { onPick(nil) } label: { Label("Off", systemImage: "moon.zzz") }
                Divider()
            }
            if types.isEmpty {
                Text("No shift types yet — add some under Shift Types")
            } else {
                ForEach(types) { type in
                    Button { onPick(type) } label: { Text(menuTitle(type)) }
                }
            }
        } label: {
            label
                .contentShape(Rectangle())
        }
        .menuIndicator(.hidden)
    }

    private func menuTitle(_ type: ShiftType) -> String {
        let name = type.label ?? type.code ?? "Shift"
        if type.workKind == .off { return name }
        return "\(name)  ·  \(hhmmString(type.startMinuteOfDay))–\(hhmmString(type.endMinuteOfDay))"
    }
}
