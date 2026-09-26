import Foundation
import XCTest
@testable import Muesli

final class CallIdentityModelTests: XCTestCase {
    func testInternationalFormattingKeepsTheSamePerson() throws {
        let a = try XCTUnwrap(CallIdentityNormalizer.phone("+1 (202) 555-0123"))
        let b = try XCTUnwrap(CallIdentityNormalizer.phone("+12025550123"))
        XCTAssertEqual(a.stableKey, "phone|e164|+12025550123|")
        XCTAssertEqual(CallIdentityNormalizer.personID(for: a), CallIdentityNormalizer.personID(for: b))
        XCTAssertEqual(CallIdentityNormalizer.personID(for: a), UUID(uuidString: "70f42ed0-0023-5347-893f-b6d497feb4f6"))
        XCTAssertTrue(a.canCreateAppleContact)
    }

    func testMalformedTextNeverBecomesACaller() {
        for raw in ["", "Private Number", "Unknown", "+01234567890", "+123", "+1234567890123456",
                    "Call +12025550123", "+12025550123; +442079460123", "+1 (202 555-0123",
                    "+1 202) 555-0123", "+12025550123\u{202e}", "+12025550123\n",
                    "+12025550123 ext", "+12025550123 ext 123456789"] {
            XCTAssertNil(CallIdentityNormalizer.phone(raw), raw)
        }
    }

    func testNationalNumbersStayUnresolved() throws {
        XCTAssertNil(CallIdentityNormalizer.phone("2025550123"))
        let h = try XCTUnwrap(CallIdentityNormalizer.phone("2025550123", region: "US"))
        XCTAssertEqual(h.stableKey, "phone|national:US|2025550123|")
        XCTAssertFalse(h.canCreateAppleContact)
        XCTAssertNil(CallIdentityNormalizer.phone("2025550123", region: "US|CA"))
    }

    func testExtensionsEmailAliasesAndServicesStayDistinct() throws {
        let a = try XCTUnwrap(CallIdentityNormalizer.phone("+12025550123 ext 10"))
        let b = try XCTUnwrap(CallIdentityNormalizer.phone("+12025550123 x11"))
        XCTAssertNotEqual(CallIdentityNormalizer.personID(for: a), CallIdentityNormalizer.personID(for: b))
        XCTAssertEqual(CallIdentityNormalizer.email("Alice+sales@EXAMPLE.test")?.canonicalValue, "Alice+sales@example.test")
        for raw in ["", "name", "Alice @example.test", "Alice@@example.test", "Alice@example.test\n", "A|B@example.test"] {
            XCTAssertNil(CallIdentityNormalizer.email(raw))
        }
        let signal = try XCTUnwrap(CallIdentityNormalizer.service("caller.123", namespace: "signal"))
        let telegram = try XCTUnwrap(CallIdentityNormalizer.service("caller.123", namespace: "telegram"))
        XCTAssertNotEqual(CallIdentityNormalizer.personID(for: signal), CallIdentityNormalizer.personID(for: telegram))
        XCTAssertFalse(signal.canCreateAppleContact)
        XCTAssertNil(CallIdentityNormalizer.service("caller|123", namespace: "signal"))
        XCTAssertNil(CallIdentityNormalizer.service("caller", namespace: ""))
    }

    func testStandardUUIDVectorAndFormattingProperty() throws {
        XCTAssertEqual(CallIdentityNormalizer.uuidV5(namespace: UUID(uuidString: "6ba7b810-9dad-11d1-80b4-00c04fd430c8")!, name: "www.example.com"), UUID(uuidString: "2ed6657d-e927-568b-95e1-2665a8aea6a2"))
        for suffix in 0..<256 {
            let digits = String(format: "%04d", suffix)
            let h = try XCTUnwrap(CallIdentityNormalizer.phone("+1 (202) 555-" + digits))
            XCTAssertEqual(h.canonicalValue, "+1202555" + digits)
        }
    }
}
