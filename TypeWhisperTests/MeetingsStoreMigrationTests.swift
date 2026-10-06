import XCTest
import SwiftData
@testable import TypeWhisper

/// The `meetings.store` schema must only ever grow additively: `SwiftDataStoreFactory` deletes a
/// store it cannot open, so a removed, renamed, or retyped column — or a new required one — would
/// silently drop every meeting. These tests pin the live schema against the frozen
/// `MeetingsSchemaV1` baseline and prove a V1-written store reopens with every row intact.
@MainActor
final class MeetingsStoreMigrationTests: XCTestCase {
    private var liveModels: [any PersistentModel.Type] {
        [Meeting.self, MeetingSegment.self, MeetingNote.self, MeetingOutput.self, MeetingQATurn.self, MeetingTemplate.self]
    }

    func testLiveSchemaIsAnAdditiveSupersetOfV1() {
        let baseline = Dictionary(uniqueKeysWithValues: Schema(MeetingsSchemaV1.models).entities.map { ($0.name, $0) })
        let live = Dictionary(uniqueKeysWithValues: Schema(liveModels).entities.map { ($0.name, $0) })
        XCTAssertEqual(Set(baseline.keys), Set(live.keys), "entities are never added to or removed from meetings.store here")

        for (name, old) in baseline {
            guard let new = live[name] else { continue }
            let newAttributes = Dictionary(uniqueKeysWithValues: new.attributes.map { ($0.name, $0) })
            for attribute in old.attributes {
                guard let current = newAttributes[attribute.name] else {
                    XCTFail("\(name).\(attribute.name) was removed or renamed")
                    continue
                }
                XCTAssertEqual(
                    String(describing: current.valueType), String(describing: attribute.valueType),
                    "\(name).\(attribute.name) was retyped"
                )
                XCTAssertEqual(current.isOptional, attribute.isOptional, "\(name).\(attribute.name) changed optionality")
            }
            let oldNames = Set(old.attributes.map(\.name))
            for attribute in new.attributes where !oldNames.contains(attribute.name) {
                XCTAssertTrue(
                    attribute.isOptional || attribute.defaultValue != nil,
                    "new column \(name).\(attribute.name) must be optional or defaulted"
                )
            }
            XCTAssertEqual(
                Set(new.relationships.map(\.name)), Set(old.relationships.map(\.name)),
                "\(name) relationships changed"
            )
        }
    }

    func testV1StoreOpensUnderTheLiveSchemaWithEveryRowIntact() throws {
        let dir = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(dir) }
        let firstID = UUID()
        let secondID = UUID()

        try autoreleasepool {
            let config = ModelConfiguration(url: dir.appendingPathComponent("meetings.store"))
            let container = try ModelContainer(for: Schema(MeetingsSchemaV1.models), configurations: [config])
            let context = ModelContext(container)
            let first = MeetingsSchemaV1.Meeting(id: firstID, title: "Weekly", startDate: Date(timeIntervalSince1970: 1_700_000_000))
            let second = MeetingsSchemaV1.Meeting(id: secondID, title: "Empty", startDate: nil)
            context.insert(first)
            context.insert(second)
            for index in 0..<3 {
                context.insert(MeetingsSchemaV1.MeetingSegment(
                    order: index, start: Double(index), end: Double(index) + 1.5,
                    text: "line \(index)", speakerLabel: index == 0 ? "SPEAKER_00" : "SPEAKER_01", meeting: first
                ))
            }
            context.insert(MeetingsSchemaV1.MeetingOutput(kindRaw: "summary", content: "# Summary", meeting: first))
            context.insert(MeetingsSchemaV1.MeetingNote(text: "note", meeting: first))
            context.insert(MeetingsSchemaV1.MeetingQATurn(question: "q", answer: "a", meeting: first))
            try context.save()
        }

        let service = MeetingService(appSupportDirectory: dir)
        XCTAssertEqual(Set(service.meetings.map(\.id)), [firstID, secondID], "the store was reset")
        let first = try XCTUnwrap(service.meetings.first { $0.id == firstID })
        XCTAssertEqual(first.title, "Weekly")
        XCTAssertEqual(first.segments.sorted { $0.order < $1.order }.map(\.text), ["line 0", "line 1", "line 2"])
        XCTAssertEqual(first.outputs.map(\.kind), [.summary])
        XCTAssertEqual(first.notes.count, 1)
        XCTAssertEqual(first.qaTurns.count, 1)
        let second = try XCTUnwrap(service.meetings.first { $0.id == secondID })
        XCTAssertTrue(second.segments.isEmpty)
    }
}
