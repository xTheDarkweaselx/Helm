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

actor GoogleAuthService: GoogleAccessTokenProviding {
    static let shared = GoogleAuthService()

    /// What's persisted in the Keychain (one JSON blob).
    private struct StoredTokens: Codable {
        var refreshToken: String
        var accessToken: String
        var expiry: Date
        var email: String?
    }

    private let keychain = KeychainStore(service: "Fusion-Studios.Helm.google-oauth", account: "google")
    private let log = Logger(subsystem: "Fusion-Studios.Helm", category: "GoogleAuth")
    private var cached: StoredTokens?
    private var refreshTask: Task<StoredTokens, Error>?
    /// Auth-header requests must never hit a shared cache.
    private let urlSession = URLSession(configuration: .ephemeral)

    // MARK: - State

    func isSignedIn() -> Bool {
        currentTokens() != nil
    }

    func accountEmail() -> String? {
        currentTokens()?.email
    }

    private func currentTokens() -> StoredTokens? {
        if let cached { return cached }
        guard let data = keychain.read(),
              let tokens = try? JSONDecoder().decode(StoredTokens.self, from: data)
        else { return nil }
        cached = tokens
        return tokens
    }

    private func store(_ tokens: StoredTokens) {
        cached = tokens
        if let data = try? JSONEncoder().encode(tokens) {
            keychain.write(data)
        }
        UserDefaults.standard.set(true, forKey: GoogleConfig.signedInDefaultsKey)
        UserDefaults.standard.set(tokens.email, forKey: GoogleConfig.accountEmailDefaultsKey)
    }

    private func clear() {
        cached = nil
        keychain.delete()
        UserDefaults.standard.set(false, forKey: GoogleConfig.signedInDefaultsKey)
        UserDefaults.standard.removeObject(forKey: GoogleConfig.accountEmailDefaultsKey)
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
        store(StoredTokens(
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
        clear()
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
        // A 401 just told us the cached token is bad regardless of its expiry.
        try await refresh(force: true).accessToken
    }

    private func refresh(force: Bool = false) async throws -> StoredTokens {
        if !force, let existing = refreshTask {
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
        refreshTask = task
        defer { refreshTask = nil }

        do {
            let refreshed = try await task.value
            store(refreshed)
            return refreshed
        } catch GoogleAuthError.reauthenticationRequired {
            // invalid_grant: the refresh token is dead — terminal until re-auth.
            clear()
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
