//
//  RotaTemplatesGallery.swift
//  Helm
//
//  v9 Rota Templates Gallery: the picker shown when starting a new schedule —
//  a blank option plus ready-made shift patterns, each with a colour-coded
//  preview of its cycle. Choosing one materialises a fully-editable schedule.
//

import SwiftUI
import HelmDomain

struct RotaTemplatesGallery: View {
    /// nil = start blank; otherwise adopt the chosen template.
    let onPick: (RotaTemplate?) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button { onPick(nil) } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "square.dashed").font(.title2).foregroundStyle(.tint).frame(width: 32)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Blank schedule").font(.subheadline.weight(.semibold))
                                Text("Build your own cycle from scratch.").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                    .buttonStyle(.plain)
                }

                Section {
                    ForEach(RotaTemplate.all) { template in
                        Button { onPick(template) } label: { row(template) }
                            .buttonStyle(.plain)
                    }
                } header: {
                    Text("Start from a template")
                } footer: {
                    Text("Starts a ready-made cycle from today. Rename, retime or edit anything afterwards.")
                }
            }
            .formStyle(.grouped)
            .themedPane()
            .navigationTitle("Build a rota")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }

    private func row(_ t: RotaTemplate) -> some View {
        HStack(spacing: 12) {
            Image(systemName: t.symbol).font(.title2).foregroundStyle(.tint).frame(width: 32)
            VStack(alignment: .leading, spacing: 4) {
                Text(t.name).font(.subheadline.weight(.semibold))
                Text(t.summary).font(.caption).foregroundStyle(.secondary)
                cyclePreview(t)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }

    /// A compact colour-coded strip of the cycle (capped), so the pattern reads at
    /// a glance — coloured chip per worked day, faint grey for OFF.
    private func cyclePreview(_ t: RotaTemplate) -> some View {
        let colors = Dictionary(t.types.map { ($0.code, Color(hex: $0.colorHex) ?? .accentColor) },
                                uniquingKeysWith: { a, _ in a })
        let cap = 14
        return HStack(spacing: 3) {
            ForEach(Array(t.slots.prefix(cap).enumerated()), id: \.offset) { _, code in
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(code.flatMap { colors[$0] } ?? Color.secondary.opacity(0.22))
                    .frame(width: 13, height: 16)
                    .overlay {
                        if let code {
                            Text(code).font(.system(size: 8, weight: .bold)).foregroundStyle(.white)
                        }
                    }
            }
            if t.slots.count > cap {
                Text("+\(t.slots.count - cap)").font(.system(size: 9)).foregroundStyle(.secondary)
            }
        }
        .padding(.top, 2)
    }
}
