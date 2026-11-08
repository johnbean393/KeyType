import AutocompleteCore
import XCTest

final class AcceptedInsertionTrackerTests: XCTestCase {
    private let target = AppTarget(bundleIdentifier: "com.test.app", appName: "Test")
    private let start = Date(timeIntervalSince1970: 1_000)

    private func context(
        before: String,
        bundle: String = "com.test.app",
        traits: TextFieldTraits = TextFieldTraits()
    ) -> TextFieldContext {
        TextFieldContext(
            beforeCursor: before,
            target: AppTarget(bundleIdentifier: bundle, appName: "Test"),
            traits: traits
        )
    }

    private func completionSpec(
        prefix: String,
        accepted: String,
        window: TimeInterval = 5,
        grace: TimeInterval = 0
    ) -> AcceptedInsertionSpec {
        AcceptedInsertionSpec(
            kind: .completion,
            acceptedText: accepted,
            prefixBeforeAccepted: prefix,
            expectedBeforeCursor: prefix + accepted,
            bundleIdentifier: target.bundleIdentifier,
            observationWindow: window,
            synthesizedSettleGrace: grace
        )
    }

    private func settle(
        _ tracker: inout AcceptedInsertionTracker,
        expected: String,
        at time: Date
    ) {
        XCTAssertNil(tracker.observe(context: context(before: expected), at: time))
    }

    func testRetainedWhenAcceptedTextStillPresentAtTimeout() {
        var tracker = AcceptedInsertionTracker()
        tracker.begin(completionSpec(prefix: "Hello ", accepted: "world", grace: 0), at: start)
        settle(&tracker, expected: "Hello world", at: start.addingTimeInterval(0.05))
        // Post-grace confirmation that the text is still present.
        XCTAssertNil(
            tracker.observe(
                context: context(before: "Hello world"),
                at: start.addingTimeInterval(0.2)
            )
        )

        let resolution = tracker.observe(
            context: context(before: "Hello world"),
            at: start.addingTimeInterval(5)
        )
        XCTAssertEqual(resolution?.outcome, .retained)
        XCTAssertEqual(resolution?.kind, .completion)
        XCTAssertFalse(tracker.hasPendingObservation)
    }

    func testRetainedWhenUserContinuesTypingAfterAcceptedText() {
        var tracker = AcceptedInsertionTracker()
        tracker.begin(completionSpec(prefix: "Hello ", accepted: "world", grace: 0), at: start)
        settle(&tracker, expected: "Hello world", at: start.addingTimeInterval(0.05))

        XCTAssertNil(
            tracker.observe(
                context: context(before: "Hello world!"),
                at: start.addingTimeInterval(0.2)
            )
        )
        let resolution = tracker.observe(
            context: context(before: "Hello world!"),
            at: start.addingTimeInterval(5)
        )
        XCTAssertEqual(resolution?.outcome, .retained)
    }

    func testFullyRevertedWhenAcceptedTextDeleted() {
        var tracker = AcceptedInsertionTracker()
        tracker.begin(completionSpec(prefix: "Hello ", accepted: "world", grace: 0), at: start)
        settle(&tracker, expected: "Hello world", at: start.addingTimeInterval(0.05))

        let resolution = tracker.observe(
            context: context(before: "Hello "),
            at: start.addingTimeInterval(0.2)
        )
        XCTAssertEqual(resolution?.outcome, .fullyReverted)
    }

    func testPartiallyRemovedWhenOnlySuffixOfAcceptedTextDeleted() {
        var tracker = AcceptedInsertionTracker()
        tracker.begin(completionSpec(prefix: "Hello ", accepted: "world", grace: 0), at: start)
        settle(&tracker, expected: "Hello world", at: start.addingTimeInterval(0.05))

        let resolution = tracker.observe(
            context: context(before: "Hello wo"),
            at: start.addingTimeInterval(0.2)
        )
        XCTAssertEqual(resolution?.outcome, .partiallyRemoved)
    }

    func testReplacedWhenAcceptedRegionOverwritten() {
        var tracker = AcceptedInsertionTracker()
        tracker.begin(completionSpec(prefix: "Hello ", accepted: "world", grace: 0), at: start)
        settle(&tracker, expected: "Hello world", at: start.addingTimeInterval(0.05))

        let resolution = tracker.observe(
            context: context(before: "Hello there"),
            at: start.addingTimeInterval(0.2)
        )
        XCTAssertEqual(resolution?.outcome, .replaced)
    }

    func testUnobservableOnSecureField() {
        var tracker = AcceptedInsertionTracker()
        tracker.begin(completionSpec(prefix: "Hello ", accepted: "world"), at: start)

        let resolution = tracker.observe(
            context: context(before: "Hello world", traits: TextFieldTraits(isSecureTextEntry: true)),
            at: start.addingTimeInterval(0.1)
        )
        XCTAssertEqual(resolution?.outcome, .unobservable)
    }

    func testUnobservableOnAppChange() {
        var tracker = AcceptedInsertionTracker()
        tracker.begin(completionSpec(prefix: "Hello ", accepted: "world"), at: start)

        let resolution = tracker.observe(
            context: context(before: "Hello world", bundle: "com.other.app"),
            at: start.addingTimeInterval(0.1)
        )
        XCTAssertEqual(resolution?.outcome, .unobservable)
    }

    func testUnobservableWhenFocusLost() {
        var tracker = AcceptedInsertionTracker()
        tracker.begin(completionSpec(prefix: "Hello ", accepted: "world"), at: start)

        let resolution = tracker.observe(context: nil, at: start.addingTimeInterval(0.1))
        XCTAssertEqual(resolution?.outcome, .unobservable)
    }

    func testUnobservableWhenInsertionNeverSettlesBeforeTimeout() {
        var tracker = AcceptedInsertionTracker()
        tracker.begin(completionSpec(prefix: "Hello ", accepted: "world", window: 1), at: start)
        // Field never shows the accepted text (insertion failed / AX missed it).
        XCTAssertNil(
            tracker.observe(
                context: context(before: "Hello "),
                at: start.addingTimeInterval(0.2)
            )
        )
        let resolution = tracker.observe(
            context: context(before: "Hello "),
            at: start.addingTimeInterval(1)
        )
        XCTAssertEqual(resolution?.outcome, .unobservable)
    }

    func testExpiredWhenSettledButNoPostGraceFieldUpdate() {
        var tracker = AcceptedInsertionTracker()
        tracker.begin(completionSpec(prefix: "Hello ", accepted: "world", window: 1, grace: 0.2), at: start)
        settle(&tracker, expected: "Hello world", at: start.addingTimeInterval(0.05))

        // Window closes without any observation after the synthesized-insertion grace.
        let resolution = tracker.observe(
            context: context(before: "Hello world"),
            at: start.addingTimeInterval(1)
        )
        XCTAssertEqual(resolution?.outcome, .expired)
    }

    func testSynthesizedSettleGraceIgnoresTransientPostPasteEdits() {
        var tracker = AcceptedInsertionTracker()
        tracker.begin(
            completionSpec(prefix: "Hello ", accepted: "world", grace: 0.2),
            at: start
        )
        settle(&tracker, expected: "Hello world", at: start.addingTimeInterval(0.05))

        // Within grace, a transient deletion from backspace-after-paste must not resolve.
        XCTAssertNil(
            tracker.observe(
                context: context(before: "Hello worl"),
                at: start.addingTimeInterval(0.1)
            )
        )
        // After grace, the same deletion classifies.
        let resolution = tracker.observe(
            context: context(before: "Hello worl"),
            at: start.addingTimeInterval(0.3)
        )
        XCTAssertEqual(resolution?.outcome, .partiallyRemoved)
    }

    func testBeginSupersedesSettledObservationAsRetained() {
        var tracker = AcceptedInsertionTracker()
        tracker.begin(completionSpec(prefix: "Hello ", accepted: "world", grace: 0), at: start)
        settle(&tracker, expected: "Hello world", at: start.addingTimeInterval(0.05))

        let prior = tracker.begin(
            completionSpec(prefix: "Hello world ", accepted: "today"),
            at: start.addingTimeInterval(0.2)
        )
        XCTAssertEqual(prior?.outcome, .retained)
        XCTAssertTrue(tracker.hasPendingObservation)
    }

    func testCorrectionReplacementHelpersAndReversion() throws {
        let correction = CorrectionCandidate(
            original: "mdidle",
            replacement: "middle",
            originalRange: TextRangeDescriptor(container: .beforeCursor, startOffset: 7, endOffset: 13),
            confidence: 0.9,
            source: .spellcheckOnly,
            validation: .spellcheckOnly
        )
        let before = "in the mdidle, "
        let ctx = context(before: before)
        let expected = AcceptedInsertionTracker.expectedBeforeCursor(accepting: correction, in: ctx)
        let prefix = AcceptedInsertionTracker.prefixBeforeAccepted(for: correction, in: ctx)
        XCTAssertEqual(prefix, "in the ")
        XCTAssertEqual(expected, "in the middle, ")

        var tracker = AcceptedInsertionTracker()
        tracker.begin(
            AcceptedInsertionSpec(
                kind: .correction,
                acceptedText: correction.replacement,
                prefixBeforeAccepted: try XCTUnwrap(prefix),
                expectedBeforeCursor: try XCTUnwrap(expected),
                bundleIdentifier: target.bundleIdentifier,
                synthesizedSettleGrace: 0
            ),
            at: start
        )
        settle(&tracker, expected: "in the middle, ", at: start.addingTimeInterval(0.05))

        let resolution = tracker.observe(
            context: context(before: "in the mdidle, "),
            at: start.addingTimeInterval(0.2)
        )
        // Restoring the typo overwrites the accepted replacement → replaced (different content),
        // not fullyReverted (fullyReverted means empty remainder / back to prefix only).
        XCTAssertEqual(resolution?.outcome, .replaced)
        XCTAssertEqual(resolution?.kind, .correction)
    }

    func testCorrectionFullyRevertedToPrefix() {
        var tracker = AcceptedInsertionTracker()
        tracker.begin(
            AcceptedInsertionSpec(
                kind: .correction,
                acceptedText: "middle",
                prefixBeforeAccepted: "in the ",
                expectedBeforeCursor: "in the middle",
                bundleIdentifier: target.bundleIdentifier,
                synthesizedSettleGrace: 0
            ),
            at: start
        )
        settle(&tracker, expected: "in the middle", at: start.addingTimeInterval(0.05))
        let resolution = tracker.observe(
            context: context(before: "in the "),
            at: start.addingTimeInterval(0.2)
        )
        XCTAssertEqual(resolution?.outcome, .fullyReverted)
    }

    func testCancelDropsPendingObservation() {
        var tracker = AcceptedInsertionTracker()
        tracker.begin(completionSpec(prefix: "A ", accepted: "b"), at: start)
        tracker.cancel()
        XCTAssertNil(tracker.observe(context: context(before: "A b"), at: start.addingTimeInterval(1)))
    }
}
