//
//  ThemedBackground.swift
//  Helm
//
//  v7.1 chrome theming: the ONE component that makes a theme visibly restyle
//  the app's surfaces (window, sidebar, panes) instead of just its accent.
//
//  Mechanics (and why): the wash gradient is layered OVER material, never
//  under it — behind-window material samples the DESKTOP, not sibling layers,
//  so anything painted under it is invisible (the same physics that made the
//  old 0.07 card tint vanish). Opacity is a fixed scheme-keyed recipe here in
//  code, deliberately NOT in the catalog: hue is data, intensity is policy.
//
//  Default theme: both wash stops are nil → every code path below collapses
//  to a literal no-op and the app renders byte-identical to pre-v7.1.
//

import SwiftUI

/// Scheme-keyed wash opacities — the single tuning point.
enum ThemeWashStrength {
    /// macOS window wash (over .ultraThinMaterial).
    static func window(_ scheme: ColorScheme) -> Double { scheme == .dark ? 0.55 : 0.30 }
    /// iOS pane wash (over the opaque system background — no frost between).
    static func pane(_ scheme: ColorScheme) -> Double { scheme == .dark ? 0.45 : 0.25 }
}

#if os(macOS)
/// The macOS window background: the loved ultra-thin frost, ALWAYS present and
/// unchanged, with the theme wash composited over it. The Liquid Glass sidebar
/// samples in-window content behind its column, so this wash tints the sidebar
/// for free — no sidebar-specific code (and never .scrollContentBackground
/// (.hidden) there: it would strip the vibrancy material).
struct ThemedWindowBackground: View {
    @Environment(\.helmBackgroundTop) private var top
    @Environment(\.helmBackgroundBottom) private var bottom
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Rectangle()
            .fill(.ultraThinMaterial)
            .overlay {
                if let top, let bottom {
                    LinearGradient(colors: [top, bottom], startPoint: .topLeading, endPoint: .bottomTrailing)
                        .opacity(ThemeWashStrength.window(scheme))
                        .allowsHitTesting(false)
                }
            }
            .ignoresSafeArea()
    }
}
#endif

/// iOS/iPadOS pane theming: hides the system scroll background ONLY when a
/// wash exists (`.automatic` is the framework default, so Default themes are a
/// true no-op AND view identity stays stable across theme switches — no
/// ViewBuilder branch around the content), then paints the wash over the
/// appropriate system base. Cell/row backgrounds stay system — only the canvas
/// behind them is themed, which is what keeps grouped forms legible.
struct ThemedPaneBackground: ViewModifier {
    enum Base {
        case grouped // List/Form canvases (systemGroupedBackground)
        case plain   // ScrollView/custom canvases (systemBackground)
    }

    let base: Base
    @Environment(\.helmBackgroundTop) private var top
    @Environment(\.helmBackgroundBottom) private var bottom
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content
            .scrollContentBackground(top == nil ? .automatic : .hidden)
            .background {
                if let top, let bottom {
                    ZStack {
                        #if os(iOS)
                        (base == .grouped ? Color(.systemGroupedBackground) : Color(.systemBackground))
                        #endif
                        LinearGradient(colors: [top, bottom], startPoint: .topLeading, endPoint: .bottomTrailing)
                            .opacity(ThemeWashStrength.pane(scheme))
                    }
                    .ignoresSafeArea()
                }
            }
    }
}

extension View {
    /// Adopt the theme wash on a pane root. Passthrough on macOS — there the
    /// themed WINDOW background + Liquid Glass do the work for every pane.
    @ViewBuilder
    func themedPane(_ base: ThemedPaneBackground.Base = .grouped) -> some View {
        #if os(macOS)
        self
        #else
        modifier(ThemedPaneBackground(base: base))
        #endif
    }
}
