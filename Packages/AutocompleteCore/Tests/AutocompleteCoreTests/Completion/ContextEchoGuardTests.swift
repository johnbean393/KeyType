import AutocompleteCore
import XCTest

final class ContextEchoGuardTests: XCTestCase {

    func testFiresWhenCompletionEchoesClipboardVerbatim() {
        // The reported case: text copied from a localhost page in another browser is injected as
        // clipboard context and parroted into a fresh Gmail draft.
        let clipboard = "if you require maintenance of UPS systems or backup power, contact us."
        XCTAssertTrue(
            ContextEchoGuard.echoesInjectedContext(
                completion: " if you require maintenance of UPS systems or",
                injectedContext: [clipboard]
            )
        )
    }

    func testFiresOnLeadingEchoThatThenDiverges() {
        let screen = "The private key for the OpenAI API is stored in the vault."
        XCTAssertTrue(
            ContextEchoGuard.echoesInjectedContext(
                completion: " the private key for the OpenAI API is yours to keep forever",
                injectedContext: [screen]
            )
        )
    }

    func testChecksAllInjectedSources() {
        XCTAssertTrue(
            ContextEchoGuard.echoesInjectedContext(
                completion: " maintenance of UPS systems is required",
                injectedContext: ["unrelated clipboard text", "notes about maintenance of UPS systems here"]
            )
        )
    }

    func testDoesNotFireWithoutInjectedContext() {
        XCTAssertFalse(
            ContextEchoGuard.echoesInjectedContext(
                completion: " if you require maintenance of UPS systems or",
                injectedContext: []
            )
        )
    }

    func testAllowsGenuineCompletionNotInContext() {
        let clipboard = "if you require maintenance of UPS systems or backup power, contact us."
        XCTAssertFalse(
            ContextEchoGuard.echoesInjectedContext(
                completion: " hope you are doing well",
                injectedContext: [clipboard]
            )
        )
    }

    func testDoesNotFireOnShortIncidentalOverlap() {
        // A short common run ("if you ") must not be enough to suppress a real continuation.
        XCTAssertFalse(
            ContextEchoGuard.echoesInjectedContext(
                completion: " if you can",
                injectedContext: ["if you require maintenance of UPS systems"]
            )
        )
    }
}
