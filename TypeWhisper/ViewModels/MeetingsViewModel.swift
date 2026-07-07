import Foundation
import Combine

@MainActor
final class MeetingsViewModel: ObservableObject {
    nonisolated(unsafe) static var _shared: MeetingsViewModel?
    static var shared: MeetingsViewModel {
        guard let instance = _shared else {
            fatalError("MeetingsViewModel not initialized")
        }
        return instance
    }

    @Published private(set) var meetings: [Meeting] = []

    private let meetingService: MeetingService
    private var cancellables = Set<AnyCancellable>()

    init(meetingService: MeetingService) {
        self.meetingService = meetingService
        self.meetings = meetingService.meetings
        meetingService.$meetings
            .receive(on: DispatchQueue.main)
            .sink { [weak self] meetings in
                self?.meetings = meetings
            }
            .store(in: &cancellables)
    }

    var hasMeetings: Bool { !meetings.isEmpty }

    #if DEBUG
    func seedDemoMeeting() {
        meetingService.seedDemoMeeting()
    }
    #endif
}
