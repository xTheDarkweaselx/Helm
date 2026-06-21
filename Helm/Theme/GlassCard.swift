//
//  GlassCard.swift
//  Helm
//
//  v7 Liquid Glass: the single place the "ultra-thin material in a rounded
//  rectangle" card idiom lives, plus the active theme's faint glass tint. Use
//  the `.glassCard()` modifier as a drop-in for the old
//  `.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius:))`, or the
//  `GlassCard { … }` container when you also want consistent padding.
//

import SwiftUI

extension View {
    /// Drop-in glass background: theme-tinted ultra-thin material in a rounded
    /// rectangle. The tint is faint (0.12 light / 0.16 dark — strong enough to
    /// read now that the canvas BEHIND cards is washed too, still well under
    /// the legibility ceiling) and only applied when the theme sets one
    /// (Default leaves it plain).
    func glassCard(cornerRadius: CGFloat = 14) -> some View {
        modifier(GlassCardBackground(cornerRadius: cornerRadius))
    }
}

private struct GlassCardBackground: ViewModifier {
    let cornerRadius: CGFloat
    @Environment(\.helmGlassTint) private var glassTint
    @Environment(\.colorScheme) private var scheme
    // Accessibility: flatten the translucent material to a solid surface when the
    // user (or the system) asks for reduced transparency, so text keeps contrast.
    @Environment(\.accessibilityReduceTransparency) private var systemReduceTransparency
    @AppStorage(A11ySettings.reduceTransparencyKey) private var appReduceTransparency = false

    private var flat: Bool { appReduceTransparency || systemReduceTransparency }

    func body(content: Content) -> some View {
        content.background {
            let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            ZStack {
                if flat {
                    shape.fill(scheme == .dark ? Color(white: 0.17) : Color.white)
                } else {
                    shape.fill(.ultraThinMaterial)
                }
                if let glassTint {
                    shape.fill(glassTint.opacity(flat ? (scheme == .dark ? 0.22 : 0.14)
                                                      : (scheme == .dark ? 0.16 : 0.12)))
                }
            }
        }
    }
}

/// A padded glass card container for new v7 surfaces.
struct GlassCard<Content: View>: View {
    var cornerRadius: CGFloat = 14
    var padding: CGFloat = 14
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassCard(cornerRadius: cornerRadius)
    }
}
