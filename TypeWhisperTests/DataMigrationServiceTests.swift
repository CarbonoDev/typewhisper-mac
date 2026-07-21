import Foundation
import XCTest
@testable import TypeWhisper

/// Deterministic, seam-injected tests for ``DataMigrationService``. No test touches the real
/// filesystem, `UserDefaults`, or Keychain — every step runs against in-memory fakes.
final class DataMigrationServiceTests: XCTestCase {

    // MARK: - Fakes

    private final class FakeFileSystem: MigrationFileSystem {
        /// Directory paths that "exist".
        var existing: Set<String>
        /// Subset of `existing` that are empty directories.
        var empty: Set<String>
        var throwOnMove = false
        private(set) var moveCalls: [(String, String)] = []
        private(set) var removeCalls: [String] = []

        init(existing: Set<String> = [], empty: Set<String> = []) {
            self.existing = existing
            self.empty = empty
        }

        func fileExists(at url: URL) -> Bool { existing.contains(url.path) }

        func isDirectoryEmpty(at url: URL) -> Bool { empty.contains(url.path) }

        func moveItem(at src: URL, to dst: URL) throws {
            moveCalls.append((src.path, dst.path))
            if throwOnMove { throw FakeError.move }
            existing.remove(src.path)
            existing.insert(dst.path)
            if empty.remove(src.path) != nil { empty.insert(dst.path) }
        }

        func removeItem(at url: URL) throws {
            removeCalls.append(url.path)
            existing.remove(url.path)
            empty.remove(url.path)
        }
    }

    private final class FakeDefaults: MigrationDefaults {
        var domains: [String: [String: Any]]
        private(set) var setCalls: [String] = []

        init(domains: [String: [String: Any]] = [:]) { self.domains = domains }

        func persistentDomain(forName name: String) -> [String: Any]? { domains[name] }

        func setPersistentDomain(_ domain: [String: Any], forName name: String) {
            setCalls.append(name)
            domains[name] = domain
        }
    }

    private final class FakeKeychain: MigrationKeychain {
        var items: [String: Data]
        var throwOnEnumerate = false
        /// Service names whose read should throw.
        var unreadable: Set<String>
        private(set) var writes: [String] = []

        init(items: [String: Data] = [:], unreadable: Set<String> = []) {
            self.items = items
            self.unreadable = unreadable
        }

        func servicesWithPrefix(_ prefix: String) throws -> [String] {
            if throwOnEnumerate { throw FakeError.enumerate }
            return items.keys.filter { $0.hasPrefix(prefix) }.sorted()
        }

        func secretExists(service: String) -> Bool { items[service] != nil }

        func readSecret(service: String) throws -> Data {
            if unreadable.contains(service) { throw FakeError.read }
            guard let data = items[service] else { throw FakeError.read }
            return data
        }

        func writeSecret(_ data: Data, service: String) throws {
            writes.append(service)
            items[service] = data
        }
    }

    private enum FakeError: Error { case move, enumerate, read }

    // MARK: - Fixtures

    private let base = URL(fileURLWithPath: "/fake/Application Support", isDirectory: true)
    private var src: URL { base.appendingPathComponent("TypeWhisper", isDirectory: true) }
    private var dst: URL { base.appendingPathComponent("MeetingWhisper", isDirectory: true) }

    private let oldDomain = "com.typewhisper.mac"
    private let newDomain = "com.meetingwhisper.mac"
    private let oldPrefix = "com.typewhisper.mac.apikey."
    private let newPrefix = "com.meetingwhisper.mac.apikey."

    // MARK: - Step A: app-support directory

    func testFreshInstall_noOp_andDoesNotCreateNewDirectory() throws {
        let fs = FakeFileSystem() // both absent
        let moved = try DataMigrationService.migrateAppSupport(src: src, dst: dst, fileSystem: fs)
        XCTAssertFalse(moved)
        XCTAssertTrue(fs.moveCalls.isEmpty)
        XCTAssertFalse(fs.existing.contains(dst.path), "migration must not create the new directory")
    }

    func testHappyPath_movesSourceToDestinationOnce() throws {
        let fs = FakeFileSystem(existing: [src.path]) // old present, non-empty; new absent
        let moved = try DataMigrationService.migrateAppSupport(src: src, dst: dst, fileSystem: fs)
        XCTAssertTrue(moved)
        XCTAssertEqual(fs.moveCalls.count, 1)
        XCTAssertEqual(fs.moveCalls.first?.0, src.path)
        XCTAssertEqual(fs.moveCalls.first?.1, dst.path)
        XCTAssertTrue(fs.existing.contains(dst.path))
        XCTAssertFalse(fs.existing.contains(src.path))
    }

    func testIdempotent_destinationAlreadyPopulated_noMove() throws {
        let fs = FakeFileSystem(existing: [src.path, dst.path]) // dst present + non-empty
        let first = try DataMigrationService.migrateAppSupport(src: src, dst: dst, fileSystem: fs)
        let second = try DataMigrationService.migrateAppSupport(src: src, dst: dst, fileSystem: fs)
        XCTAssertFalse(first)
        XCTAssertFalse(second)
        XCTAssertTrue(fs.moveCalls.isEmpty)
        XCTAssertTrue(fs.existing.contains(src.path), "old data left intact when new already exists")
    }

    func testEmptyPlaceholderDestination_removedThenSourceMovedIn() throws {
        let fs = FakeFileSystem(existing: [src.path, dst.path], empty: [dst.path])
        let moved = try DataMigrationService.migrateAppSupport(src: src, dst: dst, fileSystem: fs)
        XCTAssertTrue(moved)
        XCTAssertEqual(fs.removeCalls, [dst.path], "empty placeholder must be removed before the move")
        XCTAssertEqual(fs.moveCalls.count, 1)
        XCTAssertTrue(fs.existing.contains(dst.path))
    }

    func testMoveFailure_leavesOldDirectoryUntouched_andReportsFailure() {
        let fs = FakeFileSystem(existing: [src.path])
        fs.throwOnMove = true
        XCTAssertThrowsError(try DataMigrationService.migrateAppSupport(src: src, dst: dst, fileSystem: fs))
        // rename(2) is atomic: a failure leaves the source in place, no partial destination.
        XCTAssertTrue(fs.existing.contains(src.path))
        XCTAssertFalse(fs.existing.contains(dst.path))
    }

    // MARK: - Step B: UserDefaults

    func testDefaults_copiesOldToNewWhenNewEmpty_andLeavesOldIntact() {
        let defaults = FakeDefaults(domains: [oldDomain: ["k": "v"]])
        let copied = DataMigrationService.migrateDefaults(oldDomain: oldDomain, newDomain: newDomain, defaults: defaults)
        XCTAssertTrue(copied)
        XCTAssertEqual(defaults.domains[newDomain]?["k"] as? String, "v")
        XCTAssertEqual(defaults.domains[oldDomain]?["k"] as? String, "v", "old domain kept as rollback safety")
    }

    func testDefaults_idempotent_doesNotOverwritePopulatedNewDomain() {
        let defaults = FakeDefaults(domains: [oldDomain: ["k": "old"], newDomain: ["k": "new"]])
        let copied = DataMigrationService.migrateDefaults(oldDomain: oldDomain, newDomain: newDomain, defaults: defaults)
        XCTAssertFalse(copied)
        XCTAssertEqual(defaults.domains[newDomain]?["k"] as? String, "new")
        XCTAssertTrue(defaults.setCalls.isEmpty)
    }

    func testDefaults_oldDomainAbsent_noOp() {
        let defaults = FakeDefaults(domains: [:])
        let copied = DataMigrationService.migrateDefaults(oldDomain: oldDomain, newDomain: newDomain, defaults: defaults)
        XCTAssertFalse(copied)
        XCTAssertNil(defaults.domains[newDomain])
    }

    // MARK: - Step C: Keychain

    func testKeychain_migratesItems_withoutOverwritingExistingNewItem() {
        let items: [String: Data] = [
            oldPrefix + "a": Data("A".utf8),
            oldPrefix + "b": Data("B".utf8),
            oldPrefix + "c": Data("C".utf8),
            newPrefix + "b": Data("PRE-EXISTING".utf8), // item 2 already present under new prefix
        ]
        let keychain = FakeKeychain(items: items)
        let summary = DataMigrationService.migrateKeychain(oldPrefix: oldPrefix, newPrefix: newPrefix, keychain: keychain)
        XCTAssertEqual(summary.total, 3)
        XCTAssertEqual(summary.migrated, 2) // a and c
        XCTAssertEqual(summary.skipped, 1)  // b pre-exists
        XCTAssertEqual(keychain.items[newPrefix + "a"], Data("A".utf8))
        XCTAssertEqual(keychain.items[newPrefix + "c"], Data("C".utf8))
        XCTAssertEqual(keychain.items[newPrefix + "b"], Data("PRE-EXISTING".utf8), "must never overwrite")
        // Old items are left intact.
        XCTAssertEqual(keychain.items[oldPrefix + "a"], Data("A".utf8))
    }

    func testKeychain_enumerationFailure_zeroMigrated_noThrow() {
        let keychain = FakeKeychain(items: [oldPrefix + "a": Data("A".utf8)])
        keychain.throwOnEnumerate = true
        let summary = DataMigrationService.migrateKeychain(oldPrefix: oldPrefix, newPrefix: newPrefix, keychain: keychain)
        XCTAssertEqual(summary, .init(migrated: 0, skipped: 0, total: 0))
        XCTAssertTrue(keychain.writes.isEmpty)
    }

    func testKeychain_partialReadFailure_migratesReadableItems() {
        let items: [String: Data] = [
            oldPrefix + "a": Data("A".utf8),
            oldPrefix + "b": Data("B".utf8),
            oldPrefix + "c": Data("C".utf8),
        ]
        let keychain = FakeKeychain(items: items, unreadable: [oldPrefix + "b"]) // item 2 read throws
        let summary = DataMigrationService.migrateKeychain(oldPrefix: oldPrefix, newPrefix: newPrefix, keychain: keychain)
        XCTAssertEqual(summary.total, 3)
        XCTAssertEqual(summary.migrated, 2) // a and c
        XCTAssertEqual(summary.skipped, 1)  // b unreadable
        XCTAssertNotNil(keychain.items[newPrefix + "a"])
        XCTAssertNil(keychain.items[newPrefix + "b"])
        XCTAssertNotNil(keychain.items[newPrefix + "c"])
    }

    // MARK: - Test guard

    func testRunIfNeeded_underTestEnvironment_neverBuildsContext() {
        var factoryInvoked = false
        let result = DataMigrationService.runIfNeeded(isTestEnvironment: true) {
            factoryInvoked = true
            return nil
        }
        XCTAssertNil(result)
        XCTAssertFalse(factoryInvoked, "no seam may be constructed when the test guard is engaged")
    }

    func testRunIfNeeded_outsideTestEnvironment_invokesContextAndRuns() {
        let fs = FakeFileSystem(existing: [src.path])
        let defaults = FakeDefaults(domains: [oldDomain: ["k": "v"]])
        let keychain = FakeKeychain(items: [oldPrefix + "a": Data("A".utf8)])
        var factoryInvoked = false

        let summary = DataMigrationService.runIfNeeded(isTestEnvironment: false) {
            factoryInvoked = true
            return DataMigrationService.Context(
                appSupportSource: src,
                appSupportDestination: dst,
                oldDefaultsDomain: oldDomain,
                newDefaultsDomain: newDomain,
                oldKeychainPrefix: oldPrefix,
                newKeychainPrefix: newPrefix,
                fileSystem: fs,
                defaults: defaults,
                keychain: keychain,
                log: { _ in }
            )
        }
        XCTAssertTrue(factoryInvoked)
        XCTAssertEqual(summary?.appSupportMoved, true)
        XCTAssertEqual(summary?.defaultsCopied, true)
        XCTAssertEqual(summary?.keychain.migrated, 1)
    }

    // MARK: - Full-run composition + idempotency

    func testFullRun_composesAllSteps_thenSecondRunIsPureNoOp() {
        let fs = FakeFileSystem(existing: [src.path])
        let defaults = FakeDefaults(domains: [oldDomain: ["k": "v"]])
        let keychain = FakeKeychain(items: [
            oldPrefix + "a": Data("A".utf8),
            oldPrefix + "b": Data("B".utf8),
        ])

        func runOnce() -> DataMigrationService.Summary {
            DataMigrationService.run(
                appSupportSource: src,
                appSupportDestination: dst,
                oldDefaultsDomain: oldDomain,
                newDefaultsDomain: newDomain,
                oldKeychainPrefix: oldPrefix,
                newKeychainPrefix: newPrefix,
                fileSystem: fs,
                defaults: defaults,
                keychain: keychain
            )
        }

        let first = runOnce()
        XCTAssertEqual(first.appSupportMoved, true)
        XCTAssertEqual(first.defaultsCopied, true)
        XCTAssertEqual(first.keychain, .init(migrated: 2, skipped: 0, total: 2))

        let moveCountAfterFirst = fs.moveCalls.count
        let defaultsSetsAfterFirst = defaults.setCalls.count

        let second = runOnce()
        XCTAssertEqual(second.appSupportMoved, false)
        XCTAssertEqual(second.defaultsCopied, false)
        // Second keychain pass finds the old items already present under the new prefix -> all skipped.
        XCTAssertEqual(second.keychain, .init(migrated: 0, skipped: 2, total: 2))
        XCTAssertEqual(fs.moveCalls.count, moveCountAfterFirst, "no additional move on re-run")
        XCTAssertEqual(defaults.setCalls.count, defaultsSetsAfterFirst, "no additional defaults write on re-run")
    }

    func testFullRun_appSupportMoveThrows_doesNotRethrow_andStillRunsDefaultsAndKeychain() {
        let fs = FakeFileSystem(existing: [src.path])
        fs.throwOnMove = true
        let defaults = FakeDefaults(domains: [oldDomain: ["k": "v"]])
        let keychain = FakeKeychain(items: [
            oldPrefix + "a": Data("A".utf8),
            oldPrefix + "b": Data("B".utf8),
        ])

        // run() must swallow the Step A failure and still attempt Steps B and C.
        let summary = DataMigrationService.run(
            appSupportSource: src,
            appSupportDestination: dst,
            oldDefaultsDomain: oldDomain,
            newDefaultsDomain: newDomain,
            oldKeychainPrefix: oldPrefix,
            newKeychainPrefix: newPrefix,
            fileSystem: fs,
            defaults: defaults,
            keychain: keychain
        )

        XCTAssertEqual(summary.appSupportMoved, false, "Step A failure reported as not-moved, not rethrown")
        XCTAssertEqual(summary.defaultsCopied, true, "Step B still runs after Step A throws")
        XCTAssertEqual(summary.keychain, .init(migrated: 2, skipped: 0, total: 2), "Step C still runs after Step A throws")
        // Old data left in place by the failed move.
        XCTAssertTrue(fs.existing.contains(src.path), "old app-support directory untouched after move failure")
    }
}
