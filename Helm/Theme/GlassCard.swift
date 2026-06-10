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
    /// rectangle. Tint is kept faint (≤ 0.08) so legibility never suffers, and
    /// only applied when the theme actually sets one (Default leaves it plain).
    func glassCard(cornerRadius: CGFloat = 14) -> some View {
        modifier(GlassCardBackground(cornerRadius: cornerRadius))
    }
}

private struct GlassCardBackground: ViewModifier {
    let cornerRadius: CGFloat
    @Environment(\.helmGlassTint) private var glassTint

    func body(content: Content) -> some View {
        content.background {
            let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            ZStack {
                shape.fill(.ultraThinMaterial)
                if let glassTint {
                    shape.fill(glassTint.opacity(0.07))
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
