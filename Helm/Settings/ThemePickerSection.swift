//
//  ThemePickerSection.swift
//  Helm
//
//  v7.1: the Settings theme picker — ONE adaptive grid of miniature app
//  previews (replacing the five stacked vibe-grids). Each card paints the
//  REAL catalog colours: the theme's wash gradient, a mini sidebar, two
//  fake-glass cards and the accent pill, rendered under the theme's OWN
//  colour scheme — so a dark theme previews dark even while the app is
//  light. Tapping applies instantly (the app itself is the full preview).
//
//  The card's glass is deliberately FAKE (opacity-composited): real
//  .ultraThinMaterial would sample the Form row behind the card and render
//  every theme's glass identically — i.e. it would lie.
//

import SwiftUI
import HelmDomain

struct ThemePickerSection: View {
    @Environment(ThemeManager.self) private var theme

    private let columns = [GridItem(.adaptive(minimum: 116), spacing: 12)]

    var body: some View {
        Section {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                ForEach(theme.all) { palette in
                    ThemePreviewCard(
                        palette: palette,
                        isSelected: theme.selectedID == palette.id,
                        select: { theme.selectedID = palette.id }
                    )
                }
            }
            .padding(.vertical, 4) // room for the 2pt selection ring
        } header: {
            Text("Appearance")
        } footer: {
            Text("Tap a theme to apply it instantly. “Default” follows your system accent and light/dark setting.")
        }
    }
}

/// A miniature mock of the app, painted with one palette's actual colours.
private struct ThemePreviewCard: View {
    let palette: ThemePalette
    let isSelected: Bool
    let select: () -> Void

    @Environment(\.colorScheme) private var systemScheme

    // Resolved palette colours (all nil-gated, so Default renders system-honest).
    private var accent: Color { palette.accentHex.flatMap { Color(hex: $0) } ?? .accentColor }
    private var secondary: Color { palette.secondaryHex.flatMap { Color(hex: $0) } ?? accent }
    private var bgTop: Color? { palette.backgroundTopHex.flatMap { Color(hex: $0) } }
    private var bgBottom: Color? { palette.backgroundBottomHex.flatMap { Color(hex: $0) } }
    private var glass: Color? { palette.glassTintHex.flatMap { Color(hex: $0) } }

    /// The card previews under the THEME's scheme (system themes follow the
    /// surrounding app) — a dark theme must look dark in a light app.
    private var isDarkPreview: Bool {
        palette.scheme == .dark || (palette.scheme == .system && systemScheme == .dark)
    }

    var body: some View {
        Button(action: select) {
            VStack(spacing: 5) {
                mock
                    .frame(height: 76)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(isSelected ? accent : Color.primary.opacity(0.12),
                                          lineWidth: isSelected ? 2 : 1)
                    )
                HStack(spacing: 4) {
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(accent)
                    }
                    Text(palette.name)
                        .font(.caption.weight(isSelected ? .semibold : .regular))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                Text(palette.vibe.displayName)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(palette.name), \(palette.vibe.displayName) theme")
        .accessibilityHint("Applies immediately")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    // MARK: The mini app mock

    private var mock: some View {
        let base: Color = isDarkPreview ? Color(white: 0.11) : Color(white: 0.97)
        let washOpacity: Double = isDarkPreview ? 0.55 : 0.25
        return ZStack {
            base
            if let bgTop {
                LinearGradient(colors: [bgTop, bgBottom ?? bgTop],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                    .opacity(washOpacity)
            }
            HStack(spacing: 0) {
                // Mini sidebar — selected row in accent.
                VStack(alignment: .leading, spacing: 4) {
                    Capsule().fill(accent).frame(width: 18, height: 5)
                    Capsule().fill(.primary.opacity(0.18)).frame(width: 22, height: 5)
                    Capsule().fill(.primary.opacity(0.18)).frame(width: 14, height: 5)
                    Spacer(minLength: 0)
                }
                .padding(6)
                .frame(width: 30, alignment: .topLeading)
                .background((bgTop ?? Color.primary).opacity(bgTop == nil ? 0.06 : 0.18))

                Rectangle().fill(.primary.opacity(0.08)).frame(width: 0.5)

                // Mini detail pane — accent pill + two glass cards.
                VStack(alignment: .leading, spacing: 5) {
                    Capsule()
                        .fill(LinearGradient(colors: [accent, secondary], startPoint: .leading, endPoint: .trailing))
                        .frame(width: 40, height: 7)
                    miniCard
                    miniCard
                    Spacer(minLength: 0)
                }
                .padding(7)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        // KEY: .primary inside the mock resolves against the CARD's scheme.
        .environment(\.colorScheme, isDarkPreview ? .dark : .light)
    }

    private var miniCard: some View {
        let fill: Color = isDarkPreview ? Color.white.opacity(0.10) : Color.white.opacity(0.65)
        return RoundedRectangle(cornerRadius: 5)
            .fill(fill)
            .overlay {
                if let glass {
                    RoundedRectangle(cornerRadius: 5).fill(glass.opacity(0.15))
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.primary.opacity(0.07), lineWidth: 0.5))
            .frame(height: 20)
    }
}
