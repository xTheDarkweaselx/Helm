//
//  OnboardingView.swift
//  Helm
//
//  v9 first-run welcome guide: a short paged tour (what Helm does → how to use it
//  → pick an appearance → accessibility). Shown once on first launch, gated by
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

    func body(content: Content) -> some View {
        #if os(iOS)
        content.fullScreenCover(isPresented: $isPresented) { OnboardingView(onFinish: onFinish) }
        #else
        content.sheet(isPresented: $isPresented) { OnboardingView(onFinish: onFinish) }
        #endif
    }
}

struct OnboardingView: View {
    /// Called when the user finishes or skips — the host sets the completed flag.
    let onFinish: () -> Void

    @Environment(ThemeManager.self) private var theme
    @AppStorage(A11ySettings.reduceTransparencyKey) private var reduceTransparency = false
    @State private var page = 0

    private let lastPage = 3 // Welcome, How, Appearance, Accessibility

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
                appearancePage.tag(2)
                accessibilityPage.tag(3)
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .always))
            #else
            Group {
                switch page {
                case 0: welcomePage
                case 1: howItWorksPage
                case 2: appearancePage
                default: accessibilityPage
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transition(.opacity)
            #endif

            Button(page == lastPage ? "Get started" : "Continue") {
                if page == lastPage { onFinish() }
                else { withAnimation { page += 1 } }
            }
            .buttonStyle(.borderedProminent)
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
        }
    }

    private var appearancePage: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                Text("Make it yours")
                    .font(.title.weight(.bold))
                Text("Pick a look — you can change it any time in Settings.")
                    .font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 8)
            .padding(.horizontal, 24)

            Form { ThemePickerSection() }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
        }
    }

    private var accessibilityPage: some View {
        pageScaffold {
            hero("accessibility")
            Text("Comfort & accessibility")
                .font(.title.weight(.bold))
            Text("Helm follows your device's text size, bold text and reduce-motion settings. You can also flatten its glass effects here for extra legibility.")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 8)

            // Live preview card — toggling the switch flattens it immediately.
            VStack(alignment: .leading, spacing: 4) {
                Text("Sample card").font(.headline)
                Text("This is how surfaces look with your current setting.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .glassCard()

            Toggle("Reduce transparency", isOn: $reduceTransparency)
                .padding(14)
                .glassCard()
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
