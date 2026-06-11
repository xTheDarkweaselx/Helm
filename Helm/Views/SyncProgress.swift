//
//  SyncProgress.swift
//  Helm
//
//  v7.2: visible progress for bulk calendar work. Google writes/removes are
//  rate-limit throttled (2 concurrent, long backoffs), so a 200-event roster
//  can take minutes — without feedback "delete roster" looks ignored. The
//  sync engine chunks its batches and reports here; one floating in-window
//  HUD (never a sheet) renders "Removing shifts… 48 of 212" wherever you are.
//

import SwiftUI

/// The one app-wide progress channel for bulk calendar operations. Reported
/// into by the (MainActor) engines between awaited chunks; observed by the HUD
/// and by views that disable destructive actions while work is in flight.
@Observable
final class SyncProgress {
    static let shared = SyncProgress()

    struct Operation: Equatable {
        var label: String
        var completed: Int
        /// nil → indeterminate (e.g. "remove all" where the count is unknown).
        var total: Int?
    }

    private(set) var current: Operation?
    var isActive: Bool { current != nil }

    func begin(_ label: String, total: Int?) {
        current = Operation(label: label, completed: 0, total: total)
    }

    func advance(_ n: Int = 1) {
        guard var op = current else { return }
        op.completed = min(op.completed + n, op.total ?? .max)
        current = op
    }

    func end() {
        current = nil
    }
}

/// The floating glass progress capsule, overlaid at the bottom of the main
/// window whenever a bulk operation runs. Determinate when the engine knows
/// the batch size; indeterminate otherwise.
struct SyncProgressHUD: View {
    @Environment(SyncProgress.self) private var progress

    var body: some View {
        ZStack {
            if let op = progress.current {
                HStack(spacing: 12) {
                    if op.total == nil {
                        ProgressView()
                            .controlSize(.small)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(op.label)
                                .font(.caption.weight(.medium))
                                .lineLimit(1)
                            if let total = op.total {
                                Spacer(minLength: 8)
                                Text("\(op.completed) of \(total)")
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if let total = op.total, total > 0 {
                            ProgressView(value: Double(min(op.completed, total)), total: Double(total))
                                .progressViewStyle(.linear)
                                .animation(.linear(duration: 0.2), value: op.completed)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(maxWidth: 340)
                .glassCard(cornerRadius: 12)
                .shadow(color: .black.opacity(0.10), radius: 8, y: 2)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .accessibilityElement(children: .combine)
                .accessibilityLabel(accessibilityText(op))
            }
        }
        .animation(.snappy(duration: 0.25), value: progress.current != nil)
        .allowsHitTesting(false) // never block the UI underneath
    }

    private func accessibilityText(_ op: SyncProgress.Operation) -> String {
        if let total = op.total {
            return "\(op.label) \(op.completed) of \(total)"
        }
        return op.label
    }
}

/// Batch slicing for progress reporting (the engines write/remove in chunks so
/// the bar advances between awaits).
extension Array {
    func chunks(of size: Int) -> [[Element]] {
        guard size > 0, !isEmpty else { return isEmpty ? [] : [self] }
        return stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
