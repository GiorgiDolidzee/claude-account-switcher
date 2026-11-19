import Foundation
import Testing
@testable import SwitcherCore

@Suite struct AccountIDTests {
    @Test func acceptsAndLowercasesUUID() {
        #expect(AccountID("12345678-ABCD-4EF0-8123-456789ABCDEF")?.raw == "12345678-abcd-4ef0-8123-456789abcdef")
    }

    @Test func rejectsNonUUIDs() {
        for bad in ["", "../x", "abc", "12345678-abcd-4ef0-8123-456789abcdef/..", "12345678 abcd-4ef0-8123-456789abcdef", " 12345678-abcd-4ef0-8123-456789abcdef"] {
            #expect(AccountID(bad) == nil, "\(bad)")
        }
    }

    @Test func codableRoundTripIsPlainString() throws {
        let id = AccountID("12345678-abcd-4ef0-8123-456789abcdef")!
        let data = try JSONEncoder().encode(id)
        #expect(String(decoding: data, as: UTF8.self) == "\"12345678-abcd-4ef0-8123-456789abcdef\"")
        #expect(try JSONDecoder().decode(AccountID.self, from: data) == id)
    }
}
