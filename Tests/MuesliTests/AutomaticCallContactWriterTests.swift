import Foundation
import XCTest
@testable import Muesli

private actor FixtureIOSCallContacts: Muesli.CallContactsClient {
    let access: Muesli.CallContactsAuthorization
    var found: [String]
    let failAfterSave: Bool
    let failBeforeSave: Bool
    var creates = 0
    init(access: Muesli.CallContactsAuthorization = .full, found: [String] = [], failAfterSave: Bool = false, failBeforeSave: Bool = false) {
        self.access = access; self.found = found
        self.failAfterSave = failAfterSave; self.failBeforeSave = failBeforeSave
    }
    func authorization() async -> Muesli.CallContactsAuthorization { access }
    func matches(handles: [Muesli.CallHandle]) async throws -> [String] { found }
    func create(intent: Muesli.CallContactIntent) async throws -> String {
        creates += 1
        try await Task.sleep(nanoseconds: 5_000_000)
        if failBeforeSave { throw NSError(domain: "FixtureReadOnly", code: 1) }
        found = ["fixture-saved-contact"]
        if failAfterSave { throw NSError(domain: "FixtureSavedThenFailed", code: 1) }
        return "fixture-saved-contact"
    }
    func createCount() -> Int { creates }
}
private actor FixtureIOSCallOwner: Muesli.CallContactWriterOwnership {
    var owner: String?
    let offline: Bool
    init(owner: String? = "fixture-device", offline: Bool = false) { self.owner = owner; self.offline = offline }
    func ownsWriter(deviceID: String) async throws -> Bool {
        if offline { throw NSError(domain: "FixtureOffline", code: 1) }
        return owner == deviceID
    }
    func claimWriter(deviceID: String) async throws -> Bool {
        if offline { throw NSError(domain: "FixtureOffline", code: 1) }
        guard owner == nil || owner == deviceID else { return false }
        owner = deviceID; return true
    }
    func releaseWriterAfterDrain(deviceID: String) async throws { if owner == deviceID { owner = nil } }
}
final class AutomaticCallContactWriterTests: XCTestCase {
    private func fixture() throws -> (Muesli.CallIdentityStore, UUID, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let calls = Muesli.CallIdentityStore(store: Muesli.SharedStore(containerURL: directory))
        let handle = try XCTUnwrap(Muesli.CallIdentityNormalizer.phone("+12025550123"))
        let observation = Muesli.CallObservation(id: UUID(), source: .phone, sourceDeviceID: "fixture-device", observedAt: Date(), evidence: .dialerHistory, handles: [handle])
        let person = try XCTUnwrap(calls.resolve(observation).people.first)
        try calls.saveContactIntent(Muesli.CallContactIntent(personID: person.id, handles: [handle], displayName: nil, state: .pending, savedContactID: nil))
        return (calls, person.id, directory)
    }
    func testSavedBeforeLocalAcknowledgementDoesNotCreateTwice() async throws {
        let (calls, id, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let contacts = FixtureIOSCallContacts(failAfterSave: true)
        let first = Muesli.AutomaticCallContactWriter(store: calls, contacts: contacts, ownership: FixtureIOSCallOwner(), deviceID: "fixture-device")
        let firstResult = await first.process(personID: id)
        XCTAssertEqual(firstResult, .failed)
        let reopened = Muesli.CallIdentityStore(store: Muesli.SharedStore(containerURL: directory))
        let second = Muesli.AutomaticCallContactWriter(store: reopened, contacts: contacts, ownership: FixtureIOSCallOwner(), deviceID: "fixture-device")
        let recovered = await second.process(personID: id)
        let count = await contacts.createCount()
        XCTAssertEqual(recovered, .saved)
        XCTAssertEqual(count, 1)
        XCTAssertEqual(try reopened.contactIntent(personID: id)?.savedContactID, "fixture-saved-contact")
    }
    func testConcurrentRequestsCreateOneNamelessContact() async throws {
        let (calls, id, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let contacts = FixtureIOSCallContacts()
        let writer = Muesli.AutomaticCallContactWriter(store: calls, contacts: contacts, ownership: FixtureIOSCallOwner(), deviceID: "fixture-device")
        await withTaskGroup(of: Muesli.CallContactSaveState.self) { group in
            for _ in 0..<20 { group.addTask { await writer.process(personID: id) } }
            for await _ in group {}
        }
        let count = await contacts.createCount()
        XCTAssertEqual(count, 1)
        XCTAssertEqual(try calls.contactIntent(personID: id)?.state, .saved)
    }
    func testPermissionAndAmbiguityPreventWrites() async throws {
        for access in [Muesli.CallContactsAuthorization.limited, .denied, .notDetermined, .full] {
            let (calls, id, directory) = try fixture()
            defer { try? FileManager.default.removeItem(at: directory) }
            let contacts = FixtureIOSCallContacts(access: access, found: ["fixture-a", "fixture-b"])
            let writer = Muesli.AutomaticCallContactWriter(store: calls, contacts: contacts, ownership: FixtureIOSCallOwner(), deviceID: "fixture-device")
            let result = await writer.process(personID: id)
            let count = await contacts.createCount()
            XCTAssertEqual(result, access == .full ? .ambiguous : .permissionRequired)
            XCTAssertEqual(count, 0)
            XCTAssertEqual(try calls.contactIntent(personID: id)?.state, result)
        }
    }
    func testNonOwnerAndOfflineStayPending() async throws {
        for owner in [FixtureIOSCallOwner(owner: "fixture-other"), FixtureIOSCallOwner(offline: true)] {
            let (calls, id, directory) = try fixture()
            defer { try? FileManager.default.removeItem(at: directory) }
            let contacts = FixtureIOSCallContacts()
            let writer = Muesli.AutomaticCallContactWriter(store: calls, contacts: contacts, ownership: owner, deviceID: "fixture-device")
            let result = await writer.process(personID: id)
            let count = await contacts.createCount()
            XCTAssertEqual(result, .pending)
            XCTAssertEqual(count, 0)
        }
    }
    func testFailedWriteRequiresExplicitRetry() async throws {
        let (calls, id, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let contacts = FixtureIOSCallContacts(failBeforeSave: true)
        let writer = Muesli.AutomaticCallContactWriter(store: calls, contacts: contacts, ownership: FixtureIOSCallOwner(), deviceID: "fixture-device")
        let first = await writer.process(personID: id)
        let second = await writer.process(personID: id)
        let count = await contacts.createCount()
        XCTAssertEqual(first, .failed)
        XCTAssertEqual(second, .failed)
        XCTAssertEqual(count, 1)
    }
}
