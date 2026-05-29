import AppCompatibility
import AppKit
import AutocompleteCore
import Foundation

public enum InsertionStrategy: Equatable {
    case pasteboardPaste
    case pasteAndMatchStyle
    case characterInjection
    case chunkedStringInjection(size: Int)
    case firstWordOnly
}

public struct InsertionPlan: Equatable {
    public var text: String
    public var strategy: InsertionStrategy
    public var restorePasteboard: Bool
    public var useNonBreakingSpaceWorkaround: Bool
    public var backspaceAfterPaste: Bool

    public init(
        text: String,
        strategy: InsertionStrategy = .pasteboardPaste,
        restorePasteboard: Bool = true,
        useNonBreakingSpaceWorkaround: Bool = false,
        backspaceAfterPaste: Bool = false
    ) {
        self.text = text
        self.strategy = strategy
        self.restorePasteboard = restorePasteboard
        self.useNonBreakingSpaceWorkaround = useNonBreakingSpaceWorkaround
        self.backspaceAfterPaste = backspaceAfterPaste
    }
}

public protocol CompletionInserting {
    func planInsertion(candidate: CompletionCandidate, context: TextFieldContext) -> InsertionPlan
    func insert(plan: InsertionPlan) async throws
}

public struct InsertionPlanner {
    private let compatibilityStore: AppCompatibilityStore

    public init(compatibilityStore: AppCompatibilityStore = AppCompatibilityStore()) {
        self.compatibilityStore = compatibilityStore
    }

    public func plan(candidate: CompletionCandidate, context: TextFieldContext) -> InsertionPlan {
        let policy = compatibilityStore.policy(for: context.target)

        let strategy: InsertionStrategy
        if let chunkSize = policy.stringInjectionChunkSize {
            strategy = .chunkedStringInjection(size: chunkSize)
        } else if policy.insertionRequiresPasteAndMatchStyle {
            strategy = .pasteAndMatchStyle
        } else {
            strategy = .pasteboardPaste
        }

        let text = policy.insertionRequiresNonBreakingSpace
            ? candidate.text.replacingOccurrences(of: " ", with: "\u{00a0}")
            : candidate.text

        return InsertionPlan(
            text: text,
            strategy: strategy,
            restorePasteboard: true,
            useNonBreakingSpaceWorkaround: policy.insertionRequiresNonBreakingSpace
        )
    }
}

public final class PasteboardCompletionInserter: CompletionInserting {
    private let planner: InsertionPlanner

    public init(planner: InsertionPlanner = InsertionPlanner()) {
        self.planner = planner
    }

    public func planInsertion(candidate: CompletionCandidate, context: TextFieldContext) -> InsertionPlan {
        planner.plan(candidate: candidate, context: context)
    }

    public func insert(plan: InsertionPlan) async throws {
        let pasteboard = NSPasteboard.general
        let originalItems = pasteboard.pasteboardItems ?? []

        pasteboard.clearContents()
        pasteboard.setString(plan.text, forType: .string)

        if plan.restorePasteboard {
            pasteboard.clearContents()
            pasteboard.writeObjects(originalItems)
        }
    }
}
