//
//  GoogleCalendarTarget.swift
//  HelmCalendar
//
//  Google Calendar adapter for the CalendarTarget protocol — URLSession + Codable
//  only, no SDK. Mirrors the EventKit adapter's model: a dedicated "Helm Shifts"
//  secondary calendar (created with the minimal calendar.app.created scope) and
//  idempotent upserts keyed by a deterministic event id derived from the dedupKey.
//
//  Write semantics: insert-first (new events are the common case after a diff);
//  409 means the id exists (possibly cancelled) → full PUT replacement with
//  status=confirmed, which also resurrects previously-deleted ids. A hard
//  per-event failure THROWS (after retries) rather than returning a .failed
//  result, because RosterSyncEngine's contract is throw → SwiftData rollback;
//  idempotent upserts make the whole batch safe to re-apply.
//

import Foundation

/// The app-side OAuth service vends tokens through this seam, keeping token
/// lifecycle (Keychain, refresh, re-auth) out of the network layer.
public protocol GoogleAccessTokenProviding: Sendable {
    /// A currently-valid access token (refreshing silently if needed).
    func validAccessToken() async throws -> String
    /// Force a refresh after a 401; returns the new token.
    func refreshedAccessToken() async throws -> String
}

public enum GoogleCalendarError: Error, LocalizedError, Sendable {
    case api(status: Int, reason: String?, message: String)
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case let .api(status, _, message):
            "Google Calendar error (\(status)): \(message)"
        case .invalidResponse:
            "Google Calendar returned an unreadable response."
        }
    }
}

public actor GoogleCalendarTarget: CalendarTarget {
    public nonisolated let kind = "google"

    public static let calendarTitle = "Helm Shifts"
    /// UserDefaults key persisting the app-created calendar's id across launches.
    public static let calendarIDDefaultsKey = "googleHelmCalendarID"

    private static let apiBase = URL(string: "https://www.googleapis.com/calendar/v3")!
    private static let maxConcurrentRequests = 4
    private static let maxAttempts = 5

    private let tokens: any GoogleAccessTokenProviding
    private let session: URLSession
    private var cachedCalendarID: String?

    public init(tokens: any GoogleAccessTokenProviding) {
        self.tokens = tokens
        // Ephemeral: never write responses to a shared on-disk cache while every
        // request carries an Authorization header.
        self.session = URLSession(configuration: .ephemeral)
    }

    // MARK: - CalendarTarget

    @discardableResult
    public func write(_ drafts: [CalendarEventDraft]) async throws -> [CalendarWriteResult] {
        guard !drafts.isEmpty else { return [] }
        let calendarID = try await ensureCalendar()

        var results = [CalendarWriteResult?](repeating: nil, count: drafts.count)
        try await withThrowingTaskGroup(of: (Int, CalendarWriteResult).self) { group in
            var inFlight = 0
            for (index, draft) in drafts.enumerated() {
                if inFlight >= Self.maxConcurrentRequests {
                    if let (i, result) = try await group.next() {
                        results[i] = result
                        inFlight -= 1
                    }
                }
                group.addTask {
                    (index, try await self.upsert(draft, calendarID: calendarID))
                }
                inFlight += 1
            }
            for try await (i, result) in group {
                results[i] = result
            }
        }
        return results.compactMap { $0 }
    }

    @discardableResult
    public func remove(dedupKeys: [String]) async throws -> Int {
        guard !dedupKeys.isEmpty, let calendarID = try await resolveExistingCalendar() else { return 0 }
        var removed = 0
        try await withThrowingTaskGroup(of: Bool.self) { group in
            var inFlight = 0
            for key in dedupKeys {
                if inFlight >= Self.maxConcurrentRequests {
                    if let didRemove = try await group.next() {
                        if didRemove { removed += 1 }
                        inFlight -= 1
                    }
                }
                group.addTask {
                    try await self.delete(eventID: GoogleEventMapper.eventID(for: key), calendarID: calendarID)
                }
                inFlight += 1
            }
            for try await didRemove in group where didRemove {
                removed += 1
            }
        }
        return removed
    }

    @discardableResult
    public func removeAll() async throws -> Int {
        guard let calendarID = try await resolveExistingCalendar() else { return 0 }
        // Find every Helm-written event via the private marker property, paged.
        // (List right after a bulk insert can lag; removeAll is a cleanup path,
        // not the hot path — re-running it converges.)
        var ids: [String] = []
        var pageToken: String?
        repeat {
            let url = Self.helmEventsListURL(calendarID: calendarID, pageToken: pageToken)
            let (data, _) = try await send(makeRequest("GET", url: url))
            let page = try Self.decode(GoogleEventListPage.self, from: data)
            ids.append(contentsOf: (page.items ?? []).compactMap(\.id))
            pageToken = page.nextPageToken
        } while pageToken != nil

        var removed = 0
        for id in ids {
            if try await delete(eventID: id, calendarID: calendarID) { removed += 1 }
        }
        return removed
    }

    // MARK: - Per-event operations

    private nonisolated func upsert(_ draft: CalendarEventDraft, calendarID: String) async throws -> CalendarWriteResult {
        let event = GoogleEventMapper.event(for: draft)
        let eventID = event.id ?? GoogleEventMapper.eventID(for: draft.dedupKey)
        let body = try JSONEncoder().encode(event)
        do {
            _ = try await send(makeRequest("POST", url: Self.eventsURL(calendarID: calendarID), body: body))
            return CalendarWriteResult(dedupKey: draft.dedupKey, action: .added, eventIdentifier: eventID)
        } catch let GoogleCalendarError.api(status, _, _) where status == 409 {
            // The id already exists (live or cancelled): full replacement.
            _ = try await send(makeRequest("PUT", url: Self.eventURL(calendarID: calendarID, eventID: eventID), body: body))
            return CalendarWriteResult(dedupKey: draft.dedupKey, action: .updated, eventIdentifier: eventID)
        }
    }

    /// True when the event was deleted now; false when it was already gone (404/410).
    private nonisolated func delete(eventID: String, calendarID: String) async throws -> Bool {
        do {
            _ = try await send(makeRequest("DELETE", url: Self.eventURL(calendarID: calendarID, eventID: eventID)))
            return true
        } catch let GoogleCalendarError.api(status, _, _) where status == 404 || status == 410 {
            return false
        }
    }

    // MARK: - Calendar resolution

    /// Find or create the dedicated "Helm Shifts" calendar.
    func ensureCalendar() async throws -> String {
        if let id = try await resolveExistingCalendar() { return id }
        let body = try JSONEncoder().encode(GoogleCalendarResource(summary: Self.calendarTitle))
        let (data, _) = try await send(makeRequest("POST", url: Self.apiBase.appendingPathComponent("calendars"), body: body))
        let created = try Self.decode(GoogleCalendarResource.self, from: data)
        guard let id = created.id else { throw GoogleCalendarError.invalidResponse }
        cachedCalendarID = id
        UserDefaults.standard.set(id, forKey: Self.calendarIDDefaultsKey)
        return id
    }

    /// The existing Helm calendar if there is one — never creates (removal paths
    /// must not conjure a calendar just to find nothing to remove in it).
    private func resolveExistingCalendar() async throws -> String? {
        if let id = cachedCalendarID { return id }

        // 1. The persisted id, verified (the user may have deleted the calendar).
        if let stored = UserDefaults.standard.string(forKey: Self.calendarIDDefaultsKey) {
            do {
                _ = try await send(makeRequest("GET", url: Self.apiBase.appendingPathComponent("calendars/\(stored)")))
                cachedCalendarID = stored
                return stored
            } catch let GoogleCalendarError.api(status, _, _) where status == 404 || status == 410 {
                UserDefaults.standard.removeObject(forKey: Self.calendarIDDefaultsKey)
            }
        }

        // 2. calendarList lookup by title (e.g. after a reinstall — app.created
        //    scope still sees calendars this OAuth client created). A 403 here
        //    just means the scope can't list; fall through to "none".
        do {
            var pageToken: String?
            repeat {
                let url = Self.calendarListURL(pageToken: pageToken)
                let (data, _) = try await send(makeRequest("GET", url: url))
                let page = try Self.decode(GoogleCalendarListPage.self, from: data)
                if let match = (page.items ?? []).first(where: { $0.summary == Self.calendarTitle && $0.id != nil }) {
                    cachedCalendarID = match.id
                    UserDefaults.standard.set(match.id, forKey: Self.calendarIDDefaultsKey)
                    return match.id
                }
                pageToken = page.nextPageToken
            } while pageToken != nil
        } catch let GoogleCalendarError.api(status, _, _) where status == 403 {
            // Scope doesn't permit listing; the caller will create if needed.
        }
        return nil
    }

    // MARK: - URL building (internal static for tests)

    static func eventsURL(calendarID: String) -> URL {
        apiBase.appendingPathComponent("calendars/\(calendarID)/events")
    }

    static func eventURL(calendarID: String, eventID: String) -> URL {
        apiBase.appendingPathComponent("calendars/\(calendarID)/events/\(eventID)")
    }

    /// events.list filtered to Helm's marker. The '=' inside the param VALUE must
    /// be percent-encoded (privateExtendedProperty=helmSource%3Dhelm), so the
    /// query is assembled percent-encoded by hand rather than via URLQueryItem.
    static func helmEventsListURL(calendarID: String, pageToken: String?) -> URL {
        var components = URLComponents(url: eventsURL(calendarID: calendarID), resolvingAgainstBaseURL: false)!
        var query = "privateExtendedProperty=\(GoogleEventMapper.sourceMarkerKey)%3D\(GoogleEventMapper.sourceMarkerValue)"
        query += "&maxResults=2500&showDeleted=false"
        if let pageToken {
            var allowed = CharacterSet.alphanumerics
            allowed.insert(charactersIn: "-._~")
            query += "&pageToken=\(pageToken.addingPercentEncoding(withAllowedCharacters: allowed) ?? pageToken)"
        }
        components.percentEncodedQuery = query
        return components.url!
    }

    static func calendarListURL(pageToken: String?) -> URL {
        var components = URLComponents(url: apiBase.appendingPathComponent("users/me/calendarList"), resolvingAgainstBaseURL: false)!
        var items = [URLQueryItem(name: "minAccessRole", value: "writer"), URLQueryItem(name: "maxResults", value: "250")]
        if let pageToken { items.append(URLQueryItem(name: "pageToken", value: pageToken)) }
        components.queryItems = items
        return components.url!
    }

    // MARK: - Transport with auth + retry

    private nonisolated func makeRequest(_ method: String, url: URL, body: Data? = nil) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    /// Single chokepoint: injects the bearer token, refreshes once on 401, and
    /// retries 403-rate/429/5xx with exponential backoff + full jitter
    /// (honouring Retry-After). Never retries other 4xx.
    private nonisolated func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        var token = try await tokens.validAccessToken()
        var didRefresh = false
        var attempt = 0

        while true {
            attempt += 1
            var authed = request
            authed.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

            let (data, response) = try await session.data(for: authed)
            guard let http = response as? HTTPURLResponse else { throw GoogleCalendarError.invalidResponse }

            if (200..<300).contains(http.statusCode) { return (data, http) }

            let envelope = try? Self.decode(GoogleErrorEnvelope.self, from: data)
            let reason = envelope?.error?.errors?.first?.reason
            let message = envelope?.error?.message ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            let error = GoogleCalendarError.api(status: http.statusCode, reason: reason, message: message)

            if http.statusCode == 401, !didRefresh {
                token = try await tokens.refreshedAccessToken()
                didRefresh = true
                continue
            }

            let isRateLimited = http.statusCode == 429
                || (http.statusCode == 403 && (reason == "rateLimitExceeded" || reason == "userRateLimitExceeded"))
            let isServerError = (500..<600).contains(http.statusCode)
            guard (isRateLimited || isServerError), attempt < Self.maxAttempts else { throw error }

            let retryAfter = (http.value(forHTTPHeaderField: "Retry-After")).flatMap(Double.init)
            let backoff = retryAfter ?? Double.random(in: 0...(0.5 * pow(2, Double(attempt - 1))))
            try await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
        }
    }

    private static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw GoogleCalendarError.invalidResponse
        }
    }
}
