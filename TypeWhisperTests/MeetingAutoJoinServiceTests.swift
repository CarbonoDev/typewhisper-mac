import XCTest
@testable import TypeWhisper

/// `MeetingAutoJoinService`: opens a starting calendar meeting's join link once, inside
/// [start − lead, start + trail], and never while the user is already in a meeting.
@MainActor
final class MeetingAutoJoinServiceTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private let joinLink = "https://meet.example.com/abc-defg-hij"
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var opened: [(url: URL, accountSub: String?)] = []
    private var inMeeting = false

    override func setUp() {
        super.setUp()
        suiteName = "MeetingAutoJoinServiceTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        opened = []
        inMeeting = false
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    private func makeService() -> MeetingAutoJoinService {
        MeetingAutoJoinService(
            defaults: defaults,
            isInMeeting: { [unowned self] in self.inMeeting },
            opener: { [unowned self] url, sub in self.opened.append((url, sub)) }
        )
    }

    private func event(
        id: String = "evt-1",
        allDay: Bool = false,
        link: String? = "https://meet.example.com/abc-defg-hij",
        attendees: [Attendee] = []
    ) -> CalendarEventDTO {
        CalendarEventDTO(
            id: id,
            title: "Weekly Sync",
            startDate: start,
            endDate: start.addingTimeInterval(1800),
            isAllDay: allDay,
            attendees: attendees,
            conferencingURL: link
        )
    }

    // MARK: - Window

    func testOpensOnceInsideTheWindow() {
        let service = makeService()
        service.openStartingMeetings([event()], now: start.addingTimeInterval(-30))
        service.openStartingMeetings([event()], now: start.addingTimeInterval(10))
        XCTAssertEqual(opened.count, 1)
        XCTAssertEqual(opened.first?.url.absoluteString, joinLink)
    }

    func testDoesNotOpenBeforeTheLead() {
        // Default lead is 1 minute.
        let service = makeService()
        service.openStartingMeetings([event()], now: start.addingTimeInterval(-61))
        XCTAssertTrue(opened.isEmpty)
    }

    func testCustomLeadOpensEarlier() {
        defaults.set(5, forKey: UserDefaultsKeys.meetingsAutoJoinLeadMinutes)
        let service = makeService()
        service.openStartingMeetings([event()], now: start.addingTimeInterval(-290))
        XCTAssertEqual(opened.count, 1)
    }

    func testZeroLeadWaitsForTheStart() {
        defaults.set(0, forKey: UserDefaultsKeys.meetingsAutoJoinLeadMinutes)
        let service = makeService()
        service.openStartingMeetings([event()], now: start.addingTimeInterval(-5))
        XCTAssertTrue(opened.isEmpty)
        service.openStartingMeetings([event()], now: start)
        XCTAssertEqual(opened.count, 1)
    }

    func testDoesNotOpenAfterTheTrail() {
        let service = makeService()
        service.openStartingMeetings([event()], now: start.addingTimeInterval(MeetingAutoJoinService.trailWindow + 1))
        XCTAssertTrue(opened.isEmpty)
    }

    func testOpensWithinTheTrailGrace() {
        let service = makeService()
        service.openStartingMeetings([event()], now: start.addingTimeInterval(MeetingAutoJoinService.trailWindow - 1))
        XCTAssertEqual(opened.count, 1)
    }

    // MARK: - Qualification

    func testSkipsAllDayEvents() {
        let service = makeService()
        service.openStartingMeetings([event(allDay: true)], now: start)
        XCTAssertTrue(opened.isEmpty)
    }

    func testSkipsEventsWithoutAJoinLink() {
        let service = makeService()
        service.openStartingMeetings([event(link: nil)], now: start)
        XCTAssertTrue(opened.isEmpty)
    }

    func testSkipsNonHTTPJoinLinks() {
        let service = makeService()
        service.openStartingMeetings([event(link: "file:///tmp/x")], now: start)
        XCTAssertTrue(opened.isEmpty)
    }

    func testSkipsEventsTheUserDeclined() {
        let me = Attendee(name: "Me", email: "me@example.com", isSelf: true, responseStatusRaw: "declined")
        let service = makeService()
        service.openStartingMeetings([event(attendees: [me])], now: start)
        XCTAssertTrue(opened.isEmpty)
    }

    func testOpensWhenSomeoneElseDeclined() {
        let other = Attendee(name: "Other", email: "other@example.com", isSelf: false, responseStatusRaw: "declined")
        let service = makeService()
        service.openStartingMeetings([event(attendees: [other])], now: start)
        XCTAssertEqual(opened.count, 1)
    }

    func testPassesTheGoogleAccountSub() {
        let service = makeService()
        let id = GoogleCalendarID.eventID(sub: "sub-123", raw: "e1")
        service.openStartingMeetings([event(id: id)], now: start)
        XCTAssertEqual(opened.first?.accountSub, "sub-123")
    }

    // MARK: - Presence

    func testDoesNotOpenWhileInAMeetingAndRetriesAfterwards() {
        let service = makeService()
        inMeeting = true
        service.openStartingMeetings([event()], now: start)
        XCTAssertTrue(opened.isEmpty)
        inMeeting = false
        service.openStartingMeetings([event()], now: start.addingTimeInterval(30))
        XCTAssertEqual(opened.count, 1)
    }

    // MARK: - Persistence and setting

    func testPersistedIDsSurviveANewInstance() {
        makeService().openStartingMeetings([event()], now: start)
        XCTAssertEqual(opened.count, 1)
        makeService().openStartingMeetings([event()], now: start.addingTimeInterval(20))
        XCTAssertEqual(opened.count, 1)
    }

    func testPersistedIDsAreCapped() {
        let service = makeService()
        let count = MeetingAutoJoinService.persistedIDLimit + 5
        service.openStartingMeetings((0..<count).map { event(id: "evt-\($0)") }, now: start)
        XCTAssertEqual(opened.count, count)
        let stored = defaults.stringArray(forKey: UserDefaultsKeys.meetingsAutoJoinOpenedEventIDs) ?? []
        XCTAssertEqual(stored.count, MeetingAutoJoinService.persistedIDLimit)
        XCTAssertEqual(stored.last, "evt-\(count - 1)")
    }

    func testDisabledSettingOpensNothing() {
        defaults.set(false, forKey: UserDefaultsKeys.meetingsAutoJoinEnabled)
        let service = makeService()
        service.openStartingMeetings([event()], now: start)
        XCTAssertTrue(opened.isEmpty)
    }

    func testConsumerWindowFollowsTheLeadSetting() {
        defaults.set(2, forKey: UserDefaultsKeys.meetingsAutoJoinLeadMinutes)
        let window = MeetingAutoJoinService.consumerWindow(defaults: defaults)
        XCTAssertEqual(window.lead, 120)
        XCTAssertEqual(window.trail, MeetingAutoJoinService.trailWindow)
    }
}
