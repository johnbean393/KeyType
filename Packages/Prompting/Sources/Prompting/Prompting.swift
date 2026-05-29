import AutocompleteCore
import Foundation

public enum PromptTemplateMode: Equatable {
    case baseContinuation
    case chatML
}

public enum PromptTruncationMode: Equatable {
    case none
    case preserveStart
    case preserveEnd
    case hard
}

public struct PromptSection: Equatable {
    public var name: String
    public var heading: String?
    public var content: String
    public var priority: Int
    public var minBudget: Int
    public var maxBudget: Int
    public var truncationMode: PromptTruncationMode

    public init(
        name: String,
        heading: String? = nil,
        content: String,
        priority: Int,
        minBudget: Int = 0,
        maxBudget: Int,
        truncationMode: PromptTruncationMode = .hard
    ) {
        self.name = name
        self.heading = heading
        self.content = content
        self.priority = priority
        self.minBudget = minBudget
        self.maxBudget = maxBudget
        self.truncationMode = truncationMode
    }
}

public protocol PromptTokenCounting {
    func tokenCount(for text: String) -> Int
}

public struct ApproximatePromptTokenCounter: PromptTokenCounting {
    public init() {}

    public func tokenCount(for text: String) -> Int {
        max(1, Int(ceil(Double(text.count) / 4.0)))
    }
}

public struct PromptBuildResult: Equatable {
    public var prompt: String
    public var sections: [PromptSection]
    public var estimatedTokenCount: Int

    public init(prompt: String, sections: [PromptSection], estimatedTokenCount: Int) {
        self.prompt = prompt
        self.sections = sections
        self.estimatedTokenCount = estimatedTokenCount
    }
}

public struct PromptBuilder {
    private let tokenCounter: PromptTokenCounting
    private let maxPromptTokens: Int

    public init(
        tokenCounter: PromptTokenCounting = ApproximatePromptTokenCounter(),
        maxPromptTokens: Int = 4096
    ) {
        self.tokenCounter = tokenCounter
        self.maxPromptTokens = maxPromptTokens
    }

    public func buildPrompt(
        context: TextFieldContext,
        customInstructions: [String] = [],
        previousUserInputs: [String] = [],
        pasteboardText: String? = nil,
        screenText: String? = nil,
        mode: PromptTemplateMode = .baseContinuation
    ) -> PromptBuildResult {
        let sections = makeSections(
            context: context,
            customInstructions: customInstructions,
            previousUserInputs: previousUserInputs,
            pasteboardText: pasteboardText,
            screenText: screenText
        )
        let allocated = allocate(sections: sections)
        let body = allocated.map(render).joined(separator: "\n\n")

        switch mode {
        case .baseContinuation:
            return PromptBuildResult(
                prompt: body,
                sections: allocated,
                estimatedTokenCount: tokenCounter.tokenCount(for: body)
            )
        case .chatML:
            let wrapped = "<|system|>\nComplete the user's text at the cursor.\n<|user|>\n\(body)\n<|assistant|>\n"
            return PromptBuildResult(
                prompt: wrapped,
                sections: allocated,
                estimatedTokenCount: tokenCounter.tokenCount(for: wrapped)
            )
        }
    }

    private func makeSections(
        context: TextFieldContext,
        customInstructions: [String],
        previousUserInputs: [String],
        pasteboardText: String?,
        screenText: String?
    ) -> [PromptSection] {
        var sections: [PromptSection] = [
            PromptSection(
                name: "completionInstructions",
                heading: "Completion instructions",
                content: "Continue the user's current text at the cursor. Produce only text that should be inserted.",
                priority: 100,
                minBudget: 16,
                maxBudget: 96
            ),
            PromptSection(
                name: "generalInfo",
                heading: "General information",
                content: "Application: \(context.target.appName)\nBundle identifier: \(context.target.bundleIdentifier)\nWindow title: \(context.target.windowTitle ?? "")\nContext: \(context.typingContext ?? "")",
                priority: 60,
                maxBudget: 192
            ),
            PromptSection(
                name: "textFieldProperties",
                heading: "Text field properties",
                content: "Placeholder: \(context.placeholder ?? "")\nLabels: \(context.labels.joined(separator: ", "))\nLanguage: \(context.detectedLanguage ?? "")",
                priority: 65,
                maxBudget: 192
            ),
            PromptSection(
                name: "afterCursor",
                heading: "Text after cursor",
                content: context.afterCursor,
                priority: 90,
                maxBudget: 512,
                truncationMode: .preserveStart
            ),
            PromptSection(
                name: "beforeCursor",
                heading: "Text before cursor",
                content: context.beforeCursor,
                priority: 100,
                minBudget: 64,
                maxBudget: 2048,
                truncationMode: .preserveEnd
            )
        ]

        if !customInstructions.isEmpty {
            sections.insert(
                PromptSection(
                    name: "customInstructions",
                    heading: "Custom writing instructions",
                    content: customInstructions.joined(separator: "\n"),
                    priority: 80,
                    maxBudget: 384
                ),
                at: 1
            )
        }

        if !previousUserInputs.isEmpty {
            sections.insert(
                PromptSection(
                    name: "previousUserInputs",
                    heading: "Relevant previous writing",
                    content: previousUserInputs.joined(separator: "\n"),
                    priority: 50,
                    maxBudget: 512,
                    truncationMode: .preserveEnd
                ),
                at: max(1, sections.count - 2)
            )
        }

        if let pasteboardText, !pasteboardText.isEmpty {
            sections.insert(PromptSection(name: "pasteboard", heading: "Clipboard context", content: pasteboardText, priority: 40, maxBudget: 384), at: max(1, sections.count - 2))
        }

        if let screenText, !screenText.isEmpty {
            sections.insert(PromptSection(name: "screen", heading: "Screen context", content: screenText, priority: 35, maxBudget: 384), at: max(1, sections.count - 2))
        }

        return sections
    }

    private func allocate(sections: [PromptSection]) -> [PromptSection] {
        var remaining = maxPromptTokens
        return sections
            .sorted { lhs, rhs in lhs.priority == rhs.priority ? lhs.name < rhs.name : lhs.priority > rhs.priority }
            .map { section in
                var copy = section
                let requested = min(section.maxBudget, max(section.minBudget, tokenCounter.tokenCount(for: section.content)))
                let budget = min(requested, max(section.minBudget, remaining))
                remaining = max(0, remaining - budget)
                copy.content = truncate(section.content, toApproximateTokens: budget, mode: section.truncationMode)
                return copy
            }
            .sorted { lhs, rhs in sectionOrder(lhs.name) < sectionOrder(rhs.name) }
    }

    private func truncate(_ text: String, toApproximateTokens budget: Int, mode: PromptTruncationMode) -> String {
        let characterBudget = max(0, budget * 4)
        guard text.count > characterBudget else {
            return text
        }

        switch mode {
        case .none:
            return text
        case .preserveStart:
            return String(text.prefix(characterBudget))
        case .preserveEnd:
            return String(text.suffix(characterBudget))
        case .hard:
            return String(text.prefix(characterBudget))
        }
    }

    private func render(_ section: PromptSection) -> String {
        if let heading = section.heading {
            return "[\(heading)]\n\(section.content)"
        }
        return section.content
    }

    private func sectionOrder(_ name: String) -> Int {
        [
            "completionInstructions",
            "customInstructions",
            "generalInfo",
            "textFieldProperties",
            "previousUserInputs",
            "pasteboard",
            "screen",
            "afterCursor",
            "beforeCursor"
        ].firstIndex(of: name) ?? Int.max
    }
}
