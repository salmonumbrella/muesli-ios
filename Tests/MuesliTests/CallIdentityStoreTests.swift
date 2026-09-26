import Foundation
import XCTest
@testable import Muesli

final class CallIdentityStoreTests: XCTestCase {
    private func observation(_ handle: CallHandle) -> CallObservation {
        CallObservation(id: UUID(), source: .phone, sourceDeviceID: "fixture-device",
            observedAt: Date(timeIntervalSinceReferenceDate: 100), evidence: .dialerHistory, handles: [handle])
    }

    func testReplayAndRemovalSurviveReopen() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SharedStore(containerURL: directory)
        let calls = CallIdentityStore(store: store)
        let h = try XCTUnwrap(CallIdentityNormalizer.email("caller@example.test"))
        let o = observation(h)
        let p = try XCTUnwrap(calls.resolve(o).people.first)
        XCTAssertNil(p.displayName)
        XCTAssertEqual(try calls.resolve(o).people.map(\.id), [p.id])
        XCTAssertEqual(try calls.history(personID: p.id).count, 1)
        let removal = CallRevision(restoreEpoch: 0, counter: 2, deviceID: "fixture-device", provenance: .manual)
        try calls.suppress(personID: p.id, recordName: nil, revision: removal)
        let reopened = CallIdentityStore(store: SharedStore(containerURL: directory))
        XCTAssertTrue(try reopened.resolve(observation(h)).people.isEmpty)
        try reopened.restore(personID: p.id, revision: removal)
        XCTAssertTrue(try reopened.resolve(observation(h)).people.isEmpty)
        try reopened.restore(personID: p.id,
            revision: CallRevision(restoreEpoch: 1, counter: 3, deviceID: "fixture-device", provenance: .manual))
        XCTAssertEqual(try reopened.resolve(observation(h)).people.map(\.id), [p.id])
    }

    func testManualSharedHandleStaysAmbiguous() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let calls = CallIdentityStore(store: SharedStore(containerURL: directory))
        let h = try XCTUnwrap(CallIdentityNormalizer.phone("+12025550123"))
        let r = CallRevision(restoreEpoch: 0, counter: 1, deviceID: "fixture-device", provenance: .manual)
        for name in ["Fixture A", "Fixture B"] {
            try calls.savePerson(CallPerson(id: UUID(), handles: [h], displayName: name, revision: r,
                nameRevision: r, handleRevisions: [h.stableKey: r], deletionRevision: nil,
                createdAt: Date(), updatedAt: Date(), deletedAt: nil))
        }
        let result = try calls.resolve(observation(h))
        XCTAssertEqual(result.people.count, 2)
        XCTAssertEqual(result.ambiguousHandleKeys, [h.stableKey])
    }

    func testAliasRedirectsPendingIntentAndRejectsCycle() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let calls = CallIdentityStore(store: SharedStore(containerURL: directory))
        let h = try XCTUnwrap(CallIdentityNormalizer.email("other@example.test"))
        let p = try XCTUnwrap(calls.resolve(observation(h)).people.first)
        let root = try XCTUnwrap(calls.resolve(observation(try XCTUnwrap(CallIdentityNormalizer.email("caller@example.test")))).people.first)
        try calls.saveContactIntent(CallContactIntent(personID: p.id, handles: [h], displayName: nil, state: .pending, savedContactID: nil))
        let r = CallRevision(restoreEpoch: 0, counter: 5, deviceID: "fixture-device", provenance: .manual)
        try calls.mergeAlias(CallPersonAlias(fromID: p.id, rootID: root.id, revision: r))
        XCTAssertEqual(try calls.resolve(observation(h)).people.map(\.id), [root.id])
        XCTAssertEqual(try calls.contactIntent(personID: root.id)?.state, .pending)
        XCTAssertThrowsError(try calls.mergeAlias(CallPersonAlias(fromID: root.id, rootID: p.id, revision: r)))
    }
}
