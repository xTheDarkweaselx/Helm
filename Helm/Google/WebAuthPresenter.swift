//
//  WebAuthPresenter.swift
//  Helm
//
//  Presents the Google sign-in page via ASWebAuthenticationSession and returns
//  the custom-scheme callback URL. ASWebAuthenticationSession intercepts the
//  redirect itself, so the reversed-client-id scheme is NOT registered in
//  CFBundleURLTypes. Cross-platform anchor (UIWindow / NSWindow).
//
//  CONCURRENCY: on macOS the session's completion handler is invoked on a
//  BACKGROUND XPC queue (iOS delivers it on main). The handler must therefore
//  be @Sendable/non-isolated — a MainActor-inferred closure traps with an
//  SE-0423 isolation assertion (EXC_BREAKPOINT) the instant consent completes.
//  CheckedContinuation.resume is documented thread-safe, so we resume directly;
//  the once-guard is a real Mutex because the completion (XPC queue) and a
//  failed start() (main thread) genuinely race.
//

import Foundation
import AuthenticationServices
import Synchronization
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

enum WebAuthError: LocalizedError {
    case cancelled
    case cannotPresent
    case invalidCallback

    var errorDescription: String? {
        switch self {
        case .cancelled: "Sign-in was cancelled."
        case .cannotPresent: "Couldn't open the sign-in window. Try again from Settings."
        case .invalidCallback: "Google returned an unexpected sign-in response."
        }
    }
}

@MainActor
final class WebAuthPresenter: NSObject, ASWebAuthenticationPresentationContextProviding {
    /// Strong reference: the session is deallocated (and the sheet dismissed)
    /// if nothing retains it while the user is signing in.
    private var session: ASWebAuthenticationSession?

    /// Thread-safe single-resume guard for the continuation. Explicitly
    /// nonisolated: nesting in a @MainActor class would otherwise isolate
    /// claim() to the main actor — reintroducing the XPC-queue assertion.
    nonisolated private final class ResumeOnce: Sendable {
        private let claimed = Mutex(false)
        /// True exactly once, for whichever caller gets here first.
        func claim() -> Bool {
            claimed.withLock { done in
                if done { return false }
                done = true
                return true
            }
        }
    }

    func authenticate(url: URL, callbackScheme: String) async throws -> URL {
        defer { session = nil }
        return try await withCheckedThrowingContinuation { continuation in
            let once = ResumeOnce()
            let session = ASWebAuthenticationSession(
                url: url,
                callback: .customScheme(callbackScheme)
            ) { @Sendable callbackURL, error in
                // Runs on a background XPC queue on macOS — keep non-isolated.
                guard once.claim() else { return }
                if let callbackURL {
                    continuation.resume(returning: callbackURL)
                } else if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                    continuation.resume(throwing: WebAuthError.cancelled)
                } else {
                    continuation.resume(throwing: error ?? WebAuthError.invalidCallback)
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false // keep Google SSO cookies
            self.session = session
            if !session.start(), once.claim() {
                continuation.resume(throwing: WebAuthError.cannotPresent)
                self.session = nil
            }
        }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        #if canImport(UIKit)
        let window = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }
            .first
        return window ?? ASPresentationAnchor()
        #elseif canImport(AppKit)
        return NSApplication.shared.keyWindow ?? NSApplication.shared.mainWindow ?? ASPresentationAnchor()
        #endif
    }
}
