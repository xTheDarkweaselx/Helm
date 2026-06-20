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
import HelmParsing

@MainActor
@Observable
final class ImportCoordinator {
    enum Phase: Equatable {
        case idle
        case reading
        case loaded
        /// Auto-detection couldn't find the columns — offer manual mapping over
        /// the retained grid instead of dead-ending (DEVELOPMENT_PLAN.md §4).
        case needsMapping
        case writing
        case finished(SyncSummary)
        case failed(String)
    }

    var phase: Phase = .idle
    var result: RosterImportResult?
    var plan: RosterSyncEngine.Plan?
    /// The raw decoded grid, retained so the user can manually map columns
    /// (when auto-detect fails, or via "Columns wrong?").
    var grid: SpreadsheetGrid?
    /// v9 Auto-Learn: how many unknown codes were just resolved from the file's
    /// own legend/key (for the preview banner).
    var sniffedCount = 0
    /// The file's stem — the re-import fingerprint + legend key for re-resolution.
    private(set) var sourceName: String = ""

    func load(from url: URL, modelContext: ModelContext) async {
        // A fresh file invalidates any previous plan/grid — a failed commit
        // followed by "Try another file" must never apply the stale one.
        plan = nil
        grid = nil
        do {
            let data: Data
            do {
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                data = try Data(contentsOf: url) // small read, kept inside the scope
            }
            let name = url.deletingPathExtension().lastPathComponent
            sourceName = name
            phase = .reading
            // Snapshot the merged legend ON MainActor before the detached parse
            // (SwiftData never crosses isolation; the legend is a value).
            let legend = LegendBuilder.legend(forSourceName: name, in: modelContext)
            // Off the main actor (ADR-9): decode the grid AND attempt auto-detection.
            // The grid is retained either way so a detection miss falls back to
            // manual mapping rather than a hard failure.
            let (loadedGrid, auto): (SpreadsheetGrid, RosterImportResult?) = try await Task.detached(priority: .userInitiated) {
                let g = try RosterImporter.grid(data: data, sourceName: name)
                let r = try? RosterImporter.resolve(grid: g, sourceName: name, legend: legend,
                                                    timeZoneIdentifier: TimeZone.current.identifier, dateOrder: .dayFirst)
                return (g, r)
            }.value
            grid = loadedGrid
            if let auto {
                result = auto
                applyLegendSniff(modelContext: modelContext)
                phase = .loaded
            } else {
                phase = .needsMapping
            }
        } catch {
            phase = .failed(message(for: error))
        }
    }

    /// v9 Auto-Learn Codes: fill any still-unknown codes from the file's OWN
    /// legend/key (a sniffed code+times block), so the user doesn't teach codes
    /// the file already defines. Conservative — only unmapped codes are filled,
    /// so a stray match can never override a real mapping; nothing is persisted
    /// (the file's key is re-read every import).
    func applyLegendSniff(modelContext: ModelContext) {
        sniffedCount = 0
        guard let grid, let current = result, !current.unmappedCodes.isEmpty else { return }
        let unknown = Set(current.unmappedCodes)
        let sniffed = LegendSniffer.sniff(grid: grid).filter { unknown.contains($0.code) }
        guard !sniffed.isEmpty else { return }
        let legend = LegendBuilder.legend(forSourceName: sourceName, in: modelContext,
                                          sniffed: LegendBuilder.learned(fromSniffed: sniffed))
        let before = current.unmappedCodes.count
        result = RosterImporter.reresolve(current, legend: legend)
        sniffedCount = max(0, before - (result?.unmappedCodes.count ?? before))
        plan = nil
    }

    /// v9 Smart Import: route Foundation-Models-extracted CSV through the SAME
    /// pipeline as a file, landing on the preview (with the teach-Helm panel for
    /// any unknown codes, exactly like a file import).
    func loadFromText(_ csv: String, sourceName: String, modelContext: ModelContext) {
        plan = nil
        grid = nil
        self.sourceName = sourceName
        let legend = LegendBuilder.legend(forSourceName: sourceName, in: modelContext)
        do {
            result = try RosterImporter.importCSV(text: csv, sourceName: sourceName, legend: legend)
            preparePlan(modelContext: modelContext)
            phase = .loaded
        } catch {
            phase = .failed(message(for: error))
        }
    }

    /// Open the manual column mapper over the already-loaded grid.
    func enterManualMapping() {
        guard let grid, !grid.sheets.isEmpty else { return }
        phase = .needsMapping
    }

    /// Leave the mapper without applying: back to the preview if we already had a
    /// resolved result, otherwise to the detection-failure path.
    func cancelManualMapping() {
        phase = result != nil
            ? .loaded
            : .failed(RosterImportError.noColumnsDetected.errorDescription ?? "Couldn’t detect the columns.")
    }

    /// Resolve with the user's chosen sheet/columns/date-order and show the preview.
    func applyManualMapping(sheetIndex: Int, mapping: ListColumnMapping,
                            dateOrder: RosterDateParser.Order, modelContext: ModelContext) {
        guard let grid else { return }
        let legend = LegendBuilder.legend(forSourceName: sourceName, in: modelContext)
        result = RosterImporter.resolveManual(grid: grid, sheetIndex: sheetIndex, mapping: mapping,
                                              sourceName: sourceName, legend: legend, dateOrder: dateOrder)
        applyLegendSniff(modelContext: modelContext)
        plan = nil
        preparePlan(modelContext: modelContext)
        phase = .loaded
    }

    /// Compute the add/update/remove diff against any existing roster for this
    /// source, for the preview (read-only).
    func preparePlan(modelContext: ModelContext) {
        guard let result, plan == nil else { return }
        plan = RosterSyncEngine.plan(for: result, in: modelContext)
    }

    /// THE funnel after a code is learned: rebuild the legend FROM THE STORE
    /// (never patch in place — must match what the next real import would do),
    /// re-resolve the retained rows, replan.
    func remapAndReplan(modelContext: ModelContext) {
        guard let result else { return }
        let legend = LegendBuilder.legend(forSourceName: result.sourceName, in: modelContext)
        self.result = RosterImporter.reresolve(result, legend: legend)
        plan = nil
        preparePlan(modelContext: modelContext)
    }

    func commit(modelContext: ModelContext) async {
        guard let result else { return }
        let plan = self.plan ?? RosterSyncEngine.plan(for: result, in: modelContext)
        phase = .writing

        do {
            let targets = try await CalendarTargetProvider.authorizedTargets()
            let summary = try await RosterSyncEngine.apply(plan, targets: targets, in: modelContext)
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
    /// In-window flow: the host clears the selection when the user is done.
    var onDone: (() -> Void)? = nil

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var coordinator = ImportCoordinator()
    @State private var isFileImporterPresented = false
    @State private var showingSmartPaste = false
    @State private var previewStyle: PreviewStyle = .calendar
    /// Built ONCE per plan (fetches ShiftType colors); cleared on new loads.
    @State private var overlay: PreviewOverlay?
    /// Observed here so the commit button's title tracks the picker live —
    /// the title must derive from THESE properties (reading the store
    /// directly never re-renders this view; the button froze on its first
    /// value in the field).
    @AppStorage(CalendarDestinationSetting.key) private var destinationsCSV: String = CalendarTargetKind.eventkit.rawValue
    @AppStorage(GoogleConfig.signedInDefaultsKey) private var googleSignedIn: Bool = false

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
        content
            .themedPane(.plain) // v7.1 wash
            .navigationTitle("Import roster")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { close() }
                }
            }
            .fileImporter(
                isPresented: $isFileImporterPresented,
                allowedContentTypes: Self.importTypes,
                allowsMultipleSelection: false
            ) { result in
                if case let .success(urls) = result, let url = urls.first {
                    Task {
                        overlay = nil
                        await coordinator.load(from: url, modelContext: modelContext)
                        coordinator.preparePlan(modelContext: modelContext)
                        if let plan = coordinator.plan {
                            overlay = PlanOverlayBuilder.build(from: plan, in: modelContext)
                        }
                    }
                } else if case let .failure(error) = result {
                    coordinator.phase = .failed(error.localizedDescription)
                }
            }
            #if canImport(FoundationModels)
            .sheet(isPresented: $showingSmartPaste) {
                if #available(iOS 26, macOS 26, *) {
                    SmartPasteSheet { csv, sourceName in
                        showingSmartPaste = false
                        overlay = nil
                        coordinator.loadFromText(csv, sourceName: sourceName, modelContext: modelContext)
                        if let plan = coordinator.plan {
                            overlay = PlanOverlayBuilder.build(from: plan, in: modelContext)
                        }
                    } onCancel: {
                        showingSmartPaste = false
                    }
                }
            }
            #endif
    }

    private func close() {
        if let onDone { onDone() } else { dismiss() }
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
        case .needsMapping:
            if let grid = coordinator.grid {
                ColumnMappingView(grid: grid, sourceDisplayName: coordinator.sourceName) { sheetIndex, mapping, order in
                    coordinator.applyManualMapping(sheetIndex: sheetIndex, mapping: mapping, dateOrder: order, modelContext: modelContext)
                    if let plan = coordinator.plan {
                        overlay = PlanOverlayBuilder.build(from: plan, in: modelContext)
                    }
                } onCancel: {
                    coordinator.cancelManualMapping()
                }
            }
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
            Label("Add your roster", systemImage: "tablecells")
        } description: {
            Text("Pick an Excel (.xlsx) or CSV file — Helm finds the dates and shift codes automatically. On‑device Apple Intelligence can also read a roster you paste as plain text.")
        } actions: {
            Button("Choose file…", systemImage: "folder") { isFileImporterPresented = true }
                .buttonStyle(.glassProminent)
            #if canImport(FoundationModels)
            if SmartImport.isAvailable {
                Button("Paste text instead…", systemImage: "sparkles") { showingSmartPaste = true }
            }
            #endif
        }
    }

    private func previewView(_ result: RosterImportResult) -> some View {
        let diff = coordinator.plan?.diff
        let isReimport = coordinator.plan?.isReimport ?? false
        let hasChanges = (diff?.hasChanges ?? (result.writableCount > 0))
            || destinationChangePending(isReimport: isReimport)
        return VStack(spacing: 0) {
            HStack(spacing: 12) {
                Picker("View", selection: $previewStyle) {
                    Label("Calendar", systemImage: "calendar").tag(PreviewStyle.calendar)
                    Label("List", systemImage: "list.bullet").tag(PreviewStyle.list)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 240)
                Spacer()
                CalendarDestinationPicker()
            }
            .padding(.horizontal)
            .padding(.vertical, 8)

            // v6 Import Intelligence: the always-visible health contract and,
            // when codes are unknown, the inline teach-Helm panel.
            HStack {
                ImportHealthBanner(health: importHealth(for: result)) { previewStyle = .list }
                Button("Columns wrong?", systemImage: "tablecells.badge.ellipsis") {
                    coordinator.enterManualMapping()
                }
                .font(.caption)
                .buttonStyle(.borderless)
                .help("Pick the sheet, header row and which columns hold the date and shift code.")
            }
            .padding(.horizontal)
            .padding(.bottom, 6)
            if coordinator.sniffedCount > 0 {
                Label("Read \(coordinator.sniffedCount) code\(coordinator.sniffedCount == 1 ? "" : "s") from your file's key — no need to teach \(coordinator.sniffedCount == 1 ? "it" : "them").",
                      systemImage: "sparkles.rectangle.stack")
                    .font(.caption)
                    .foregroundStyle(.green)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.bottom, 6)
            }
            if !result.unmappedCodes.isEmpty {
                // Bounded: expanded editors scroll inside the panel instead of
                // starving the calendar preview below.
                ScrollView {
                    UnknownCodesPanel(codes: result.unmappedCodes, result: result) { code, action in
                        LegendBuilder.learn(code: code, action: action, sourceName: result.sourceName, in: modelContext)
                        coordinator.remapAndReplan(modelContext: modelContext)
                        if let plan = coordinator.plan {
                            overlay = PlanOverlayBuilder.build(from: plan, in: modelContext)
                        }
                    }
                }
                .frame(maxHeight: 280)
                .padding(.horizontal)
                .padding(.bottom, 6)
            }

            // ZStack (not if/else) so toggling styles never destroys the
            // calendar's state (selected day, visible month, event cache).
            ZStack {
                Group {
                    if let overlay {
                        // The headline feature: the pending diff rendered against
                        // the user's real calendar (other events included).
                        CalendarView(mode: .preview(overlay))
                    } else {
                        ProgressView()
                    }
                }
                .opacity(previewStyle == .calendar ? 1 : 0)
                .allowsHitTesting(previewStyle == .calendar)
                listPreview(result, diff: diff, isReimport: isReimport)
                    .themedPane(.grouped) // grouped canvas over the root's plain wash
                    .opacity(previewStyle == .list ? 1 : 0)
                    .allowsHitTesting(previewStyle == .list)
            }

            commitBar(diff: diff, isReimport: isReimport, result: result, enabled: hasChanges)
        }
    }

    /// A glass bottom bar in the layout flow — NOT a `.safeAreaInset` overlay: the
    /// calendar preview's body is a GeometryReader (safe-area-greedy), so a
    /// floating inset button drew on top of the month grid + agenda.
    private func commitBar(diff: RosterDiff?, isReimport: Bool, result: RosterImportResult, enabled: Bool) -> some View {
        Button {
            Task { await coordinator.commit(modelContext: modelContext) }
        } label: {
            Text(commitTitle(diff: diff, isReimport: isReimport, result: result))
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.glassProminent)
        .controlSize(.large)
        .disabled(!enabled)
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.bar)
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
                if !result.unmappedCodes.isEmpty {
                    LabeledContent("Unknown codes", value: result.unmappedCodes.joined(separator: ", "))
                        .foregroundStyle(.orange)
                }
            }

            ForEach(outcomeGroups(for: result), id: \.title) { group in
                Section("\(group.title) (\(group.drafts.count))") {
                    ForEach(group.drafts) { draft in
                        DraftRow(draft: draft)
                    }
                }
            }
        }
    }

    private func outcomeGroups(for result: RosterImportResult) -> [(title: String, drafts: [DraftShift])] {
        var groups: [(String, [DraftShift])] = []
        let timed = result.drafts.filter { $0.outcome == .willWrite && !$0.isAllDay }
        let allDay = result.drafts.filter { $0.outcome == .willWrite && $0.isAllDay }
        let off = result.drafts.filter { $0.outcome == .skippedOff || $0.outcome == .skippedTentative }
        let byRule = result.drafts.filter { $0.outcome == .skippedByRule }
        let unknown = result.drafts.filter { $0.outcome == .skippedUnmapped }
        if !timed.isEmpty { groups.append(("Shifts", timed)) }
        if !allDay.isEmpty { groups.append(("All-day", allDay)) }
        if !off.isEmpty { groups.append(("Off days", off)) }
        if !byRule.isEmpty { groups.append(("Ignored by your rules", byRule)) }
        if !unknown.isEmpty { groups.append(("Unknown codes", unknown)) }
        return groups
    }

    private func importHealth(for result: RosterImportResult) -> ImportHealth {
        var written = 0, allDay = 0, off = 0, byRule = 0, unknown = 0
        for draft in result.drafts {
            switch draft.outcome {
            case .willWrite: if draft.isAllDay { allDay += 1 } else { written += 1 }
            case .skippedOff, .skippedTentative: off += 1
            case .skippedByRule: byRule += 1
            case .skippedUnmapped: unknown += 1
            }
        }
        return ImportHealth(written: written, allDay: allDay, off: off, byRule: byRule, unknown: unknown, unknownCodes: result.unmappedCodes)
    }

    /// CalendarDestinationSetting.current, derived from OBSERVED storage so
    /// SwiftUI re-evaluates when the picker changes.
    private var resolvedDestinations: Set<CalendarTargetKind> {
        var kinds = CalendarDestinationSetting.parse(destinationsCSV)
        if kinds.isEmpty { kinds = [.eventkit] }
        if kinds.contains(.google), !(GoogleConfig.isConfigured && googleSignedIn) {
            kinds.remove(.google)
        }
        return kinds.isEmpty ? [.eventkit] : kinds
    }

    /// The matched profile's recorded destinations differ from the current
    /// selection — committing migrates even when the shifts are unchanged.
    private func destinationChangePending(isReimport: Bool) -> Bool {
        guard isReimport, let profileID = coordinator.plan?.existingProfileID else { return false }
        let descriptor = FetchDescriptor<ImportProfile>(predicate: #Predicate { $0.id == profileID })
        guard let profile = try? modelContext.fetch(descriptor).first else { return false }
        return profile.targets != resolvedDestinations
    }

    private func commitTitle(diff: RosterDiff?, isReimport: Bool, result: RosterImportResult) -> String {
        let destination = SyncSummary.name(for: resolvedDestinations)
        func shifts(_ n: Int) -> String { "\(n) shift\(n == 1 ? "" : "s")" }
        guard let diff else { return "Add \(shifts(result.writableCount)) to \(destination)" }
        if !diff.hasChanges {
            return destinationChangePending(isReimport: isReimport)
                ? "Move shifts to \(destination)"
                : "No changes"
        }
        if isReimport {
            var parts: [String] = []
            if diff.added.count > 0 { parts.append("+\(diff.added.count)") }
            if diff.updated.count > 0 { parts.append("✎\(diff.updated.count)") }
            if diff.removed.count > 0 { parts.append("−\(diff.removed.count)") }
            return "Apply changes to \(destination) (\(parts.joined(separator: " ")))"
        }
        return "Add \(shifts(diff.added.count)) to \(destination)"
    }

    private func finishedView(summary: SyncSummary) -> some View {
        ContentUnavailableView {
            Label(summary.isReimport ? "Roster updated" : "Shifts added", systemImage: "checkmark.circle.fill")
        } description: {
            Text(summary.userDescription)
        } actions: {
            Button("Done") { close() }.buttonStyle(.glassProminent)
        }
    }

    private func failureView(_ message: String) -> some View {
        ContentUnavailableView {
            Label("Import problem", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            // Never dead-end: if the grid decoded but columns weren't detected,
            // let the user map them by hand (prominent); else just retry.
            if coordinator.grid != nil {
                Button("Map columns manually", systemImage: "tablecells") {
                    coordinator.enterManualMapping()
                }
                .buttonStyle(.glassProminent)
                Button("Try another file", action: retryAnotherFile)
                    .buttonStyle(.glass)
            } else {
                Button("Try another file", action: retryAnotherFile)
                    .buttonStyle(.glassProminent)
            }
        }
    }

    private func retryAnotherFile() {
        coordinator.result = nil
        coordinator.plan = nil
        overlay = nil
        coordinator.phase = .idle
        isFileImporterPresented = true
    }
}

/// "Add to: Apple + Google Calendar" — v5 MULTI-select: both can be on at
/// once and every apply writes to all of them. Same setting Settings manages.
struct CalendarDestinationPicker: View {
    @AppStorage(CalendarDestinationSetting.key) private var destinationsCSV: String = CalendarTargetKind.eventkit.rawValue
    @AppStorage(GoogleConfig.signedInDefaultsKey) private var googleSignedIn: Bool = false

    private var googleUsable: Bool { GoogleConfig.isConfigured && googleSignedIn }
    private var chosen: Set<CalendarTargetKind> {
        let kinds = CalendarDestinationSetting.parse(destinationsCSV)
        return kinds.isEmpty ? [.eventkit] : kinds
    }

    /// What writes will actually target right now (observed, Google-gated).
    private var resolvedKinds: Set<CalendarTargetKind> {
        var kinds = chosen
        if kinds.contains(.google), !(GoogleConfig.isConfigured && googleSignedIn) {
            kinds.remove(.google)
        }
        return kinds.isEmpty ? [.eventkit] : kinds
    }

    var body: some View {
        Menu {
            Toggle("Apple Calendar", isOn: binding(for: .eventkit))
            if GoogleConfig.isConfigured {
                Toggle("Google Calendar", isOn: binding(for: .google))
                    .disabled(!googleUsable && !chosen.contains(.google))
            }
        } label: {
            // Derived from the OBSERVED properties — a raw store read here
            // froze on first render (same class as the 559aed4 commit-title bug).
            Label("Add to: \(SyncSummary.name(for: resolvedKinds))",
                  systemImage: "calendar.badge.plus")
                .lineLimit(1)
        }
        .fixedSize()
        // Run the legacy single-key migration before @AppStorage's default masks it.
        .onAppear { _ = CalendarDestinationSetting.chosenKinds }
    }

    private func binding(for kind: CalendarTargetKind) -> Binding<Bool> {
        Binding(
            get: { chosen.contains(kind) },
            set: { isOn in
                var kinds = chosen
                if isOn { kinds.insert(kind) } else { kinds.remove(kind) }
                if kinds.isEmpty { kinds = [.eventkit] } // never write to nowhere
                destinationsCSV = CalendarDestinationSetting.encode(kinds)
            }
        )
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
            if draft.isAllDay { return "All-day" }
            if let s = draft.startMinuteOfDay, let e = draft.endMinuteOfDay {
                return "\(ImportCoordinator.hhmm(s))–\(ImportCoordinator.hhmm(e))"
            }
            return "✓"
        case .skippedOff: return "Off"
        case .skippedTentative: return "TBC"
        case .skippedByRule: return "Ignored (your rule)"
        case .skippedUnmapped: return "Unknown: \(draft.code)"
        }
    }

    private var color: Color {
        switch draft.outcome {
        case .willWrite: .secondary
        case .skippedOff: .secondary
        case .skippedTentative: .orange
        case .skippedByRule: .secondary
        case .skippedUnmapped: .red
        }
    }
}
