import XCTest
@testable import TypeWhisper

/// `GoogleCalendarProvider` over a canned snapshot and an ephemeral account store (§7): overlap
/// filtering, the `events(around:window:)` protocol-extension default, and authorization status
/// derived from account state (D-G7). No sync engine, no network — the snapshot seam is a closure.
@MainActor
final class GoogleCalendarProviderTests: XCTestCase {
    private final class InMemorySecretStore: GoogleSecretStoring {
        private var secrets: [String: String] = [:]
        func save(_ secret: String, service: String) throws { secrets[service] = secret }
        func load(service: String) -> String? { secrets[service] }
        func delete(service: String) throws { secrets[service] = nil }
        func deleteAll(prefix: String) throws {
            secrets = secrets.filter { !$0.key.hasPrefix(prefix) }
        }
    }

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "GoogleCalendarProviderTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        try await super.tearDown()
    }

    // MARK: - Fixtures

    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeStore(statuses: [GoogleAccountStatus]) throws -> GoogleAccountStore {
        let store = GoogleAccountStore(defaults: defaults, secretStore: InMemorySecretStore())
        for (index, status) in statuses.enumerated() {
            try store.upsert(
                GoogleAccount(
                    id: "sub-\(index)",
                    email: "user\(index)@example.com",
                    displayName: nil,
                    grantedScopes: ["openid"],
                    connectedAt: base,
                    statusRaw: status.rawValue
                ),
                refreshToken: "rt-\(index)"
            )
        }
        return store
    }

    private func event(_ id: String, startOffset: TimeInterval, endOffset: TimeInterval) -> CalendarEventDTO {
        CalendarEventDTO(
            id: id,
            title: "Event \(id)",
            startDate: base.addingTimeInterval(startOffset),
            endDate: base.addingTimeInterval(endOffset),
            calendarName: "Work",
            calendarID: "google:sub-0:work",
            calendarColor: .fallback
        )
    }

    private func cannedSnapshot() -> [GoogleCalendarSyncEngine.CalendarEvents] {
        let calendar = CalendarInfo(
            id: "google:sub-0:work",
            title: "Work",
            sourceName: "user0@example.com",
            color: .fallback
        )
        return [
            GoogleCalendarSyncEngine.CalendarEvents(
                calendar: calendar,
                events: [
                    event("before", startOffset: -7200, endOffset: -3600), // ends before the window
                    event("overlapsStart", startOffset: -1800, endOffset: 1800), // straddles window start
                    event("inside", startOffset: 3600, endOffset: 5400),
                    event("after", startOffset: 90_000, endOffset: 93_600), // starts after the window
                ]
            ),
        ]
    }

    private func makeProvider(
        statuses: [GoogleAccountStatus],
        snapshot: [GoogleCalendarSyncEngine.CalendarEvents]
    ) throws -> GoogleCalendarProvider {
        let store = try makeStore(statuses: statuses)
        return GoogleCalendarProvider(accountStore: store, snapshot: { snapshot })
    }

    // MARK: - Authorization status (D-G7)

    func testAuthorizedWithAtLeastOneConnectedAccount() throws {
        let provider = try makeProvider(statuses: [.needsReauth, .connected], snapshot: [])
        XCTAssertEqual(provider.authorizationStatus, .authorized)
    }

    func testNotDeterminedWithNoAccounts() throws {
        let provider = try makeProvider(statuses: [], snapshot: [])
        XCTAssertEqual(provider.authorizationStatus, .notDetermined)
    }

    func testNotDeterminedWhenEveryAccountNeedsReauth() throws {
        let provider = try makeProvider(statuses: [.needsReauth], snapshot: cannedSnapshot())
        XCTAssertEqual(provider.authorizationStatus, .notDetermined)
        XCTAssertTrue(
            provider.events(from: base.addingTimeInterval(-86_400), to: base.addingTimeInterval(86_400)).isEmpty,
            "auth loss clears events (D-G4), mirroring EventKit-denied"
        )
        XCTAssertTrue(provider.calendars().isEmpty)
    }

    func testRequestAccessIsANoOpReturningCurrentStatus() async throws {
        let provider = try makeProvider(statuses: [.connected], snapshot: [])
        let status = await provider.requestAccess()
        XCTAssertEqual(status, .authorized, "no system permission to prompt for")
    }

    // MARK: - Overlap filtering

    func testEventsReturnsOnlyWindowOverlaps() throws {
        let provider = try makeProvider(statuses: [.connected], snapshot: cannedSnapshot())
        let events = provider.events(from: base, to: base.addingTimeInterval(86_400))
        XCTAssertEqual(
            events.map(\.id),
            ["overlapsStart", "inside"],
            "an event straddling the window start overlaps; fully-outside events do not"
        )
    }

    func testEventsAroundWindowDefaultViaProtocolExtension() throws {
        let provider = try makeProvider(statuses: [.connected], snapshot: cannedSnapshot())
        // ±2h around base: picks up the straddler and the fully-before event (its end at −3600 is
        // inside), but not the far-future one.
        let events = (provider as CalendarEventProviding).events(around: base, window: 2 * 3600)
        XCTAssertEqual(events.map(\.id), ["before", "overlapsStart", "inside"])
    }

    // MARK: - Calendars

    func testCalendarsServedFromSnapshot() throws {
        let provider = try makeProvider(statuses: [.connected], snapshot: cannedSnapshot())
        XCTAssertEqual(provider.calendars().map(\.id), ["google:sub-0:work"])
        XCTAssertEqual(provider.calendars().first?.sourceName, "user0@example.com")
    }
}
