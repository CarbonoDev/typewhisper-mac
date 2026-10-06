import Combine
import XCTest
@testable import TypeWhisper

/// [Perf · finding 12] `Publisher.mirror(to:_:)`: synchronous, compare-before-assign mirroring
/// between two `@MainActor` objects.
@MainActor
final class PublisherMirrorTests: XCTestCase {
    @MainActor
    private final class Source: ObservableObject {
        @Published var value = 0
    }

    @MainActor
    private final class Mirror: ObservableObject {
        @Published var value = 0
    }

    func testMirrorUpdatesSynchronously() {
        let source = Source()
        let mirror = Mirror()
        let token = source.$value.mirror(to: mirror, \.value)
        source.value = 7
        XCTAssertEqual(mirror.value, 7, "no run-loop turn between the source write and the mirror")
        withExtendedLifetime(token) {}
    }

    func testEqualValueDoesNotRepublish() {
        let source = Source()
        let mirror = Mirror()
        let token = source.$value.mirror(to: mirror, \.value)
        var publishes = 0
        let watch = mirror.objectWillChange.sink { publishes += 1 }
        source.value = 0
        source.value = 0
        XCTAssertEqual(publishes, 0)
        source.value = 1
        source.value = 1
        XCTAssertEqual(publishes, 1)
        withExtendedLifetime((token, watch)) {}
    }

    func testMirrorDoesNotRetainTheTarget() {
        let source = Source()
        var mirror: Mirror? = Mirror()
        weak let weakMirror = mirror
        let token = source.$value.mirror(to: mirror!, \.value)
        mirror = nil
        XCTAssertNil(weakMirror)
        source.value = 3   // no crash with the target gone
        withExtendedLifetime(token) {}
    }
}
