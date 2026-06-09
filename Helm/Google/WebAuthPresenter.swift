//
//  WebAuthPresenter.swift
//  Helm
//
//  Presents the Google sign-in page via ASWebAuthenticationSession and returns
//  the custom-scheme callback URL. ASWebAuthenticationSession intercepts the
//  redirect itself, so the reversed-client-id scheme is NOT registered in
//  CFBundleURLTypes. Cross-platform anchor (UIWindow / NSWindow).
//

import Foundation
import AuthenticationServices
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

    /// Guards against any double-resume of the continuation (completion handler
    /// vs. a false `start()`); AS delivers the completion on the main queue.
    private final class ResumeOnce: @unchecked Sendable {
        var done = false
    }

    func authenticate(url: URL, callbackScheme: String) async throws -> URL {
        defer { session = nil }
        return try await withCheckedThrowingContinuation { continuation in
            let once = ResumeOnce()
            let session = ASWebAuthenticationSession(
                url: url,
                callback: .customScheme(callbackScheme)
            ) { callbackURL, error in
                guard !once.done else { return }
                once.done = true
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
            if !session.start(), !once.done {
                once.done = true
                continuation.resume(throwing: WebAuthError.cannotPresent)
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
