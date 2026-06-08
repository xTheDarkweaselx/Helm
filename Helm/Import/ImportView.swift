//
//  ImportView.swift
//  Helm
//
//  v0 import flow: pick a CSV → preview resolved shifts → persist (SwiftData) →
//  write to the Helm calendar via EventKit. The full auto-detecting wizard,
//  diff-on-reimport, and .xlsx support arrive in v1.
//

import SwiftUI
import SwiftData
import UniformTypeIdentifiers

@MainActor
@Observable
final class ImportCoordinator {
    enum Phase: Equatable {
        case idle
        case loaded
        case writing
        case finished(added: Int, updated: Int, skipped: Int)
        case failed(String)
    }

    var phase: Phase = .idle
    var result: RosterImportResult?

    func load(from url: URL) {
        do {
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: url)
            let text = String(decoding: data, as: UTF8.self)
            let name = url.deletingPathExtension().lastPathComponent
            result = try RosterImporter.importCSV(text: text, sourceName: name)
            phase = .loaded
        } catch {
            phase = .failed(message(for: error))
        }
    }

    func commit(modelContext: ModelContext) async {
        guard let result else { return }
        phase = .writing

        let writable = result.drafts.filter(\.isWritable)
        let nonWritable = result.drafts.count - writable.count

        let roster = Roster(title: result.sourceName)
        modelContext.insert(roster)

        var typeCache: [String: ShiftType] = [:]
        var instances: [ShiftInstance] = []
        for (index, draft) in writable.enumerated() {
            let type = shiftType(for: draft, cache: &typeCache, context: modelContext)
            let instance = ShiftInstance(
                localDate: draft.localDate,
                timeZoneIdentifier: draft.timeZoneIdentifier,
                title: draft.title ?? type.label,
                locationName: draft.location,
                shiftType: type,
                roster: roster,
                dedupKey: draft.dedupKey
            )
            instance.startUTC = draft.start
            instance.endUTC = draft.end
            instance.computedPaidHours = draft.paidHours
            instance.sortIndex = index
            modelContext.insert(instance)
            instances.append(instance)
        }

        do {
            try modelContext.save()
        } catch {
            phase = .failed("Couldn't save the roster: \(error.localizedDescription)")
            return
        }

        let writer = ShiftCalendarWriter()
        guard await writer.requestAccess() else {
            phase = .failed("Calendar access was denied. Enable it for Helm in Settings, then try again. Your shifts are saved in Helm.")
            return
        }
        do {
            let summary = try writer.upsert(instances)
            phase = .finished(added: summary.added, updated: summary.updated, skipped: summary.skipped + nonWritable)
        } catch {
            phase = .failed(message(for: error))
        }
    }

    private func shiftType(for draft: DraftShift, cache: inout [String: ShiftType], context: ModelContext) -> ShiftType {
        let key = draft.code.isEmpty
            ? "inline:\(draft.startMinuteOfDay ?? 0)-\(draft.endMinuteOfDay ?? 0)"
            : draft.code
        if let cached = cache[key] { return cached }

        let label = draft.label
            ?? draft.startMinuteOfDay.map { Self.hhmm($0) + (draft.endMinuteOfDay.map { "–" + Self.hhmm($0) } ?? "") }
            ?? (draft.code.isEmpty ? "Shift" : draft.code)

        let type = ShiftType(
            code: draft.code.isEmpty ? nil : draft.code,
            label: label,
            startMinuteOfDay: draft.startMinuteOfDay ?? 0,
            endMinuteOfDay: draft.endMinuteOfDay ?? 0,
            workKind: .worked
        )
        context.insert(type)
        cache[key] = type
        return type
    }

    private func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    static func hhmm(_ minute: Int) -> String {
        let m = ((minute % 1440) + 1440) % 1440
        return String(format: "%02d:%02d", m / 60, m % 60)
    }
}

struct ImportView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var coordinator = ImportCoordinator()
    @State private var isFileImporterPresented = false

    private static let csvTypes: [UTType] = [.commaSeparatedText, .tabSeparatedText, .plainText, .text]

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Import roster")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") { dismiss() }
                    }
                }
                .fileImporter(
                    isPresented: $isFileImporterPresented,
                    allowedContentTypes: Self.csvTypes,
                    allowsMultipleSelection: false
                ) { result in
                    if case let .success(urls) = result, let url = urls.first {
                        coordinator.load(from: url)
                    } else if case let .failure(error) = result {
                        coordinator.phase = .failed(error.localizedDescription)
                    }
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch coordinator.phase {
        case .idle:
            idleView
        case .loaded:
            if let result = coordinator.result { previewView(result) }
        case .writing:
            ProgressView("Adding shifts to your calendar…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case let .finished(added, updated, skipped):
            finishedView(added: added, updated: updated, skipped: skipped)
        case let .failed(message):
            failureView(message)
        }
    }

    private var idleView: some View {
        ContentUnavailableView {
            Label("Choose a roster file", systemImage: "tablecells")
        } description: {
            Text("Pick a CSV exported from your shift spreadsheet. Helm will find the dates and shift codes automatically. (Excel .xlsx support is coming next.)")
        } actions: {
            Button("Choose CSV…", systemImage: "folder") { isFileImporterPresented = true }
                .buttonStyle(.borderedProminent)
        }
    }

    private func previewView(_ result: RosterImportResult) -> some View {
        List {
            Section {
                LabeledContent("Source", value: result.sourceName)
                LabeledContent("Shifts to add", value: "\(result.writableCount)")
                LabeledContent("Skipped (off / TBC / unmapped)", value: "\(result.drafts.count - result.writableCount)")
                if !result.unmappedCodes.isEmpty {
                    LabeledContent("Unknown codes", value: result.unmappedCodes.joined(separator: ", "))
                        .foregroundStyle(.orange)
                }
            }

            Section("Preview") {
                ForEach(result.drafts) { draft in
                    DraftRow(draft: draft)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            Button {
                Task { await coordinator.commit(modelContext: modelContext) }
            } label: {
                Text("Add \(result.writableCount) shifts to Calendar")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(result.writableCount == 0)
            .padding()
        }
    }

    private func finishedView(added: Int, updated: Int, skipped: Int) -> some View {
        ContentUnavailableView {
            Label("Shifts added", systemImage: "checkmark.circle.fill")
        } description: {
            Text("Added \(added), updated \(updated), skipped \(skipped). Open Calendar to see your “Helm Shifts”.")
        } actions: {
            Button("Done") { dismiss() }.buttonStyle(.borderedProminent)
        }
    }

    private func failureView(_ message: String) -> some View {
        ContentUnavailableView {
            Label("Import problem", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button("Try another file") {
                coordinator.result = nil
                coordinator.phase = .idle
                isFileImporterPresented = true
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

private struct DraftRow: View {
    let draft: DraftShift

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(draft.title ?? draft.label ?? draft.code)
                    .font(.subheadline.weight(.medium))
                Text(draft.localDate, format: .dateTime.weekday().day().month())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(trailing)
                .font(.caption)
                .foregroundStyle(color)
        }
    }

    private var trailing: String {
        switch draft.outcome {
        case .willWrite:
            if let s = draft.startMinuteOfDay, let e = draft.endMinuteOfDay {
                return "\(ImportCoordinator.hhmm(s))–\(ImportCoordinator.hhmm(e))"
            }
            return "✓"
        case .skippedOff: return "Off"
        case .skippedTentative: return "TBC"
        case .skippedUnmapped: return "Unknown: \(draft.code)"
        }
    }

    private var color: Color {
        switch draft.outcome {
        case .willWrite: .secondary
        case .skippedOff: .secondary
        case .skippedTentative: .orange
        case .skippedUnmapped: .red
        }
    }
}
