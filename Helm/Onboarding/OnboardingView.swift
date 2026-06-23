//
//  OnboardingView.swift
//  Helm
//
//  v9 first-run welcome guide: a short two-page tour (what Helm does → how to use
//  it) that hands you straight into your first import. Appearance & accessibility
//  live in Settings, where the copy points. Shown once on first launch, gated by
//  `hasCompletedOnboarding`; replayable from Settings ▸ "Show welcome guide".
//

import SwiftUI

/// Persisted gate. False until the user finishes (or skips) the guide; Settings'
/// reset flips it back to false to replay.
enum OnboardingState {
    static let completedKey = "hasCompletedOnboarding"
}

/// Presents the welcome guide full-screen on iOS, as a sheet on macOS.
struct OnboardingPresenter: ViewModifier {
    @Binding var isPresented: Bool
    let onFinish: () -> Void
    let onImport: () -> Void

    func body(content: Content) -> some View {
        #if os(iOS)
        content.fullScreenCover(isPresented: $isPresented) { OnboardingView(onFinish: onFinish, onImport: onImport) }
        #else
        content.sheet(isPresented: $isPresented) { OnboardingView(onFinish: onFinish, onImport: onImport) }
        #endif
    }
}

struct OnboardingView: View {
    /// Called when the user finishes or skips — the host sets the completed flag.
    let onFinish: () -> Void
    /// Called by the final "Import a roster" CTA to hand straight into the importer.
    let onImport: () -> Void

    @Environment(ThemeManager.self) private var theme
    @State private var page = 0

    private let lastPage = 1 // Welcome, How it works

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                if page < lastPage {
                    Button("Skip", action: onFinish)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal)
            .padding(.top, 10)
            .frame(height: 28)

            #if os(iOS)
            TabView(selection: $page) {
                welcomePage.tag(0)
                howItWorksPage.tag(1)
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .always))
            #else
            Group {
                switch page {
                case 0: welcomePage
                default: howItWorksPage
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transition(.opacity)
            #endif

            Button(page == lastPage ? "Import a roster" : "Continue") {
                if page == lastPage {
                    onImport()  // hand straight into the importer instead of a dead-end welcome
                    onFinish()
                } else {
                    withAnimation { page += 1 }
                }
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .frame(maxWidth: 420)
            .padding()
        }
        .themedPane(.plain)
        .interactiveDismissDisabled()
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 600)
        #endif
    }

    // MARK: Pages

    private var welcomePage: some View {
        pageScaffold {
            hero("sailboat.fill")
            Text("Welcome to Helm")
                .font(.largeTitle.weight(.bold))
            Text("Your work roster, always in step with your calendar.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private var howItWorksPage: some View {
        pageScaffold {
            Text("How Helm works")
                .font(.title.weight(.bold))
                .padding(.bottom, 4)
            step("square.and.arrow.down", "Bring in your rota",
                 "Import a spreadsheet from work, or build a repeating schedule in the app.")
            step("calendar", "See every shift",
                 "Helm turns your shift codes into real shifts — with times, breaks and pay.")
            step("arrow.triangle.2.circlepath", "Stay in sync",
                 "Your calendar updates automatically, with reminders and wake-up alarms.")
            Text("Only need part of Helm? Turn features on or off any time in Settings.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 8)
        }
    }

    // MARK: Building blocks

    private func pageScaffold<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ScrollView {
            VStack(spacing: 16) {
                Spacer(minLength: 24)
                content()
                Spacer(minLength: 24)
            }
            .frame(maxWidth: 460)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 28)
        }
    }

    private func hero(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 52, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 104, height: 104)
            .background(
                LinearGradient(colors: [theme.accent, theme.accent.opacity(0.7)],
                               startPoint: .topLeading, endPoint: .bottomTrailing),
                in: RoundedRectangle(cornerRadius: 26, style: .continuous)
            )
            .padding(.bottom, 4)
    }

    private func step(_ symbol: String, _ title: String, _ body: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(theme.accent)
                .frame(width: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(body).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
