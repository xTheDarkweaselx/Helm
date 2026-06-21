//
//  GoogleOAuth.swift
//  HelmCalendar
//
//  Pure builders for Google's OAuth 2.0 native-app flow (authorization-code +
//  PKCE, NO client secret — iOS-type clients are public clients). The app layer
//  owns the ASWebAuthenticationSession, Keychain, and token lifecycle; this file
//  is the testable protocol surface: endpoints, parameters, and PKCE math.
//
//  Verified against https://developers.google.com/identity/protocols/oauth2/native-app
//

import Foundation
import CryptoKit

public enum GoogleOAuth {
    public static let authorizationEndpoint = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    public static let tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!
    public static let revocationEndpoint = URL(string: "https://oauth2.googleapis.com/revoke")!

    /// The single calendar scope Helm needs: create its own secondary calendar
    /// and full event CRUD on it — no access to the user's other calendars.
    public static let calendarScope = "https://www.googleapis.com/auth/calendar.app.created"
    /// openid+email so Settings can show which account is signed in (id_token).
    public static let scopes = [calendarScope, "openid", "email"]

    // MARK: - Client id derivations

    /// "1234-abcd.apps.googleusercontent.com" → "com.googleusercontent.apps.1234-abcd".
    public static func reversedClientID(_ clientID: String) -> String {
        clientID.split(separator: ".").reversed().joined(separator: ".")
    }

    /// Google's custom-scheme redirect: reversed client id + ":/oauth2redirect"
    /// (a SINGLE slash — native-app custom-scheme paths differ from http URLs).
    public static func redirectURI(clientID: String) -> String {
        reversedClientID(clientID) + ":/oauth2redirect"
    }

    /// What ASWebAuthenticationSession's callback matcher needs: just the scheme.
    public static func callbackScheme(clientID: String) -> String {
        reversedClientID(clientID)
    }

    // MARK: - PKCE (RFC 7636, S256)

    public struct PKCE: Sendable {
        public let verifier: String
        public let challenge: String

        /// 64 random bytes → 86-char base64url verifier (43–128 unreserved chars allowed).
        public static func generate() -> PKCE {
            var bytes = [UInt8](repeating: 0, count: 64)
            var rng = SystemRandomNumberGenerator() // cryptographically secure on Apple platforms
            for i in bytes.indices { bytes[i] = UInt8.random(in: .min ... .max, using: &rng) }
            let verifier = base64url(Data(bytes))
            return PKCE(verifier: verifier, challenge: challenge(for: verifier))
        }

        /// S256: base64url(SHA-256(ASCII(verifier))), no padding.
        public static func challenge(for verifier: String) -> String {
            base64url(Data(SHA256.hash(data: Data(verifier.utf8))))
        }
    }

    /// CSRF state parameter (random, echoed back on the callback).
    public static func makeState() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        var rng = SystemRandomNumberGenerator()
        for i in bytes.indices { bytes[i] = UInt8.random(in: .min ... .max, using: &rng) }
        return base64url(Data(bytes))
    }

    // MARK: - Requests

    /// access_type=offline asks for a refresh token; prompt=consent forces the
    /// consent screen so Google re-issues one even on re-authorization.
    public static func authorizationURL(
        clientID: String,
        state: String,
        codeChallenge: String
    ) -> URL {
        var components = URLComponents(url: authorizationEndpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI(clientID: clientID)),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
        ]
        return components.url!
    }

    /// No client_secret: "not applicable to requests from clients registered as
    /// Android, iOS, or Chrome applications" (Google).
    public static func tokenExchangeRequest(
        clientID: String,
        code: String,
        codeVerifier: String
    ) -> URLRequest {
        formPOST(to: tokenEndpoint, fields: [
            "client_id": clientID,
            "code": code,
            "code_verifier": codeVerifier,
            "grant_type": "authorization_code",
            "redirect_uri": redirectURI(clientID: clientID),
        ])
    }

    public static func refreshRequest(clientID: String, refreshToken: String) -> URLRequest {
        formPOST(to: tokenEndpoint, fields: [
            "client_id": clientID,
            "refresh_token": refreshToken,
            "grant_type": "refresh_token",
        ])
    }

    public static func revokeRequest(token: String) -> URLRequest {
        formPOST(to: revocationEndpoint, fields: ["token": token])
    }

    /// Extract the email claim from an id_token JWT payload. Display-only
    /// (no signature verification — the token came straight from Google over TLS).
    public static func email(fromIDToken idToken: String) -> String? {
        let segments = idToken.split(separator: ".")
        guard segments.count >= 2 else { return nil }
        var base64 = String(segments[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64.append("=") }
        guard let data = Data(base64Encoded: base64),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return payload["email"] as? String
    }

    // MARK: - Encoding helpers

    static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func formPOST(to url: URL, fields: [String: String]) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(formEncode(fields).utf8)
        return request
    }

    static func formEncode(_ fields: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return fields
            .sorted { $0.key < $1.key } // deterministic for tests
            .map { key, value in
                let k = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
                let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
                return "\(k)=\(v)"
            }
            .joined(separator: "&")
    }
}
