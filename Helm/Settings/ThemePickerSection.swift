//
//  ThemePickerSection.swift
//  Helm
//
//  v7 theming: the Settings section that picks the app theme. A swatch grid
//  grouped by vibe; tapping a swatch re-themes the whole app instantly (the
//  ThemeManager drives both scene roots), so the app itself IS the live preview.
//

import SwiftUI
import HelmDomain

struct ThemePickerSection: View {
    @Environment(ThemeManager.self) private var theme

    private let columns = [GridItem(.adaptive(minimum: 66), spacing: 12)]

    var body: some View {
        Section {
            ForEach(ThemeCatalog.grouped, id: \.vibe) { group in
                VStack(alignment: .leading, spacing: 8) {
                    Text(group.vibe.displayName.uppercased())
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                        ForEach(group.palettes) { palette in
                            swatch(palette)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        } header: {
            Text("Appearance")
        } footer: {
            Text("Pick a theme — it applies everywhere instantly. “Default” follows your system accent and light/dark setting.")
        }
    }

    private func swatch(_ palette: ThemePalette) -> some View {
        let isSelected = theme.selectedID == palette.id
        return Button {
            theme.selectedID = palette.id
        } label: {
            VStack(spacing: 5) {
                ZStack {
                    Circle()
                        .fill(swatchFill(palette))
                        .frame(width: 38, height: 38)
                        .overlay(
                            Circle().strokeBorder(.primary.opacity(isSelected ? 0.85 : 0.12),
                                                  lineWidth: isSelected ? 2.5 : 1)
                        )
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.white)
                            .shadow(radius: 1)
                    }
                }
                Text(palette.name)
                    .font(.caption2)
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(palette.name) theme")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    /// The swatch fill: a gradient from accent → secondary (or a single accent /
    /// the system accent for Default).
    private func swatchFill(_ palette: ThemePalette) -> AnyShapeStyle {
        let accent = palette.accentHex.flatMap { Color(hex: $0) } ?? .accentColor
        if let secondaryHex = palette.secondaryHex, let secondary = Color(hex: secondaryHex) {
            return AnyShapeStyle(LinearGradient(colors: [accent, secondary], startPoint: .topLeading, endPoint: .bottomTrailing))
        }
        return AnyShapeStyle(accent)
    }
}
