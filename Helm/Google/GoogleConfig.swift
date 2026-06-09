//
//  GoogleConfig.swift
//  Helm
//
//  The Google feature's single activation switch: an OAuth client ID (type
//  "iOS", no secret — PKCE public client). Read from Info.plist
//  (HelmGoogleClientID) or, more conveniently, pasted into Settings
//  (UserDefaults). Everything Google-related stays hidden until this is set.
//

import Foundation

// nonisolated: read from both the UI (main actor) and GoogleAuthService (its
// own actor) under the app target's default-MainActor isolation.
nonisolated enum GoogleConfig {
    static let infoPlistKey = "HelmGoogleClientID"
    static let defaultsKey = "googleClientID"

    /// Mirrors written by GoogleAuthService so synchronous UI/settings code can
    /// see sign-in state without hopping to the actor.
    static let signedInDefaultsKey = "googleSignedIn"
    static let accountEmailDefaultsKey = "googleAccountEmail"

    static var clientID: String {
        let plist = (Bundle.main.object(forInfoDictionaryKey: infoPlistKey) as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !plist.isEmpty { return plist }
        return UserDefaults.standard.string(forKey: defaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// Light shape check: a real native client ID always carries this suffix,
    /// and the reversed-id redirect scheme is derived from it.
    static var isConfigured: Bool {
        clientID.hasSuffix(".apps.googleusercontent.com")
    }

    static var isSignedIn: Bool {
        UserDefaults.standard.bool(forKey: signedInDefaultsKey)
    }

    static var accountEmail: String? {
        UserDefaults.standard.string(forKey: accountEmailDefaultsKey)
    }
}
