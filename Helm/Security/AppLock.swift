//
//  AppLock.swift
//  Helm
//
//  Optional biometric / passcode gate (iOS/iPadOS). When the user turns on
//  "Require Face ID" in Settings, the app is covered by a lock screen on cold
//  launch and whenever it leaves the foreground, until they authenticate with
//  Face ID / Touch ID — falling back to the DEVICE PASSCODE. We use
//  `.deviceOwnerAuthentication`, so Helm never stores a secret of its own: the
//  OS owns both the biometric check and the passcode fallback.
//
//  iOS-only on purpose: SwiftUI scenePhase has well-defined .inactive/.background
//  transitions on iOS (so we can cover content BEFORE the app-switcher snapshot),
//  whereas a macOS WindowGroup rarely reaches .background, which would make the
//  "locks when you return to it" promise hollow. Shift rosters can be sensitive,
//  so this keeps a borrowed phone out of them. See [[watch-companion-wiring]].
//

import SwiftUI

#if os(iOS)
import LocalAuthentication

enum AppLockSetting {
    /// Canonical UserDefaults key (also bound via @AppStorage in Settings).
    static let enabledKey = "requireAppLock"
    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    /// Whether biometric/passcode auth is even possible on this device.
    static var canAuthenticate: Bool {
        var err: NSError?
        return LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: &err)
    }

    /// Device biometry name for labels ("Face ID" / "Touch ID" / "Optic ID"),
    /// or "passcode" when there's no enrolled biometry.
    static var biometryLabel: String {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
        switch context.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        default: return "passcode"
        }
    }
}

@MainActor
@Observable
final class AppLock {
    /// True once the app has left the foreground and demands re-authentication.
    /// (Distinct from a transient cover — see AppLockGate.covered.)
    private(set) var isLocked: Bool
    /// A prompt is in flight — guards against stacking evaluatePolicy calls.
    private(set) var isAuthenticating = false
    /// Last user-facing failure (empty = nothing to show, e.g. a plain cancel).
    private(set) var lastError: String = ""

    init() {
        // Cold launch starts locked iff the feature is on, so it demands auth
        // before any shift is visible.
        isLocked = AppLockSetting.isEnabled
    }

    /// Demand authentication — called when the app leaves the foreground or the
    /// user turns the feature on.
    func lock() {
        if AppLockSetting.isEnabled { isLocked = true }
    }

    /// Prompt for Face ID / passcode. No-op when disabled, already unlocked, or
    /// a prompt is already showing.
    func authenticate() async {
        guard AppLockSetting.isEnabled, isLocked, !isAuthenticating else { return }
        isAuthenticating = true
        defer { isAuthenticating = false }

        let context = LAContext()
        // Hide the custom fallback button — `.deviceOwnerAuthentication` already
        // offers the system passcode path after a biometric failure.
        context.localizedFallbackTitle = ""
        do {
            let ok = try await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: "Unlock Helm to view your shifts."
            )
            if ok {
                isLocked = false
                lastError = ""
            }
        } catch {
            lastError = (error as? LAError)?.helmMessage ?? "Couldn't unlock. Try again."
        }
    }
}

private extension LAError {
    /// "" = a benign cancel we shouldn't surface; otherwise a short message.
    var helmMessage: String {
        switch code {
        case .userCancel, .appCancel, .systemCancel: return ""
        case .biometryNotEnrolled, .passcodeNotSet:
            return "Set up \(AppLockSetting.biometryLabel) or a device passcode first."
        case .biometryLockout:
            return "\(AppLockSetting.biometryLabel) is locked — use your passcode."
        default: return "Couldn't unlock. Try again."
        }
    }
}

/// Wraps the app's content and covers it whenever the lock is engaged OR the app
/// is not active. Covering on EVERY non-active phase (not just `.background`) is
/// what keeps the shift roster out of the app-switcher snapshot and the
/// Control-Center / notification-shade peek — iOS captures those at `.inactive`,
/// before `.background`. Authentication is only demanded when the app actually
/// left the foreground (`isLocked`); a transient `.inactive` cover lifts by
/// itself on return without a Face ID prompt.
struct AppLockGate<Content: View>: View {
    @AppStorage(AppLockSetting.enabledKey) private var enabled = false
    @Environment(\.scenePhase) private var scenePhase
    @State private var lock = AppLock()
    @ViewBuilder var content: Content

    /// Cover the UI while locked, or any time we're not the active foreground app.
    private var covered: Bool { enabled && (lock.isLocked || scenePhase != .active) }

    var body: some View {
        ZStack {
            // Disable + hide from accessibility/focus so the roster isn't
            // reachable via VoiceOver or a hardware keyboard behind the cover.
            content
                .disabled(covered)
                .accessibilityHidden(covered)
            if covered {
                LockScreen(lock: lock, showsUnlock: lock.isLocked)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: covered)
        .task { if enabled && lock.isLocked { await lock.authenticate() } }
        .onChange(of: enabled) { _, on in
            // Turning it on takes effect at once, rather than waiting for the
            // next backgrounding.
            if on { lock.lock(); Task { await lock.authenticate() } }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                lock.lock()
            case .active:
                if enabled && lock.isLocked { Task { await lock.authenticate() } }
            default:
                break
            }
        }
    }
}

private struct LockScreen: View {
    let lock: AppLock
    /// Show the unlock button only when truly locked — a transient `.inactive`
    /// cover (Control Center peek) shouldn't flash an unlock prompt.
    let showsUnlock: Bool

    var body: some View {
        ZStack {
            // Opaque, not translucent: the roster must be ILLEGIBLE behind the
            // cover, including in the app-switcher thumbnail.
            Rectangle().fill(.background).ignoresSafeArea()
            Rectangle().fill(.ultraThinMaterial).ignoresSafeArea()
            if showsUnlock {
                VStack(spacing: 16) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 42))
                        .foregroundStyle(.secondary)
                    Text("Helm is locked").font(.headline)
                    Button {
                        Task { await lock.authenticate() }
                    } label: {
                        Label("Unlock with \(AppLockSetting.biometryLabel)",
                              systemImage: AppLockSetting.biometryLabel == "Touch ID" ? "touchid" : "faceid")
                            .padding(.horizontal, 8)
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(lock.isAuthenticating)
                    if !lock.lastError.isEmpty {
                        Text(lock.lastError)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding(40)
            } else {
                Image(systemName: "lock.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

#else

/// Non-iOS: no app lock (scenePhase backgrounding semantics differ). Passthrough
/// so HelmApp can wrap the scene unconditionally.
struct AppLockGate<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View { content }
}

#endif
