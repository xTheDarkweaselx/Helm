//
//  GoogleAPIModels.swift
//  HelmCalendar
//
//  Codable value types for the Google Calendar API v3 (the subset Helm uses).
//  Pure data — no networking — so the event mapping is unit-testable.
//

import Foundation

/// A Google Calendar event (insert/update body and list item).
public struct GoogleEvent: Codable, Equatable, Sendable {
    public struct Time: Codable, Equatable, Sendable {
        /// All-day events: "yyyy-MM-dd". Exclusive on `end` (Google convention).
        public var date: String?
        /// Timed events: RFC 3339 instant (Helm emits UTC "Z").
        public var dateTime: String?
        /// IANA zone the event should render in (timed events only).
        public var timeZone: String?

        public init(date: String? = nil, dateTime: String? = nil, timeZone: String? = nil) {
            self.date = date
            self.dateTime = dateTime
            self.timeZone = timeZone
        }
    }

    public struct ReminderOverride: Codable, Equatable, Sendable {
        public var method: String
        public var minutes: Int

        public init(method: String, minutes: Int) {
            self.method = method
            self.minutes = minutes
        }
    }

    public struct Reminders: Codable, Equatable, Sendable {
        public var useDefault: Bool
        public var overrides: [ReminderOverride]?

        public init(useDefault: Bool, overrides: [ReminderOverride]? = nil) {
            self.useDefault = useDefault
            self.overrides = overrides
        }
    }

    public struct ExtendedProperties: Codable, Equatable, Sendable {
        /// Visible only to this app's OAuth client — Helm's idempotency marker.
        public var `private`: [String: String]?

        public init(private privateProperties: [String: String]? = nil) {
            self.private = privateProperties
        }
    }

    /// Settable only at insert; base32hex (a–v, 0–9), 5–1024 chars, unique per calendar.
    public var id: String?
    /// "confirmed" resurrects a previously-deleted (cancelled) id on update.
    public var status: String?
    public var summary: String?
    public var location: String?
    public var description: String?
    public var start: Time?
    public var end: Time?
    public var reminders: Reminders?
    public var extendedProperties: ExtendedProperties?

    public init(
        id: String? = nil,
        status: String? = nil,
        summary: String? = nil,
        location: String? = nil,
        description: String? = nil,
        start: Time? = nil,
        end: Time? = nil,
        reminders: Reminders? = nil,
        extendedProperties: ExtendedProperties? = nil
    ) {
        self.id = id
        self.status = status
        self.summary = summary
        self.location = location
        self.description = description
        self.start = start
        self.end = end
        self.reminders = reminders
        self.extendedProperties = extendedProperties
    }
}

/// One page of events.list.
public struct GoogleEventListPage: Decodable, Sendable {
    public var items: [GoogleEvent]?
    public var nextPageToken: String?
}

/// A calendar resource (calendars.insert/get).
public struct GoogleCalendarResource: Codable, Sendable {
    public var id: String?
    public var summary: String?

    public init(id: String? = nil, summary: String? = nil) {
        self.id = id
        self.summary = summary
    }
}

/// One page of calendarList.list.
public struct GoogleCalendarListPage: Decodable, Sendable {
    public struct Entry: Decodable, Sendable {
        public var id: String?
        public var summary: String?
        public var accessRole: String?
    }

    public var items: [Entry]?
    public var nextPageToken: String?
}

/// Google's standard error envelope: {"error": {"code", "message", "errors": [{"reason"}]}}.
public struct GoogleErrorEnvelope: Decodable, Sendable {
    public struct Body: Decodable, Sendable {
        public struct Item: Decodable, Sendable {
            public var reason: String?
        }

        public var code: Int?
        public var message: String?
        public var errors: [Item]?
    }

    public var error: Body?
}

/// OAuth token endpoint response (exchange and refresh).
public struct GoogleTokenResponse: Decodable, Sendable {
    public var accessToken: String
    public var expiresIn: Int
    /// Present on first consent (and when prompt=consent); absent on most refreshes.
    public var refreshToken: String?
    public var scope: String?
    /// JWT carrying the email claim when "openid email" scopes were granted.
    public var idToken: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case expiresIn = "expires_in"
        case refreshToken = "refresh_token"
        case scope
        case idToken = "id_token"
    }
}

/// OAuth token endpoint error body, e.g. {"error": "invalid_grant"}.
public struct GoogleOAuthErrorBody: Decodable, Sendable {
    public var error: String?
    public var errorDescription: String?

    enum CodingKeys: String, CodingKey {
        case error
        case errorDescription = "error_description"
    }
}
