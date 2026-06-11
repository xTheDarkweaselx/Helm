//
//  GoogleAdapterTests.swift
//  HelmCalendarTests
//
//  The pure Google layer: deterministic event ids (base32hex), draft→event
//  mapping (timed, all-day exclusive end, reminders, idempotency markers),
//  PKCE (RFC 7636 vector), and OAuth/list request shapes.
//

import Foundation
import Testing
@testable import HelmCalendar

// MARK: - base32hex + event id

@Suite struct GoogleEventIDTests {
    // RFC 4648 §10 test vectors (base32hex), lowercased, padding stripped.
    @Test func base32hexMatchesRFC4648Vectors() {
        #expect(GoogleEventMapper.base32hex(Data("".utf8)) == "")
        #expect(GoogleEventMapper.base32hex(Data("f".utf8)) == "co")
        #expect(GoogleEventMapper.base32hex(Data("fo".utf8)) == "cpng")
        #expect(GoogleEventMapper.base32hex(Data("foo".utf8)) == "cpnmu")
        #expect(GoogleEventMapper.base32hex(Data("foob".utf8)) == "cpnmuog")
        #expect(GoogleEventMapper.base32hex(Data("fooba".utf8)) == "cpnmuoj1")
        #expect(GoogleEventMapper.base32hex(Data("foobar".utf8)) == "cpnmuoj1e8")
    }

    @Test func eventIDIsValidGoogleID() {
        let id = GoogleEventMapper.eventID(for: "2026-06-09|Europe/London|M")
        // "helm" prefix is itself base32hex-legal; SHA-256 → 52 base32hex chars.
        #expect(id.count == 56)
        #expect(id.hasPrefix("helm"))
        let allowed = Set("0123456789abcdefghijklmnopqrstuv")
        #expect(id.allSatisfy { allowed.contains($0) })
    }

    @Test func eventIDIsDeterministicAndCollisionFree() {
        let a = GoogleEventMapper.eventID(for: "2026-06-09|Europe/London|M")
        #expect(a == GoogleEventMapper.eventID(for: "2026-06-09|Europe/London|M"))
        // Full-hash ids: near-identical keys (and the long generated "g:" scope
        // keys that motivated dropping prefix-truncation) must not collide.
        #expect(a != GoogleEventMapper.eventID(for: "2026-06-09|Europe/London|A"))
        let g1 = GoogleEventMapper.eventID(for: "2026-06-09|Europe/London|g:sched1234extra:M")
        let g2 = GoogleEventMapper.eventID(for: "2026-06-09|Europe/London|g:sched1234other:M")
        #expect(g1 != g2)
    }
}

// MARK: - Draft → GoogleEvent mapping

@Suite struct GoogleEventMappingTests {
    private func draft(
        start: Date = Date(timeIntervalSince1970: 1_780_986_600), // 2026-06-09 06:30:00 UTC
        end: Date = Date(timeIntervalSince1970: 1_781_011_800),   // 2026-06-09 13:30:00 UTC
        isAllDay: Bool = false,
        alarms: [Int] = [60]
    ) -> CalendarEventDraft {
        CalendarEventDraft(
            dedupKey: "2026-06-09|Europe/London|M",
            title: "Morning",
            location: "UEC",
            start: start,
            end: end,
            timeZoneIdentifier: "Europe/London",
            isAllDay: isAllDay,
            alarmOffsetsMinutes: alarms,
            contentHash: "h"
        )
    }

    @Test func timedEventCarriesInstantAndZone() {
        let event = GoogleEventMapper.event(for: draft())
        #expect(event.start?.dateTime == "2026-06-09T06:30:00Z")
        #expect(event.end?.dateTime == "2026-06-09T13:30:00Z")
        #expect(event.start?.timeZone == "Europe/London")
        #expect(event.start?.date == nil && event.end?.date == nil)
        #expect(event.status == "confirmed")
        #expect(event.summary == "Morning")
        #expect(event.location == "UEC")
    }

    @Test func allDayDatesUseTheDraftZoneNotUTC() {
        // REGRESSION (v6 hardening): a London-midnight all-day start during BST
        // is 23:00Z the PREVIOUS day — UTC formatting shipped TBC days one day
        // early to Google/.ics. 2026-06-08T23:00Z == 2026-06-09 00:00 London.
        let londonMidnight = Date(timeIntervalSince1970: 1_780_959_600)
        let event = GoogleEventMapper.event(for: draft(start: londonMidnight, end: londonMidnight, isAllDay: true, alarms: []))
        #expect(event.start?.date == "2026-06-09")
        #expect(event.end?.date == "2026-06-10")
    }

    @Test func allDayEventUsesExclusiveEndDate() {
        // Single all-day on 2026-06-09 (inclusive internal end) → end.date 06-10.
        let day = Date(timeIntervalSince1970: 1_780_963_200) // 2026-06-09 00:00 UTC
        let event = GoogleEventMapper.event(for: draft(start: day, end: day, isAllDay: true, alarms: []))
        #expect(event.start?.date == "2026-06-09")
        #expect(event.end?.date == "2026-06-10")
        #expect(event.start?.dateTime == nil && event.end?.dateTime == nil)
        #expect(event.start?.timeZone == nil)
    }

    @Test func allDayExclusiveEndMatchesICSExporterConvention() {
        // Both exporters must agree on the same draft (shared UTC convention).
        let end = Date(timeIntervalSince1970: 1_780_963_200 + 9_000) // 02:30 into the day
        let google = GoogleEventMapper.allDayEndExclusive(end, timeZoneID: "Europe/London")
        let ics = ICSExporter.allDayEndExclusive(end, timeZoneID: "Europe/London")
        #expect(google == ics)
    }

    @Test func remindersMapToPopupOverrides() {
        let event = GoogleEventMapper.event(for: draft(alarms: [60]))
        #expect(event.reminders?.useDefault == false)
        #expect(event.reminders?.overrides == [.init(method: "popup", minutes: 60)])

        let none = GoogleEventMapper.event(for: draft(alarms: []))
        #expect(none.reminders?.useDefault == false)
        #expect(none.reminders?.overrides == nil)

        // Clamped to Google's 0...40320 and capped at 5 overrides.
        let wild = GoogleEventMapper.event(for: draft(alarms: [-5, 99_999, 1, 2, 3, 4, 5]))
        #expect(wild.reminders?.overrides?.count == 5)
        #expect(wild.reminders?.overrides?.first == .init(method: "popup", minutes: 0))
        #expect(wild.reminders?.overrides?[1] == .init(method: "popup", minutes: 40_320))
    }

    @Test func idempotencyMarkersAreStamped() {
        let event = GoogleEventMapper.event(for: draft())
        #expect(event.id == GoogleEventMapper.eventID(for: "2026-06-09|Europe/London|M"))
        #expect(event.extendedProperties?.private?["helmSource"] == "helm")
        #expect(event.extendedProperties?.private?["helmKey"] == "2026-06-09|Europe/London|M")
        #expect(event.description?.contains("[helm:2026-06-09|Europe/London|M]") == true)
    }
}

// MARK: - OAuth / PKCE

@Suite struct GoogleOAuthTests {
    @Test func pkceMatchesRFC7636Vector() {
        // RFC 7636 Appendix B.
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        #expect(GoogleOAuth.PKCE.challenge(for: verifier) == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    @Test func generatedPKCEIsWellFormed() {
        let pkce = GoogleOAuth.PKCE.generate()
        #expect((43...128).contains(pkce.verifier.count))
        var unreserved = CharacterSet.alphanumerics
        unreserved.insert(charactersIn: "-._~")
        #expect(pkce.verifier.unicodeScalars.allSatisfy { unreserved.contains($0) })
        #expect(pkce.challenge == GoogleOAuth.PKCE.challenge(for: pkce.verifier))
        // Two generations must differ (random).
        #expect(GoogleOAuth.PKCE.generate().verifier != pkce.verifier)
    }

    @Test func reversedClientIDAndRedirect() {
        let id = "1234-abcd.apps.googleusercontent.com"
        #expect(GoogleOAuth.reversedClientID(id) == "com.googleusercontent.apps.1234-abcd")
        // Single slash after the colon — Google's documented native-app format.
        #expect(GoogleOAuth.redirectURI(clientID: id) == "com.googleusercontent.apps.1234-abcd:/oauth2redirect")
        #expect(GoogleOAuth.callbackScheme(clientID: id) == "com.googleusercontent.apps.1234-abcd")
    }

    @Test func authorizationURLCarriesAllRequiredParams() throws {
        let url = GoogleOAuth.authorizationURL(
            clientID: "1234-abcd.apps.googleusercontent.com",
            state: "st4te",
            codeChallenge: "ch4llenge"
        )
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.host == "accounts.google.com")
        var params: [String: String] = [:]
        for item in components.queryItems ?? [] { params[item.name] = item.value }
        #expect(params["client_id"] == "1234-abcd.apps.googleusercontent.com")
        #expect(params["redirect_uri"] == "com.googleusercontent.apps.1234-abcd:/oauth2redirect")
        #expect(params["response_type"] == "code")
        #expect(params["scope"]?.contains("calendar.app.created") == true)
        #expect(params["scope"]?.contains("email") == true)
        #expect(params["code_challenge"] == "ch4llenge")
        #expect(params["code_challenge_method"] == "S256")
        #expect(params["state"] == "st4te")
        // Without these two, Google won't (reliably) issue a refresh token.
        #expect(params["access_type"] == "offline")
        #expect(params["prompt"] == "consent")
    }

    @Test func tokenExchangeHasNoClientSecret() throws {
        let request = GoogleOAuth.tokenExchangeRequest(
            clientID: "1234-abcd.apps.googleusercontent.com",
            code: "c0de",
            codeVerifier: "v3rifier"
        )
        #expect(request.httpMethod == "POST")
        #expect(request.url == GoogleOAuth.tokenEndpoint)
        let body = String(decoding: try #require(request.httpBody), as: UTF8.self)
        #expect(body.contains("grant_type=authorization_code"))
        #expect(body.contains("code=c0de"))
        #expect(body.contains("code_verifier=v3rifier"))
        #expect(!body.contains("client_secret"))
    }

    @Test func refreshKeepsGrantAndOmitsSecret() throws {
        let request = GoogleOAuth.refreshRequest(clientID: "x.apps.googleusercontent.com", refreshToken: "r1")
        let body = String(decoding: try #require(request.httpBody), as: UTF8.self)
        #expect(body.contains("grant_type=refresh_token"))
        #expect(body.contains("refresh_token=r1"))
        #expect(!body.contains("client_secret"))
    }

    @Test func emailParsesFromIDToken() {
        // Header.payload.signature with payload {"email":"a@b.com"} (base64url, no padding).
        let payload = GoogleOAuth.base64url(Data(#"{"email":"a@b.com"}"#.utf8))
        #expect(GoogleOAuth.email(fromIDToken: "eyJh.\(payload).sig") == "a@b.com")
        #expect(GoogleOAuth.email(fromIDToken: "garbage") == nil)
    }
}

// MARK: - API URL shapes

@Suite struct GoogleCalendarURLTests {
    @Test func helmEventsListEncodesMarkerFilter() {
        let url = GoogleCalendarTarget.helmEventsListURL(calendarID: "cal1", pageToken: nil)
        let s = url.absoluteString
        // The '=' between key and value MUST be %3D or Google misparses the filter.
        #expect(s.contains("privateExtendedProperty=helmSource%3Dhelm"))
        #expect(s.contains("/calendars/cal1/events"))
        #expect(s.contains("maxResults=2500"))

        let paged = GoogleCalendarTarget.helmEventsListURL(calendarID: "cal1", pageToken: "tok=en")
        #expect(paged.absoluteString.contains("pageToken=tok%3Den"))
    }

    @Test func eventURLTargetsDeterministicID() {
        let id = GoogleEventMapper.eventID(for: "k")
        let url = GoogleCalendarTarget.eventURL(calendarID: "cal1", eventID: id)
        #expect(url.absoluteString == "https://www.googleapis.com/calendar/v3/calendars/cal1/events/\(id)")
    }
}

@Suite struct GoogleRetryClassificationTests {
    @Test func retriesRateAndQuotaAndServerErrors() {
        // The classic machine reasons.
        #expect(GoogleCalendarTarget.isRetryable(status: 403, reason: "rateLimitExceeded", message: "Rate Limit Exceeded"))
        #expect(GoogleCalendarTarget.isRetryable(status: 403, reason: "userRateLimitExceeded", message: "x"))
        #expect(GoogleCalendarTarget.isRetryable(status: 403, reason: "quotaExceeded", message: "x"))
        // 429 + 5xx always.
        #expect(GoogleCalendarTarget.isRetryable(status: 429, reason: nil, message: ""))
        #expect(GoogleCalendarTarget.isRetryable(status: 503, reason: nil, message: ""))
    }

    @Test func retriesA403RateLimitWithNoMachineReason() {
        // The field-hit case: 403 with only the human message, no `reason`.
        #expect(GoogleCalendarTarget.isRetryable(status: 403, reason: nil, message: "Rate Limit Exceeded"))
    }

    @Test func doesNotRetryRealPermissionDenials() {
        #expect(!GoogleCalendarTarget.isRetryable(status: 403, reason: "insufficientPermissions", message: "Insufficient Permission"))
        #expect(!GoogleCalendarTarget.isRetryable(status: 404, reason: nil, message: "Not Found"))
        #expect(!GoogleCalendarTarget.isRetryable(status: 400, reason: "badRequest", message: "Bad Request"))
    }
}
