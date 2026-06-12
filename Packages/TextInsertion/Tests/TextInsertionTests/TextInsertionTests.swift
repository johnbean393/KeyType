import AppCompatibility
import AutocompleteCore
import XCTest
@testable import TextInsertion

final class TextInsertionTests: XCTestCase {
    private static let target = AppTarget(bundleIdentifier: "com.test.app", appName: "Test")

    private func context(target: AppTarget = TextInsertionTests.target) -> TextFieldContext {
        TextFieldContext(beforeCursor: "hello", target: target)
    }

    // MARK: - Recording seams

    /// Ordered log of every synthesiser + pasteboard call so tests can assert dispatch & sequencing.
    private final class Recorder: KeystrokeSynthesizing, CompletionPasteboard {
        var events: [String] = []
        func paste() { events.append("paste") }
        func pasteAndMatchStyle() { events.append("pasteAndMatchStyle") }
        func type(_ string: String) { events.append("type(\(string))") }
        func deleteBackward() { events.append("deleteBackward") }
        func save() { events.append("save") }
        func write(_ string: String) { events.append("write(\(string))") }
        func restore() { events.append("restore") }
    }

    private func makeInserter(_ recorder: Recorder, planner: InsertionPlanner = InsertionPlanner()) -> PasteboardCompletionInserter {
        PasteboardCompletionInserter(
            planner: planner,
            synthesizer: recorder,
            pasteboard: recorder,
            restoreDelayNanoseconds: 0
        )
    }

    // MARK: - Planner strategy selection

    func testPlannerDefaultsToPasteboardPaste() {
        let plan = InsertionPlanner().plan(candidate: CompletionCandidate(text: " world"), context: context())
        XCTAssertEqual(plan.strategy, .pasteboardPaste)
        XCTAssertEqual(plan.text, " world")
    }

    func testPlannerSelectsMatchStyle() {
        let store = AppCompatibilityStore(overrides: [
            TargetOverride(bundleIdentifier: Self.target.bundleIdentifier, requiresPasteAndMatchStyle: true)
        ])
        let plan = InsertionPlanner(compatibilityStore: store)
            .plan(candidate: CompletionCandidate(text: " world"), context: context())
        XCTAssertEqual(plan.strategy, .pasteAndMatchStyle)
    }

    func testPlannerSelectsChunkedInjectionAndNBSP() {
        let store = AppCompatibilityStore(overrides: [
            TargetOverride(
                bundleIdentifier: Self.target.bundleIdentifier,
                requiresNonBreakingSpaceWorkaround: true,
                stringInjectionChunkSize: 2
            )
        ])
        let plan = InsertionPlanner(compatibilityStore: store)
            .plan(candidate: CompletionCandidate(text: "a b"), context: context())
        XCTAssertEqual(plan.strategy, .chunkedStringInjection(size: 2))
        XCTAssertTrue(plan.useNonBreakingSpaceWorkaround)
        XCTAssertEqual(plan.text, "a\u{00a0}b")
    }

    func testPlannerCarriesBackspaceWorkaround() {
        let store = AppCompatibilityStore(overrides: [
            TargetOverride(bundleIdentifier: Self.target.bundleIdentifier, requiresBackspaceAfterPaste: true)
        ])
        let plan = InsertionPlanner(compatibilityStore: store)
            .plan(candidate: CompletionCandidate(text: " world"), context: context())
        XCTAssertTrue(plan.backspaceAfterPaste)
    }

    func testPlannerUsesDefaultPasteForNativeDiscord() {
        let target = AppTarget(bundleIdentifier: "com.hnc.Discord", appName: "Discord")
        let plan = InsertionPlanner()
            .plan(candidate: CompletionCandidate(text: " world"), context: context(target: target))

        XCTAssertEqual(plan.strategy, .pasteboardPaste)
        XCTAssertFalse(plan.useNonBreakingSpaceWorkaround)
    }

    func testPlannerUsesChunkedInjectionForNativeSlack() {
        let target = AppTarget(bundleIdentifier: "com.tinyspeck.slackmacgap", appName: "Slack")
        let plan = InsertionPlanner()
            .plan(candidate: CompletionCandidate(text: " world"), context: context(target: target))

        XCTAssertEqual(plan.strategy, .chunkedStringInjection(size: 8))
        XCTAssertFalse(plan.useNonBreakingSpaceWorkaround)
    }

    func testPlannerUsesChunkedInjectionForIAWriterMidWordText() {
        let target = AppTarget(bundleIdentifier: "pro.writer.mac", appName: "iA Writer")
        let plan = InsertionPlanner()
            .plan(candidate: CompletionCandidate(text: "out"), context: context(target: target))

        XCTAssertEqual(plan.strategy, .chunkedStringInjection(size: 8))
        XCTAssertEqual(plan.text, "out")
        XCTAssertFalse(plan.useNonBreakingSpaceWorkaround)
    }

    func testPlannerUsesChunkedInjectionForMessagesMidWordText() {
        let target = AppTarget(bundleIdentifier: "com.apple.MobileSMS", appName: "Messages")
        let plan = InsertionPlanner()
            .plan(candidate: CompletionCandidate(text: "rkaround"), context: context(target: target))

        XCTAssertEqual(plan.strategy, .chunkedStringInjection(size: 8))
        XCTAssertEqual(plan.text, "rkaround")
        XCTAssertFalse(plan.useNonBreakingSpaceWorkaround)
    }

    // MARK: - Inserter dispatch

    func testPasteboardPasteSavesWritesPastesRestores() async throws {
        let recorder = Recorder()
        try await makeInserter(recorder).insert(plan: InsertionPlan(text: " world"))
        XCTAssertEqual(recorder.events, ["save", "write( world)", "paste", "restore"])
    }

    func testPasteAndMatchStyleUsesMatchStyleShortcut() async throws {
        let recorder = Recorder()
        try await makeInserter(recorder).insert(plan: InsertionPlan(text: " world", strategy: .pasteAndMatchStyle))
        XCTAssertEqual(recorder.events, ["save", "write( world)", "pasteAndMatchStyle", "restore"])
    }

    func testBackspaceAfterPasteHappensBeforeRestore() async throws {
        let recorder = Recorder()
        try await makeInserter(recorder).insert(plan: InsertionPlan(text: "x", backspaceAfterPaste: true))
        XCTAssertEqual(recorder.events, ["save", "write(x)", "paste", "deleteBackward", "restore"])
    }

    func testNoRestoreWhenDisabled() async throws {
        let recorder = Recorder()
        try await makeInserter(recorder).insert(plan: InsertionPlan(text: "x", restorePasteboard: false))
        XCTAssertEqual(recorder.events, ["save", "write(x)", "paste"])
    }

    func testCharacterInjectionTypesEachCharAndSkipsPasteboard() async throws {
        let recorder = Recorder()
        try await makeInserter(recorder).insert(plan: InsertionPlan(text: "abc", strategy: .characterInjection))
        XCTAssertEqual(recorder.events, ["type(a)", "type(b)", "type(c)"])
    }

    func testChunkedInjectionTypesEachChunk() async throws {
        let recorder = Recorder()
        try await makeInserter(recorder).insert(plan: InsertionPlan(text: "abcde", strategy: .chunkedStringInjection(size: 2)))
        XCTAssertEqual(recorder.events, ["type(ab)", "type(cd)", "type(e)"])
    }

    func testFirstWordOnlyTruncatesBeforePaste() async throws {
        let recorder = Recorder()
        try await makeInserter(recorder).insert(plan: InsertionPlan(text: "orrow to discuss", strategy: .firstWordOnly))
        XCTAssertEqual(recorder.events, ["save", "write(orrow)", "paste", "restore"])
    }

    func testEmptyTextIsANoOp() async throws {
        let recorder = Recorder()
        try await makeInserter(recorder).insert(plan: InsertionPlan(text: ""))
        XCTAssertEqual(recorder.events, [])
    }

    // MARK: - Helpers

    func testFirstWordKeepsLeadingWhitespace() {
        XCTAssertEqual(PasteboardCompletionInserter.firstWord(of: " hello world"), " hello")
        XCTAssertEqual(PasteboardCompletionInserter.firstWord(of: "single"), "single")
    }

    func testChunkSplitting() {
        XCTAssertEqual(PasteboardCompletionInserter.chunks(of: "abcde", size: 2), ["ab", "cd", "e"])
        XCTAssertEqual(PasteboardCompletionInserter.chunks(of: "abc", size: 0), ["abc"])
    }
}
