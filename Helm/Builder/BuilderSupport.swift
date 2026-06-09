//
//  BuilderSupport.swift
//  Helm
//
//  Small shared helpers + components for the rota builder UI.
//

import SwiftUI
import SwiftData
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Ensure a pattern's slots are exactly `cycleLengthDays`, contiguously indexed
/// 0..<n (defensive against CloudKit-merge gaps/dupes). Used at creation (eager)
/// and on length change.
@MainActor
func syncRotationSlots(_ pattern: RotationPattern, context: ModelContext) {
    var slots = (pattern.slots ?? []).sorted { $0.sortIndex < $1.sortIndex }
    for (i, slot) in slots.enumerated() where slot.sortIndex != i { slot.sortIndex = i }
    while slots.count < pattern.cycleLengthDays {
        let slot = RotationSlot(sortIndex: slots.count, isOff: true)
        slot.pattern = pattern
        context.insert(slot)
        slots.append(slot)
    }
    if slots.count > pattern.cycleLengthDays {
        for slot in slots[pattern.cycleLengthDays...] { context.delete(slot) }
    }
    try? context.save()
}

/// "HH:MM" from a minute-of-day (handles values ≥ 1440 / negative defensively).
func hhmmString(_ minute: Int) -> String {
    let m = ((minute % 1440) + 1440) % 1440
    return String(format: "%02d:%02d", m / 60, m % 60)
}

/// Bridge a minute-of-day `Int` binding to a `Date` for `DatePicker(.hourAndMinute)`.
func timeOfDayBinding(_ minutes: Binding<Int>) -> Binding<Date> {
    Binding(
        get: {
            var c = DateComponents()
            c.hour = (minutes.wrappedValue / 60) % 24
            c.minute = minutes.wrappedValue % 60
            return Calendar.current.date(from: c) ?? Date()
        },
        set: { newDate in
            let c = Calendar.current.dateComponents([.hour, .minute], from: newDate)
            minutes.wrappedValue = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        }
    )
}

/// Bridge an optional `Date` binding to a non-optional one for `DatePicker`.
func dateBinding(_ binding: Binding<Date?>, default fallback: Date) -> Binding<Date> {
    Binding(get: { binding.wrappedValue ?? fallback }, set: { binding.wrappedValue = $0 })
}

extension Color {
    /// Init from a hex string ("RRGGBB" or "AARRGGBB", optional leading #). Nil if malformed.
    init?(hex: String?) {
        guard var hex else { return nil }
        hex = hex.trimmingCharacters(in: .whitespaces)
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard let value = UInt64(hex, radix: 16) else { return nil }
        let r, g, b, a: Double
        switch hex.count {
        case 6:
            r = Double((value >> 16) & 0xFF) / 255
            g = Double((value >> 8) & 0xFF) / 255
            b = Double(value & 0xFF) / 255
            a = 1
        case 8:
            a = Double((value >> 24) & 0xFF) / 255
            r = Double((value >> 16) & 0xFF) / 255
            g = Double((value >> 8) & 0xFF) / 255
            b = Double(value & 0xFF) / 255
        default:
            return nil
        }
        self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
    }

    var hexString: String {
        #if canImport(UIKit)
        let ui = UIColor(self)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255))
        #elseif canImport(AppKit)
        let base = NSColor(self)
        guard let c = base.usingColorSpace(.sRGB) ?? base.usingColorSpace(.deviceRGB) else { return "808080" }
        return String(format: "%02X%02X%02X", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
        #else
        return "808080"
        #endif
    }
}

/// A small colored chip for a shift type / slot.
struct ShiftTypeChip: View {
    let label: String
    var colorHex: String?
    var systemImage: String?

    var body: some View {
        Label {
            Text(label)
        } icon: {
            if let systemImage { Image(systemName: systemImage) }
        }
        .labelStyle(.titleAndIcon)
        .font(.caption.weight(.medium))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background((Color(hex: colorHex) ?? .accentColor).opacity(0.22), in: Capsule())
    }
}
