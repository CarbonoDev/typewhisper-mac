import Foundation

extension MeetingService {
    /// A caption session that was marked `.interrupted` is live again the moment its bridge is
    /// heard from. Launch recovery no longer interrupts caption sessions, but a meeting flipped by
    /// an earlier build (or by hand) would otherwise stay out of presence — and without the
    /// floating call controls — until the user hangs up, while its captions keep arriving.
    /// Returns whether the meeting was revived.
    @discardableResult
    func resumeInterruptedCaptionSession(id: UUID) -> Bool {
        guard let meeting = meetings.first(where: { $0.id == id }),
              meeting.state == .interrupted, meeting.externalSessionKey != nil else {
            return false
        }
        meeting.state = .live
        update(meeting)
        return true
    }
}
