//
//  SmartImport.swift
//  Helm
//
//  v9 Foundation Models flexible import. The on-device model's ONLY job is to turn
//  arbitrary roster text (a pasted email, message, copied table…) into structured
//  shifts; everything after that — legend resolution, dedup, OFF/tentative
//  handling, the teach-Helm panel, the calendar diff and write — is the existing
//  RosterImporter / ImportView pipeline, reused unchanged.
//
//  Device-only: the model is unavailable on the Simulator and on devices without
//  Apple Intelligence, so the Smart Import entry only appears when it can run.
//  Everything is gated `#if canImport(FoundationModels)` + an availability check,
//  and the file/CSV importers remain the fallback on every other device.
//

import SwiftUI
#if canImport(FoundationModels)
import FoundationModels
#endif

enum SmartImport {

    /// Whether on-device Smart Import can run right now.
    static var isAvailable: Bool { unavailableReason == nil }

    /// Why Smart Import can't run, or nil when it can.
    static var unavailableReason: String? {
        #if canImport(FoundationModels)
        if #available(iOS 26, macOS 26, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return nil
            case .unavailable(.deviceNotEligible):
                return "This device doesn't support Apple Intelligence."
            case .unavailable(.appleIntelligenceNotEnabled):
                return "Turn on Apple Intelligence in Settings to use Smart Import."
            case .unavailable(.modelNotReady):
                return "Apple Intelligence is still preparing. Try again shortly."
            case .unavailable:
                return "Smart Import isn't available on this device right now."
            }
        }
        return "Smart Import needs iOS 26 or macOS 26."
        #else
        return "Smart Import needs iOS 26 or macOS 26."
        #endif
    }

    #if canImport(FoundationModels)
    @available(iOS 26, macOS 26, *)
    static func extract(from text: String) async throws -> ExtractedRoster {
        let session = LanguageModelSession(instructions: instructions)
        let response = try await session.respond(to: text, generating: ExtractedRoster.self)
        return response.content
    }

    @available(iOS 26, macOS 26, *)
    private static var instructions: String {
        """
        You convert a person's work roster — written in any layout or format — into structured shifts.
        Produce one entry per dated shift, in date order. For each entry give the calendar date and \
        EITHER a shift code/name exactly as written (e.g. M, Early, LD, Night) OR explicit start and \
        end times. Use dd/MM/yyyy for dates and 24-hour HH:mm for times. Skip days that are off, rest, \
        blank or annual leave. Never invent shifts that aren't in the text.
        """
    }

    /// AI-assist for the spreadsheet importer: which columns hold what.
    @available(iOS 26, macOS 26, *)
    static func suggestColumns(from gridText: String) async throws -> ColumnSuggestion {
        let session = LanguageModelSession(instructions: """
            You are given a spreadsheet of a work roster as tab-separated rows. The first row labels each \
            column with its 0-based index (Col0, Col1, …). Identify which column index holds the calendar \
            DATE, which holds the SHIFT code or name, and an optional TITLE/description column (-1 if none). \
            Also say how many rows at the top are headers before the shift data begins.
            """)
        return try await session.respond(to: gridText, generating: ColumnSuggestion.self).content
    }

    /// AI-assist for the teach-Helm panel: what an unknown shift code likely means.
    @available(iOS 26, macOS 26, *)
    static func decodeCode(_ code: String, sampleTitle: String?) async throws -> CodeMeaning {
        let context = sampleTitle.map { " It sometimes appears with the description: \"\($0)\"." } ?? ""
        let session = LanguageModelSession(instructions: """
            You interpret short codes used on UK work rosters for shift types. Given a code, give a likely \
            full name and the typical start and end times (24-hour HH:mm) for that kind of shift. If it's \
            plainly an overnight shift, the end time may be earlier than the start.
            """)
        return try await session.respond(to: "Shift code: \"\(code)\".\(context)", generating: CodeMeaning.self).content
    }
    #endif
}

#if canImport(FoundationModels)

@available(iOS 26, macOS 26, *)
@Generable
struct ExtractedRoster {
    @Guide(description: "Every dated shift found in the roster, in date order")
    var shifts: [ExtractedShift]
}

@available(iOS 26, macOS 26, *)
@Generable
struct ExtractedShift {
    @Guide(description: "The shift's date, formatted dd/MM/yyyy")
    var date: String
    @Guide(description: "The shift code or name exactly as written, e.g. M, Early, Night. Empty if only times are given.")
    var code: String
    @Guide(description: "Start time as HH:mm 24-hour, or empty if not stated")
    var startTime: String
    @Guide(description: "End time as HH:mm 24-hour, or empty if not stated")
    var endTime: String
}

@available(iOS 26, macOS 26, *)
@Generable
struct ColumnSuggestion {
    @Guide(description: "0-based index of the column that holds calendar dates")
    var dateColumn: Int
    @Guide(description: "0-based index of the column that holds the shift code or name")
    var codeColumn: Int
    @Guide(description: "0-based index of an optional title/description column, or -1 if there isn't one")
    var titleColumn: Int
    @Guide(description: "How many rows at the top are headers before the shift data begins (usually 1)")
    var headerRows: Int
}

@available(iOS 26, macOS 26, *)
@Generable
struct CodeMeaning {
    @Guide(description: "A short human-readable name for this shift code, e.g. 'Long Day' for 'LD'")
    var label: String
    @Guide(description: "The most likely start time as HH:mm 24-hour")
    var startTime: String
    @Guide(description: "The most likely end time as HH:mm 24-hour")
    var endTime: String
}

@available(iOS 26, macOS 26, *)
extension ExtractedRoster {
    /// Render as the simple CSV the existing RosterImporter consumes: explicit
    /// times become an inline "HHMM-HHMM" cell (resolved directly), otherwise the
    /// raw code (resolved by the legend, or surfaced in the teach-Helm panel).
    func toCSV() -> String {
        var lines = ["Date,Shift"]
        for s in shifts {
            let date = s.date.trimmingCharacters(in: .whitespaces)
            guard !date.isEmpty else { continue }
            let start = digits(s.startTime), end = digits(s.endTime)
            let cell = (start.count == 4 && end.count == 4) ? "\(start)-\(end)"
                                                            : s.code.trimmingCharacters(in: .whitespaces)
            guard !cell.isEmpty else { continue }
            lines.append("\(field(date)),\(field(cell))")
        }
        return lines.joined(separator: "\n")
    }

    private func digits(_ s: String) -> String { s.filter(\.isNumber) }
    private func field(_ s: String) -> String {
        s.contains(where: { ",\"\n".contains($0) })
            ? "\"\(s.replacingOccurrences(of: "\"", with: "\"\""))\""
            : s
    }
}

/// Paste-any-text → Foundation Models extracts shifts → hands a CSV back to the
/// import flow. Presented from ImportView's idle screen when Smart Import can run.
@available(iOS 26, macOS 26, *)
struct SmartPasteSheet: View {
    /// (csv, sourceName) once extraction succeeds.
    let onExtract: (String, String) -> Void
    let onCancel: () -> Void

    @State private var text = ""
    @State private var isExtracting = false
    @State private var error: String?
    @FocusState private var editorFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 0) {
                Text("Paste your roster — an email, a message, a copied table, anything. Apple Intelligence reads it on-device and pulls out your shifts.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding([.horizontal, .top])

                TextEditor(text: $text)
                    .focused($editorFocused)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(alignment: .topLeading) {
                        if text.isEmpty {
                            Text("Paste here…")
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 13).padding(.vertical, 16)
                                .allowsHitTesting(false)
                        }
                    }

                if let error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                        .padding(.horizontal)
                }
            }
            .themedPane(.plain)
            .navigationTitle("Smart Import")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onCancel) }
                ToolbarItem(placement: .confirmationAction) {
                    if isExtracting {
                        ProgressView()
                    } else {
                        Button("Extract") { Task { await extract() } }
                            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
        }
        .onAppear { editorFocused = true }
    }

    private func extract() async {
        error = nil
        isExtracting = true
        defer { isExtracting = false }
        do {
            let roster = try await SmartImport.extract(from: text)
            let csv = roster.toCSV()
            guard csv.split(separator: "\n").count > 1 else {
                error = "Helm couldn't find any shifts in that text. Try including the dates and shift names."
                return
            }
            onExtract(csv, "Smart import")
        } catch {
            self.error = error.localizedDescription
        }
    }
}
#endif
