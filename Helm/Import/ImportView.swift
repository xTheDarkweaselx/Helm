//
//  ImportView.swift
//  Helm
//
//  Import flow: pick an .xlsx/CSV → preview the add/update/remove diff vs any
//  existing roster → persist (SwiftData) → sync the Helm calendar via EventKit.
//

import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import HelmDomain

@MainActor
@Observable
final class ImportCoordinator {
    enum Phase: Equatable {
        case idle
        case reading
        case loaded
        case writing
        case finished(SyncSummary)
        case failed(String)
    }

    var phase: Phase = .idle
    var result: RosterImportResult?
    var plan: RosterSyncEngine.Plan?

    func load(from url: URL) async {
        do {
            let data: Data
            do {
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                data = try Data(contentsOf: url) // small read, kept inside the scope
            }
            let name = url.deletingPathExtension().lastPathComponent
            phase = .reading
            // Parse off the main actor (ADR-9): heavy decode must not block the UI.
            result = try await Task.detached(priority: .userInitiated) {
                // Sniff the bytes, not the extension: PK = ZIP/OOXML (.xlsx);
                // D0CF11E0 = OLE2 (legacy .xls); otherwise treat as text/CSV.
                if data.starts(with: [0x50, 0x4B]) {
                    return try RosterImporter.importXLSX(data: data, sourceName: name)
                } else if data.starts(with: [0xD0, 0xCF, 0x11, 0xE0]) {
                    throw RosterImportError.legacyXLS
                } else {
                    // UTF-8 first, then cp1252/Latin-1 so legacy rosters don't become
                    // mojibake; strip a leading Excel UTF-8 BOM.
                    let text = (String(data: data, encoding: .utf8)
                                ?? String(data: data, encoding: .windowsCP1252)
                                ?? String(data: data, encoding: .isoLatin1)
                                ?? String(decoding: data, as: UTF8.self))
                        .replacingOccurrences(of: "\u{FEFF}", with: "")
                    return try RosterImporter.importCSV(text: text, sourceName: name)
                }
            }.value
            phase = .loaded
        } catch {
            phase = .failed(message(for: error))
        }
    }

    /// Compute the add/update/remove diff against any existing roster for this
    /// source, for the preview (read-only).
    func preparePlan(modelContext: ModelContext) {
        guard let result, plan == nil else { return }
        plan = RosterSyncEngine.plan(for: result, in: modelContext)
    }

    func commit(modelContext: ModelContext) async {
        guard let result else { return }
        let plan = self.plan ?? RosterSyncEngine.plan(for: result, in: modelContext)
        phase = .writing

        do {
            let target = try await CalendarTargetProvider.authorizedTarget()
            let summary = try await RosterSyncEngine.apply(plan, target: target, in: modelContext)
            phase = .finished(summary)
        } catch CalendarAccessError.eventKitDenied {
            phase = .failed("Calendar access was denied. Enable it for Helm in Settings, then try again. Your shifts are saved in Helm.")
        } catch {
            phase = .failed(message(for: error))
        }
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
    @State private var previewStyle: PreviewStyle = .calendar

    enum PreviewStyle: Hashable {
        case calendar, list
    }

    // Explicit OOXML + legacy-xls + text UTIs only — NOT the broad `.spreadsheet`
    // (which would also offer .numbers/.ods that dead-end on the xlsx parser).
    private static let importTypes: [UTType] = [
        .commaSeparatedText, .tabSeparatedText, .plainText, .text,
        UTType("org.openxmlformats.spreadsheetml.sheet") ?? .data, // .xlsx
        UTType("com.microsoft.excel.xls") ?? .data,                // legacy .xls → friendly error
    ]

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
                    allowedContentTypes: Self.importTypes,
                    allowsMultipleSelection: false
                ) { result in
                    if case let .success(urls) = result, let url = urls.first {
                        Task {
                            await coordinator.load(from: url)
                            coordinator.preparePlan(modelContext: modelContext)
                        }
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
        case .reading:
            ProgressView("Reading roster…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded:
            if let result = coordinator.result { previewView(result) }
        case .writing:
            ProgressView("Adding shifts to your calendar…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case let .finished(summary):
            finishedView(summary: summary)
        case let .failed(message):
            failureView(message)
        }
    }

    private var idleView: some View {
        ContentUnavailableView {
            Label("Choose a roster file", systemImage: "tablecells")
        } description: {
            Text("Pick an Excel (.xlsx) or CSV file of your roster. Helm finds the dates and shift codes automatically.")
        } actions: {
            Button("Choose file…", systemImage: "folder") { isFileImporterPresented = true }
                .buttonStyle(.borderedProminent)
        }
    }

    private func previewView(_ result: RosterImportResult) -> some View {
        let diff = coordinator.plan?.diff
        let isReimport = coordinator.plan?.isReimport ?? false
        let hasChanges = diff?.hasChanges ?? (result.writableCount > 0)
        return VStack(spacing: 0) {
            Picker("View", selection: $previewStyle) {
                Label("Calendar", systemImage: "calendar").tag(PreviewStyle.calendar)
                Label("List", systemImage: "list.bullet").tag(PreviewStyle.list)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal)
            .padding(.vertical, 8)

            switch previewStyle {
            case .calendar:
                // The headline feature: the pending diff rendered against the
                // user's real calendar (other events included).
                if let plan = coordinator.plan {
                    CalendarView(mode: .preview(PlanOverlayBuilder.build(from: plan, in: modelContext)))
                } else {
                    ProgressView()
                }
            case .list:
                listPreview(result, diff: diff, isReimport: isReimport)
            }
        }
        .safeAreaInset(edge: .bottom) {
            Button {
                Task { await coordinator.commit(modelContext: modelContext) }
            } label: {
                Text(commitTitle(diff: diff, isReimport: isReimport, result: result))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!hasChanges)
            .padding()
        }
    }

    private func listPreview(_ result: RosterImportResult, diff: RosterDiff?, isReimport: Bool) -> some View {
        List {
            Section {
                LabeledContent("Source", value: result.sourceName)
                if isReimport, let diff {
                    Label("Re-import — updating in place", systemImage: "arrow.triangle.2.circlepath")
                        .foregroundStyle(.secondary)
                    LabeledContent("Add", value: "\(diff.added.count)")
                    LabeledContent("Update", value: "\(diff.updated.count)")
                    LabeledContent("Remove", value: "\(diff.removed.count)")
                    LabeledContent("Unchanged", value: "\(diff.unchanged.count)")
                } else {
                    LabeledContent("Shifts to add", value: "\(diff?.added.count ?? result.writableCount)")
                }
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
    }

    private func commitTitle(diff: RosterDiff?, isReimport: Bool, result: RosterImportResult) -> String {
        guard let diff else { return "Add \(result.writableCount) shifts to Calendar" }
        if !diff.hasChanges { return "No changes" }
        if isReimport {
            var parts: [String] = []
            if diff.added.count > 0 { parts.append("+\(diff.added.count)") }
            if diff.updated.count > 0 { parts.append("✎\(diff.updated.count)") }
            if diff.removed.count > 0 { parts.append("−\(diff.removed.count)") }
            return "Apply changes (\(parts.joined(separator: " ")))"
        }
        return "Add \(diff.added.count) shifts to Calendar"
    }

    private func finishedView(summary: SyncSummary) -> some View {
        ContentUnavailableView {
            Label(summary.isReimport ? "Roster updated" : "Shifts added", systemImage: "checkmark.circle.fill")
        } description: {
            Text(summary.userDescription)
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
