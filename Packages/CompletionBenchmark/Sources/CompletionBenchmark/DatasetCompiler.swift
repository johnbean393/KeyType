import Foundation

public enum CompilerCaseType: String, Codable, CaseIterable, Equatable {
    case endOfLineAppend = "end-of-line-append"
    case midWordCompletion = "mid-word-completion"
    case fillInMiddle = "fill-in-middle"
    case duplicationTrap = "duplication-trap"
    case codeIdentifierOrComment = "code-identifiers-comments"
    case messagingChat = "messaging-chat"
    case email
    case browserWebForm = "browser-web-form"
    case appPolicySuppression = "app-policy-suppression"
    case secureFieldSuppression = "secure-field-suppression"
}

public struct BenchmarkSourceDocument: Codable, Equatable {
    public var id: String
    public var sourceGroup: String
    public var split: BenchmarkSplit
    public var text: String
    public var tags: [String]
    public var suites: [BenchmarkSuite]
    public var source: BenchmarkSourceMetadata
    public var contextSources: BenchmarkContextSources
    public var target: BenchmarkAppTarget?
    public var detectedLanguage: String?
    public var typingContext: String?
    public var placeholder: String?
    public var labels: [String]
    public var screenContext: String?
    public var clipboardContext: String?
    public var caseTypes: [CompilerCaseType]

    public init(
        id: String,
        sourceGroup: String,
        split: BenchmarkSplit = .eval,
        text: String,
        tags: [String] = [],
        suites: [BenchmarkSuite] = [.core],
        source: BenchmarkSourceMetadata,
        contextSources: BenchmarkContextSources = BenchmarkContextSources(fieldText: .real, appContext: .synthetic),
        target: BenchmarkAppTarget? = nil,
        detectedLanguage: String? = "en",
        typingContext: String? = nil,
        placeholder: String? = nil,
        labels: [String] = [],
        screenContext: String? = nil,
        clipboardContext: String? = nil,
        caseTypes: [CompilerCaseType] = []
    ) {
        self.id = id
        self.sourceGroup = sourceGroup
        self.split = split
        self.text = text
        self.tags = tags
        self.suites = suites
        self.source = source
        self.contextSources = contextSources
        self.target = target
        self.detectedLanguage = detectedLanguage
        self.typingContext = typingContext
        self.placeholder = placeholder
        self.labels = labels
        self.screenContext = screenContext
        self.clipboardContext = clipboardContext
        self.caseTypes = caseTypes
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case sourceGroup
        case split
        case text
        case tags
        case suites
        case source
        case contextSources
        case target
        case detectedLanguage
        case typingContext
        case placeholder
        case labels
        case screenContext
        case clipboardContext
        case caseTypes
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.sourceGroup = try c.decodeIfPresent(String.self, forKey: .sourceGroup) ?? id
        self.split = try c.decodeIfPresent(BenchmarkSplit.self, forKey: .split) ?? .eval
        self.text = try c.decode(String.self, forKey: .text)
        self.tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        self.suites = try c.decodeIfPresent([BenchmarkSuite].self, forKey: .suites) ?? [.core]
        self.source = try c.decode(BenchmarkSourceMetadata.self, forKey: .source)
        self.contextSources = try c.decodeIfPresent(BenchmarkContextSources.self, forKey: .contextSources)
            ?? BenchmarkContextSources(fieldText: .real, appContext: .synthetic)
        self.target = try c.decodeIfPresent(BenchmarkAppTarget.self, forKey: .target)
        self.detectedLanguage = try c.decodeIfPresent(String.self, forKey: .detectedLanguage)
        self.typingContext = try c.decodeIfPresent(String.self, forKey: .typingContext)
        self.placeholder = try c.decodeIfPresent(String.self, forKey: .placeholder)
        self.labels = try c.decodeIfPresent([String].self, forKey: .labels) ?? []
        self.screenContext = try c.decodeIfPresent(String.self, forKey: .screenContext)
        self.clipboardContext = try c.decodeIfPresent(String.self, forKey: .clipboardContext)
        self.caseTypes = try c.decodeIfPresent([CompilerCaseType].self, forKey: .caseTypes) ?? []
    }
}

public struct BenchmarkDatasetCompilerConfiguration: Equatable {
    public var defaultCaseTypes: [CompilerCaseType]
    public var includePolicyCases: Bool
    public var maxTargetCharacters: Int

    public init(
        defaultCaseTypes: [CompilerCaseType] = [
            .endOfLineAppend,
            .midWordCompletion,
            .fillInMiddle,
            .duplicationTrap,
            .messagingChat,
            .email,
            .browserWebForm
        ],
        includePolicyCases: Bool = true,
        maxTargetCharacters: Int = 32
    ) {
        self.defaultCaseTypes = defaultCaseTypes
        self.includePolicyCases = includePolicyCases
        self.maxTargetCharacters = maxTargetCharacters
    }
}

public enum BenchmarkDatasetCompiler {
    public static func compile(
        documents: [BenchmarkSourceDocument],
        configuration: BenchmarkDatasetCompilerConfiguration = BenchmarkDatasetCompilerConfiguration()
    ) -> [CompletionBenchmarkCase] {
        var cases: [CompletionBenchmarkCase] = []
        for document in documents {
            let types = document.caseTypes.isEmpty ? configuration.defaultCaseTypes : document.caseTypes
            for type in types {
                if let c = makeCase(type: type, document: document, maxTargetCharacters: configuration.maxTargetCharacters) {
                    cases.append(c)
                }
            }
        }
        if configuration.includePolicyCases {
            cases.append(contentsOf: policySuppressionCases(split: documents.first?.split ?? .eval))
        }
        return cases
    }

    public static func sourceDocuments(fromTextFilesAt url: URL, suite: BenchmarkSuite, split: BenchmarkSplit) throws -> [BenchmarkSourceDocument] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return []
        }

        let urls: [URL]
        if isDirectory.boolValue {
            let entries = try FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            urls = entries.filter { ["txt", "md", "swift"].contains($0.pathExtension.lowercased()) }.sorted { $0.path < $1.path }
        } else {
            urls = [url]
        }

        return try urls.map { file in
            let text = try String(contentsOf: file, encoding: .utf8)
            let stem = file.deletingPathExtension().lastPathComponent
            return BenchmarkSourceDocument(
                id: stem,
                sourceGroup: "local-\(stem)",
                split: split,
                text: text,
                tags: inferredTags(for: file),
                suites: [suite],
                source: BenchmarkSourceMetadata(
                    kind: file.pathExtension.lowercased() == "swift" ? "code" : "document",
                    title: file.lastPathComponent,
                    path: file.path,
                    license: "local"
                ),
                contextSources: BenchmarkContextSources(fieldText: .real, appContext: .synthetic)
            )
        }
    }

    private static func makeCase(
        type: CompilerCaseType,
        document: BenchmarkSourceDocument,
        maxTargetCharacters: Int
    ) -> CompletionBenchmarkCase? {
        switch type {
        case .appPolicySuppression, .secureFieldSuppression:
            return nil
        default:
            break
        }

        let text = normalized(document.text)
        guard text.count >= 80 else { return nil }

        let slice: Slice
        switch type {
        case .endOfLineAppend, .messagingChat, .email, .browserWebForm, .codeIdentifierOrComment:
            guard let s = appendSlice(in: text, maxTargetCharacters: maxTargetCharacters) else { return nil }
            slice = s
        case .midWordCompletion:
            guard let s = midWordSlice(in: text, maxTargetCharacters: maxTargetCharacters) else { return nil }
            slice = s
        case .fillInMiddle:
            guard let s = fimSlice(in: text, maxTargetCharacters: maxTargetCharacters) else { return nil }
            slice = s
        case .duplicationTrap:
            guard let s = duplicationTrapSlice(in: text, maxTargetCharacters: maxTargetCharacters) else { return nil }
            slice = s
        case .appPolicySuppression, .secureFieldSuppression:
            return nil
        }

        let target = targetFor(type: type, document: document)
        let context = BenchmarkTextFieldContext(
            beforeCursor: slice.before,
            afterCursor: slice.after,
            target: target,
            detectedLanguage: document.detectedLanguage,
            typingContext: typingContextFor(type: type, document: document),
            placeholder: placeholderFor(type: type, document: document),
            labels: labelsFor(type: type, document: document),
            traits: traitsFor(type: type),
            screenContext: document.screenContext,
            clipboardContext: document.clipboardContext
        )
        let tags = stableTags(document.tags + tagsFor(type))
        let id = "\(document.id)-\(type.rawValue)-001"
        let expected = BenchmarkExpected(
            kind: .insert,
            modelTarget: slice.target,
            shownAcceptable: [slice.target.trimmingCharacters(in: .whitespacesAndNewlines)].filter { !$0.isEmpty }
        )
        return CompletionBenchmarkCase(
            id: id,
            split: document.split,
            sourceGroup: document.sourceGroup,
            suites: stableSuites(document.suites),
            tags: tags,
            contextSources: document.contextSources,
            source: document.source,
            context: context,
            expected: expected
        )
    }

    private struct Slice {
        var before: String
        var target: String
        var after: String
    }

    private static func appendSlice(in text: String, maxTargetCharacters: Int) -> Slice? {
        guard let cursor = wordBoundary(near: text.index(text.startIndex, offsetBy: min(max(32, text.count / 3), text.count - 24)), in: text),
              let target = followingText(in: text, from: cursor, maxCharacters: maxTargetCharacters)
        else { return nil }
        return Slice(before: String(text[..<cursor]), target: target, after: "")
    }

    private static func midWordSlice(in text: String, maxTargetCharacters: Int) -> Slice? {
        let words = text.rangesOfWords(minLength: 6)
        guard let word = words.dropFirst(max(0, words.count / 3)).first else { return nil }
        let splitOffset = min(4, max(2, text.distance(from: word.lowerBound, to: word.upperBound) / 2))
        let cursor = text.index(word.lowerBound, offsetBy: splitOffset)
        let targetEnd = text.index(
            cursor,
            offsetBy: min(maxTargetCharacters, text.distance(from: cursor, to: word.upperBound)),
            limitedBy: word.upperBound
        ) ?? word.upperBound
        let target = String(text[cursor..<targetEnd])
        guard !target.isEmpty else { return nil }
        return Slice(before: String(text[..<cursor]), target: target, after: "")
    }

    private static func fimSlice(in text: String, maxTargetCharacters: Int) -> Slice? {
        guard let append = appendSlice(in: text, maxTargetCharacters: maxTargetCharacters) else { return nil }
        let start = append.before.endIndex
        guard let targetEnd = text.index(start, offsetBy: append.target.count, limitedBy: text.endIndex) else { return nil }
        let suffixStart = targetEnd
        let suffixEnd = text.index(
            suffixStart,
            offsetBy: min(80, text.distance(from: suffixStart, to: text.endIndex)),
            limitedBy: text.endIndex
        ) ?? text.endIndex
        let after = String(text[suffixStart..<suffixEnd])
        guard !after.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return Slice(before: append.before, target: append.target, after: after)
    }

    private static func duplicationTrapSlice(in text: String, maxTargetCharacters: Int) -> Slice? {
        let words = text.rangesOfWords(minLength: 4)
        guard words.count >= 8 else { return nil }
        let targetWord = words[min(words.count / 2, words.count - 2)]
        let nextWord = words[min(words.count / 2 + 1, words.count - 1)]
        let before = String(text[..<targetWord.lowerBound])
        var target = String(text[targetWord.lowerBound..<targetWord.upperBound])
        if target.count < maxTargetCharacters, targetWord.upperBound < text.endIndex {
            target += String(text[targetWord.upperBound..<nextWord.lowerBound])
        }
        let afterEnd = text.index(
            nextWord.lowerBound,
            offsetBy: min(80, text.distance(from: nextWord.lowerBound, to: text.endIndex)),
            limitedBy: text.endIndex
        ) ?? text.endIndex
        let after = String(text[nextWord.lowerBound..<afterEnd])
        guard !before.isEmpty, !target.isEmpty, !after.isEmpty else { return nil }
        return Slice(before: before, target: target, after: after)
    }

    private static func policySuppressionCases(split: BenchmarkSplit) -> [CompletionBenchmarkCase] {
        [
            CompletionBenchmarkCase(
                id: "policy-terminal-tab-001",
                split: split,
                sourceGroup: "policy-handcrafted-001",
                suites: [.policy, .smoke],
                tags: ["policy", "terminal", "suppress"],
                contextSources: BenchmarkContextSources(fieldText: .synthetic, appContext: .synthetic),
                source: BenchmarkSourceMetadata(kind: "policy", title: "Terminal Tab policy"),
                context: BenchmarkTextFieldContext(
                    beforeCursor: "git checkout fea",
                    target: BenchmarkAppTarget(
                        bundleIdentifier: "com.apple.Terminal",
                        appName: "Terminal",
                        windowTitle: "zsh"
                    ),
                    detectedLanguage: "en",
                    typingContext: "terminal",
                    traits: BenchmarkTextFieldTraits(isTerminalLike: true)
                ),
                expected: BenchmarkExpected(kind: .suppress, allowedReasons: ["tabShortcutsDisabled"])
            ),
            CompletionBenchmarkCase(
                id: "secure-field-001",
                split: split,
                sourceGroup: "policy-handcrafted-001",
                suites: [.policy, .smoke],
                tags: ["policy", "secure-field", "suppress"],
                contextSources: BenchmarkContextSources(fieldText: .synthetic, appContext: .synthetic),
                source: BenchmarkSourceMetadata(kind: "policy", title: "Secure field exclusion"),
                context: BenchmarkTextFieldContext(
                    beforeCursor: "hunter",
                    target: BenchmarkAppTarget(
                        bundleIdentifier: "com.1password.1password",
                        appName: "1Password"
                    ),
                    traits: BenchmarkTextFieldTraits(isSecureTextEntry: true, isPasswordField: true)
                ),
                expected: BenchmarkExpected(kind: .suppress, allowedReasons: ["secureFieldExcluded"])
            )
        ]
    }

    private static func followingText(in text: String, from cursor: String.Index, maxCharacters: Int) -> String? {
        guard cursor < text.endIndex else { return nil }
        var end = cursor
        var consumed = 0
        var lastGood = cursor
        while end < text.endIndex && consumed < maxCharacters {
            let ch = text[end]
            end = text.index(after: end)
            consumed += 1
            if ch == "." || ch == "!" || ch == "?" || ch == "\n" {
                lastGood = end
                break
            }
            if ch.isWhitespace {
                lastGood = end
            }
        }
        if lastGood == cursor {
            lastGood = end
        }
        let target = String(text[cursor..<lastGood])
        guard target.rangeOfCharacter(from: .alphanumerics) != nil else { return nil }
        return target
    }

    private static func wordBoundary(near index: String.Index, in text: String) -> String.Index? {
        var cursor = index
        while cursor < text.endIndex {
            if text[cursor].isWhitespace {
                return text.index(after: cursor)
            }
            cursor = text.index(after: cursor)
        }
        cursor = index
        while cursor > text.startIndex {
            cursor = text.index(before: cursor)
            if text[cursor].isWhitespace {
                return text.index(after: cursor)
            }
        }
        return nil
    }

    private static func normalized(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func inferredTags(for file: URL) -> [String] {
        switch file.pathExtension.lowercased() {
        case "swift":
            return ["code"]
        case "md":
            return ["document", "markdown"]
        default:
            return ["document"]
        }
    }

    private static func targetFor(type: CompilerCaseType, document: BenchmarkSourceDocument) -> BenchmarkAppTarget {
        if let target = document.target {
            return target
        }
        switch type {
        case .email:
            return BenchmarkAppTarget(bundleIdentifier: "com.apple.mail", appName: "Mail", windowTitle: "Draft")
        case .messagingChat:
            return BenchmarkAppTarget(bundleIdentifier: "com.apple.MobileSMS", appName: "Messages", windowTitle: "Chat")
        case .browserWebForm:
            return BenchmarkAppTarget(
                bundleIdentifier: "com.google.Chrome",
                appName: "Google Chrome",
                windowTitle: "Feedback",
                domain: "example.com"
            )
        case .codeIdentifierOrComment:
            return BenchmarkAppTarget(bundleIdentifier: "com.apple.dt.Xcode", appName: "Xcode", windowTitle: "Source.swift")
        default:
            return BenchmarkAppTarget(bundleIdentifier: "com.apple.TextEdit", appName: "TextEdit", windowTitle: "Untitled")
        }
    }

    private static func typingContextFor(type: CompilerCaseType, document: BenchmarkSourceDocument) -> String? {
        if let typingContext = document.typingContext {
            return typingContext
        }
        switch type {
        case .email:
            return "email"
        case .messagingChat:
            return "message"
        case .browserWebForm:
            return "browser-form"
        case .codeIdentifierOrComment:
            return "code"
        default:
            return "document"
        }
    }

    private static func placeholderFor(type: CompilerCaseType, document: BenchmarkSourceDocument) -> String? {
        if let placeholder = document.placeholder {
            return placeholder
        }
        switch type {
        case .email:
            return "Write your message"
        case .messagingChat:
            return "Message"
        case .browserWebForm:
            return "Leave a comment"
        default:
            return nil
        }
    }

    private static func labelsFor(type: CompilerCaseType, document: BenchmarkSourceDocument) -> [String] {
        if !document.labels.isEmpty {
            return document.labels
        }
        switch type {
        case .browserWebForm:
            return ["Comment"]
        case .email:
            return ["Body"]
        default:
            return []
        }
    }

    private static func traitsFor(type: CompilerCaseType) -> BenchmarkTextFieldTraits {
        switch type {
        case .browserWebForm:
            return BenchmarkTextFieldTraits(isWebField: true)
        default:
            return BenchmarkTextFieldTraits()
        }
    }

    private static func tagsFor(_ type: CompilerCaseType) -> [String] {
        switch type {
        case .endOfLineAppend:
            return ["append"]
        case .midWordCompletion:
            return ["mid-word", "hard"]
        case .fillInMiddle:
            return ["fim", "mid-line", "hard"]
        case .duplicationTrap:
            return ["duplication-trap", "after-cursor", "hard"]
        case .codeIdentifierOrComment:
            return ["code", "comment"]
        case .messagingChat:
            return ["messaging", "chat"]
        case .email:
            return ["email"]
        case .browserWebForm:
            return ["browser", "web-form"]
        case .appPolicySuppression:
            return ["policy", "suppress"]
        case .secureFieldSuppression:
            return ["secure-field", "suppress"]
        }
    }

    private static func stableTags(_ tags: [String]) -> [String] {
        Array(Set(tags)).sorted()
    }

    private static func stableSuites(_ suites: [BenchmarkSuite]) -> [BenchmarkSuite] {
        Array(Set(suites)).sorted { $0.rawValue < $1.rawValue }
    }
}

private extension String {
    func rangesOfWords(minLength: Int) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var cursor = startIndex
        while cursor < endIndex {
            while cursor < endIndex, !self[cursor].isLetter && !self[cursor].isNumber {
                cursor = index(after: cursor)
            }
            let start = cursor
            while cursor < endIndex, self[cursor].isLetter || self[cursor].isNumber || self[cursor] == "_" {
                cursor = index(after: cursor)
            }
            if start < cursor, distance(from: start, to: cursor) >= minLength {
                ranges.append(start..<cursor)
            }
        }
        return ranges
    }
}
