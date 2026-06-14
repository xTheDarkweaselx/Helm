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
    var body: some View {
        // Frost ONLY — the base Liquid Glass. The wash is carried by the panes and
        // the sidebar (each adopts .themedPane()), so painting it here too would
        // DOUBLE the wash: the live theme came out heavier than the single-wash
        // preview, and the inactive-window desaturation hit two material layers
        // (the "darkened tint when the window loses focus" report). One wash now.
        Rectangle()
            .fill(.ultraThinMaterial)
            .ignoresSafeArea()
    }
}
#endif

/// Pane theming (both platforms): hides the system scroll background ONLY when a
/// wash exists (`.automatic` is the framework default, so Default themes are a
/// true no-op AND view identity stays stable across theme switches), then paints
/// the wash over a glass/system base so the surface reads as the theme hue —
/// matching the picker preview. Cell/row backgrounds stay system; only the canvas
/// behind them is themed, which keeps grouped forms legible.
///
/// macOS: the canvas is `.ultraThinMaterial` (the loved Liquid Glass frost) with
/// the wash composited OVER it — so the sidebar and every pane that adopts this
/// finally carry the theme colour instead of staying system-grey, WITHOUT losing
/// the glass. v7.1's "let the sidebar sample the window wash" was invisible once
/// an opaque Form/list canvas covered that wash; painting the wash on the canvas
/// itself is what the preview always promised.
struct ThemedPaneBackground: ViewModifier {
    enum Base {
        case grouped // List/Form canvases (systemGroupedBackground)
        case plain   // ScrollView/custom canvases (systemBackground)
    }

    let base: Base
    /// false → behave exactly like the nil-wash (Default) path. Used by views
    /// embedded in an already-washed host (e.g. the calendar in preview mode)
    /// so the gradient doesn't restart mid-screen.
    var active: Bool = true
    @Environment(\.helmBackgroundTop) private var top
    @Environment(\.helmBackgroundBottom) private var bottom
    @Environment(\.colorScheme) private var scheme

    private var washTop: Color? { active ? top : nil }

    #if os(macOS)
    private var washOpacity: Double { ThemeWashStrength.window(scheme) }
    #else
    private var washOpacity: Double { ThemeWashStrength.pane(scheme) }
    #endif

    func body(content: Content) -> some View {
        #if os(macOS)
        // A grouped Form/List canvas is OPAQUE system grey/white on macOS, so for
        // grouped panes ALWAYS hide it and supply our own frost — otherwise the
        // Default (no-wash) theme shows a SOLID pane instead of the glass window
        // (the Settings-looks-solid bug). Plain panes stay a true Default no-op
        // (transparent → the window frost shows through), painting only when washed.
        let needsCanvas = base == .grouped || washTop != nil
        content
            .scrollContentBackground(needsCanvas ? .hidden : .automatic)
            .background {
                if needsCanvas {
                    ZStack {
                        Rectangle().fill(.ultraThinMaterial) // the loved Liquid Glass frost
                        if let top = washTop, let bottom {
                            LinearGradient(colors: [top, bottom], startPoint: .topLeading, endPoint: .bottomTrailing)
                                .opacity(washOpacity)
                        }
                    }
                    .ignoresSafeArea()
                }
            }
        #else
        content
            .scrollContentBackground(washTop == nil ? .automatic : .hidden)
            .background {
                if let top = washTop, let bottom {
                    ZStack {
                        (base == .grouped ? Color(.systemGroupedBackground) : Color(.systemBackground))
                        LinearGradient(colors: [top, bottom], startPoint: .topLeading, endPoint: .bottomTrailing)
                            .opacity(washOpacity)
                    }
                    .ignoresSafeArea()
                }
            }
        #endif
    }
}

extension View {
    /// Adopt the theme wash on a pane/sidebar root — now active on macOS too, so
    /// the chrome actually takes the theme colour (over Liquid Glass) the way the
    /// picker preview shows, instead of staying system-grey.
    func themedPane(_ base: ThemedPaneBackground.Base = .grouped, active: Bool = true) -> some View {
        modifier(ThemedPaneBackground(base: base, active: active))
    }
}
