//
//  GoogleAuthService.swift
//  Helm
//
//  The Google token lifecycle: interactive sign-in (auth-code + PKCE via
//  ASWebAuthenticationSession), Keychain persistence, silent refresh with
//  coalescing, invalid_grant → forced re-auth, and sign-out (revoke + clear).
//  An actor so concurrent token() callers never trigger parallel refreshes;
//  UserDefaults mirrors (signed-in flag + email) keep synchronous UI honest.
//

import Foundation
import HelmCalendar
import OSLog

nonisolated enum GoogleAuthError: LocalizedError {
    case notConfigured
    case notSignedIn
    case stateMismatch
    case tokenExchangeFailed(String)
    case reauthenticationRequired

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            "Google isn't set up yet. Paste your Google OAuth client ID in Settings first."
        case .notSignedIn:
            "Sign in to Google in Settings, then try again."
        case .stateMismatch:
            "Sign-in failed a security check (state mismatch). Please try again."
        case let .tokenExchangeFailed(detail):
            "Google sign-in failed: \(detail)"
        case .reauthenticationRequired:
            "Your Google sign-in has expired or was revoked. Sign in again in Settings."
        }
    }
}

/// What's persisted in the Keychain (one JSON blob).
///
/// File-scope and explicitly `nonisolated`: it is encoded/decoded ON the
/// GoogleAuthService actor's executor (a background thread). Under the app
/// target's default-MainActor isolation, a type nested in the actor gets a
/// MainActor-isolated synthesized Codable conformance — JSONEncoder/Decoder
/// then trip a runtime isolation assertion (EXC_BREAKPOINT) off the main
/// thread: crashed at sign-in (first encode) and at every launch once tokens
/// existed (reconcileMirror's first decode).
nonisolated private struct StoredTokens: Codable, Sendable {
    var refreshToken: String
    var accessToken: String
    var expiry: Date
    var email: String?
}

actor GoogleAuthService: GoogleAccessTokenProviding {
    static let shared = GoogleAuthService()

    private let keychain = KeychainStore(service: "Fusion-Studios.Helm.google-oauth", account: "google")
    private let log = Logger(subsystem: "Fusion-Studios.Helm", category: "GoogleAuth")
    private var cached: StoredTokens?
    private var refreshTask: Task<StoredTokens, Error>?
    /// Guards refreshTask cleanup under actor reentrancy: a finished refresh must
    /// never nil out a NEWER in-flight task another caller is joined on.
    private var refreshGeneration = 0
    private var lastRefreshCompletedAt: Date = .distantPast
    /// Auth-header requests must never hit a shared cache.
    private let urlSession = URLSession(configuration: .ephemeral)

    // MARK: - State

    func isSignedIn() -> Bool {
        currentTokens() != nil
    }

    func accountEmail() -> String? {
        currentTokens()?.email
    }

    /// Re-align the synchronous UserDefaults mirrors with the Keychain truth.
    /// Called at launch: the Keychain survives reinstalls while UserDefaults
    /// doesn't (and vice-versa desyncs would hard-fail or hide the feature).
    func reconcileMirror() async {
        let tokens = currentTokens()
        await Self.setMirror(signedIn: tokens != nil, email: tokens?.email)
    }

    /// The ONLY writer of the sign-in mirror keys, pinned to the main actor:
    /// UserDefaults delivers KVO synchronously on the CALLING thread, and these
    /// keys feed live @AppStorage observers in SettingsForm — an off-main write
    /// from this actor's executor invalidates SwiftUI off the main thread.
    @MainActor
    private static func setMirror(signedIn: Bool, email: String?) {
        UserDefaults.standard.set(signedIn, forKey: GoogleConfig.signedInDefaultsKey)
        if let email {
            UserDefaults.standard.set(email, forKey: GoogleConfig.accountEmailDefaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: GoogleConfig.accountEmailDefaultsKey)
        }
    }

    private func currentTokens() -> StoredTokens? {
        if let cached { return cached }
        guard let data = keychain.read(),
              let tokens = try? JSONDecoder().decode(StoredTokens.self, from: data)
        else { return nil }
        cached = tokens
        return tokens
    }

    private func store(_ tokens: StoredTokens) async {
        cached = tokens
        if let data = try? JSONEncoder().encode(tokens) {
            keychain.write(data)
        }
        await Self.setMirror(signedIn: true, email: tokens.email)
    }

    private func clear() async {
        cached = nil
        keychain.delete()
        await Self.setMirror(signedIn: false, email: nil)
    }

    // MARK: - Interactive sign-in

    func signIn() async throws {
        let clientID = GoogleConfig.clientID
        guard GoogleConfig.isConfigured else { throw GoogleAuthError.notConfigured }

        let pkce = GoogleOAuth.PKCE.generate()
        let state = GoogleOAuth.makeState()
        let authURL = GoogleOAuth.authorizationURL(clientID: clientID, state: state, codeChallenge: pkce.challenge)
        let scheme = GoogleOAuth.callbackScheme(clientID: clientID)

        let presenter = await MainActor.run { WebAuthPresenter() }
        let callback = try await presenter.authenticate(url: authURL, callbackScheme: scheme)

        guard let components = URLComponents(url: callback, resolvingAgainstBaseURL: false) else {
            throw WebAuthError.invalidCallback
        }
        var params: [String: String] = [:]
        for item in components.queryItems ?? [] { params[item.name] = item.value }
        if let error = params["error"] {
            throw GoogleAuthError.tokenExchangeFailed(error)
        }
        guard params["state"] == state else { throw GoogleAuthError.stateMismatch }
        guard let code = params["code"] else { throw WebAuthError.invalidCallback }

        let request = GoogleOAuth.tokenExchangeRequest(clientID: clientID, code: code, codeVerifier: pkce.verifier)
        let response = try await performTokenRequest(request)
        guard let refreshToken = response.refreshToken else {
            // Shouldn't happen with access_type=offline + prompt=consent.
            throw GoogleAuthError.tokenExchangeFailed("Google did not return a refresh token. Remove Helm from your Google account's third-party access list and sign in again.")
        }
        // Granular consent lets the user untick the calendar permission yet still
        // complete sign-in — without this scope every calendar call would 403.
        guard response.scope?.contains(GoogleOAuth.calendarScope) == true else {
            _ = try? await urlSession.data(for: GoogleOAuth.revokeRequest(token: refreshToken))
            throw GoogleAuthError.tokenExchangeFailed("Helm needs the Google Calendar permission. Sign in again and keep the calendar checkbox ticked.")
        }
        // Replacing an existing session: revoke the old grant so it doesn't
        // linger authorized-but-untracked in the user's Google account.
        if let previous = currentTokens(), previous.refreshToken != refreshToken {
            _ = try? await urlSession.data(for: GoogleOAuth.revokeRequest(token: previous.refreshToken))
        }
        await store(StoredTokens(
            refreshToken: refreshToken,
            accessToken: response.accessToken,
            expiry: Date.now.addingTimeInterval(TimeInterval(response.expiresIn)),
            email: response.idToken.flatMap(GoogleOAuth.email(fromIDToken:))
        ))
        log.info("Google sign-in succeeded")
    }

    func signOut() async {
        if let tokens = currentTokens() {
            // Best-effort revocation (revoking the refresh token kills the grant).
            let request = GoogleOAuth.revokeRequest(token: tokens.refreshToken)
            _ = try? await urlSession.data(for: request)
        }
        await clear()
        log.info("Google signed out")
    }

    // MARK: - GoogleAccessTokenProviding

    func validAccessToken() async throws -> String {
        guard let tokens = currentTokens() else { throw GoogleAuthError.notSignedIn }
        if tokens.expiry > Date.now.addingTimeInterval(120) {
            return tokens.accessToken
        }
        return try await refresh().accessToken
    }

    func refreshedAccessToken() async throws -> String {
        // A 401 just told us the caller's token is bad regardless of expiry.
        // Several concurrent requests can all 401 at once (GoogleCalendarTarget
        // runs 4-wide): if a refresh completed moments ago, the first caller
        // already fixed the token — hand the others the fresh one instead of
        // hammering the token endpoint with redundant refreshes.
        if Date.now.timeIntervalSince(lastRefreshCompletedAt) < 10, let tokens = currentTokens() {
            return tokens.accessToken
        }
        return try await refresh().accessToken
    }

    /// Single-flight: every caller joins the in-flight refresh; the cleanup is
    /// generation-guarded so a finishing task never clears a newer one.
    private func refresh() async throws -> StoredTokens {
        if let existing = refreshTask {
            return try await existing.value
        }
        guard let tokens = currentTokens() else { throw GoogleAuthError.notSignedIn }
        let clientID = GoogleConfig.clientID
        guard GoogleConfig.isConfigured else { throw GoogleAuthError.notConfigured }

        let task = Task<StoredTokens, Error> {
            let request = GoogleOAuth.refreshRequest(clientID: clientID, refreshToken: tokens.refreshToken)
            let response = try await performTokenRequest(request)
            return StoredTokens(
                // Google usually omits refresh_token on refresh: keep the old one.
                refreshToken: response.refreshToken ?? tokens.refreshToken,
                accessToken: response.accessToken,
                expiry: Date.now.addingTimeInterval(TimeInterval(response.expiresIn)),
                email: response.idToken.flatMap(GoogleOAuth.email(fromIDToken:)) ?? tokens.email
            )
        }
        refreshGeneration += 1
        let generation = refreshGeneration
        refreshTask = task
        defer {
            if refreshGeneration == generation { refreshTask = nil }
        }

        do {
            let refreshed = try await task.value
            await store(refreshed)
            lastRefreshCompletedAt = .now
            return refreshed
        } catch GoogleAuthError.reauthenticationRequired {
            // invalid_grant: the refresh token is dead — terminal until re-auth.
            await clear()
            throw GoogleAuthError.reauthenticationRequired
        }
    }

    private func performTokenRequest(_ request: URLRequest) async throws -> GoogleTokenResponse {
        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GoogleAuthError.tokenExchangeFailed("no response")
        }
        if http.statusCode == 200 {
            do {
                return try JSONDecoder().decode(GoogleTokenResponse.self, from: data)
            } catch {
                throw GoogleAuthError.tokenExchangeFailed("unreadable token response")
            }
        }
        let body = try? JSONDecoder().decode(GoogleOAuthErrorBody.self, from: data)
        if body?.error == "invalid_grant" {
            throw GoogleAuthError.reauthenticationRequired
        }
        throw GoogleAuthError.tokenExchangeFailed(body?.errorDescription ?? body?.error ?? "HTTP \(http.statusCode)")
    }
}
