import AutocompleteCore
import Foundation

public enum BenchmarkSuite: String, Codable, CaseIterable, Equatable {
    case smoke
    case core
    case edge
    case policy
    case humanCalibration = "human-calibration"
    case latency
}

public enum BenchmarkSplit: String, Codable, CaseIterable, Equatable {
    case train
    case dev
    case eval
    case holdout
}

public enum BenchmarkContextSourceKind: String, Codable, Equatable {
    case real
    case synthetic
    case mixed
    case none
}

public enum BenchmarkExpectedKind: String, Codable, Equatable {
    case insert
    case suppress
}

public struct BenchmarkContextSources: Codable, Equatable {
    public var fieldText: BenchmarkContextSourceKind
    public var appContext: BenchmarkContextSourceKind
    public var screenContext: BenchmarkContextSourceKind
    public var clipboard: BenchmarkContextSourceKind
    public var labels: BenchmarkContextSourceKind

    public init(
        fieldText: BenchmarkContextSourceKind,
        appContext: BenchmarkContextSourceKind = .none,
        screenContext: BenchmarkContextSourceKind = .none,
        clipboard: BenchmarkContextSourceKind = .none,
        labels: BenchmarkContextSourceKind = .none
    ) {
        self.fieldText = fieldText
        self.appContext = appContext
        self.screenContext = screenContext
        self.clipboard = clipboard
        self.labels = labels
    }

    private enum CodingKeys: String, CodingKey {
        case fieldText
        case appContext
        case screenContext
        case clipboard
        case labels
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.fieldText = try c.decodeIfPresent(BenchmarkContextSourceKind.self, forKey: .fieldText) ?? .none
        self.appContext = try c.decodeIfPresent(BenchmarkContextSourceKind.self, forKey: .appContext) ?? .none
        self.screenContext = try c.decodeIfPresent(BenchmarkContextSourceKind.self, forKey: .screenContext) ?? .none
        self.clipboard = try c.decodeIfPresent(BenchmarkContextSourceKind.self, forKey: .clipboard) ?? .none
        self.labels = try c.decodeIfPresent(BenchmarkContextSourceKind.self, forKey: .labels) ?? .none
    }
}

public struct BenchmarkSourceMetadata: Codable, Equatable {
    public var kind: String
    public var title: String?
    public var path: String?
    public var url: String?
    public var license: String?
    public var note: String?

    public init(
        kind: String,
        title: String? = nil,
        path: String? = nil,
        url: String? = nil,
        license: String? = nil,
        note: String? = nil
    ) {
        self.kind = kind
        self.title = title
        self.path = path
        self.url = url
        self.license = license
        self.note = note
    }
}

public struct BenchmarkAppTarget: Codable, Equatable {
    public var bundleIdentifier: String
    public var appName: String
    public var windowTitle: String?
    public var domain: String?

    public init(
        bundleIdentifier: String,
        appName: String,
        windowTitle: String? = nil,
        domain: String? = nil
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.appName = appName
        self.windowTitle = windowTitle
        self.domain = domain
    }

    public func coreTarget() -> AppTarget {
        AppTarget(
            bundleIdentifier: bundleIdentifier,
            appName: appName,
            windowTitle: windowTitle,
            domain: domain
        )
    }
}

public struct BenchmarkTextFieldTraits: Codable, Equatable {
    public var isSecureTextEntry: Bool
    public var isPasswordField: Bool
    public var isPasswordManagerContext: Bool
    public var isWebField: Bool
    public var isTerminalLike: Bool

    public init(
        isSecureTextEntry: Bool = false,
        isPasswordField: Bool = false,
        isPasswordManagerContext: Bool = false,
        isWebField: Bool = false,
        isTerminalLike: Bool = false
    ) {
        self.isSecureTextEntry = isSecureTextEntry
        self.isPasswordField = isPasswordField
        self.isPasswordManagerContext = isPasswordManagerContext
        self.isWebField = isWebField
        self.isTerminalLike = isTerminalLike
    }

    public func coreTraits() -> TextFieldTraits {
        TextFieldTraits(
            isSecureTextEntry: isSecureTextEntry,
            isPasswordField: isPasswordField,
            isPasswordManagerContext: isPasswordManagerContext,
            isWebField: isWebField,
            isTerminalLike: isTerminalLike
        )
    }

    private enum CodingKeys: String, CodingKey {
        case isSecureTextEntry
        case isPasswordField
        case isPasswordManagerContext
        case isWebField
        case isTerminalLike
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.isSecureTextEntry = try c.decodeIfPresent(Bool.self, forKey: .isSecureTextEntry) ?? false
        self.isPasswordField = try c.decodeIfPresent(Bool.self, forKey: .isPasswordField) ?? false
        self.isPasswordManagerContext = try c.decodeIfPresent(Bool.self, forKey: .isPasswordManagerContext) ?? false
        self.isWebField = try c.decodeIfPresent(Bool.self, forKey: .isWebField) ?? false
        self.isTerminalLike = try c.decodeIfPresent(Bool.self, forKey: .isTerminalLike) ?? false
    }
}

public struct BenchmarkTextFieldContext: Codable, Equatable {
    public var beforeCursor: String
    public var afterCursor: String
    public var target: BenchmarkAppTarget
    public var detectedLanguage: String?
    public var typingContext: String?
    public var placeholder: String?
    public var labels: [String]
    public var traits: BenchmarkTextFieldTraits
    public var screenContext: String?
    public var clipboardContext: String?
    public var previousUserInputs: [String]

    public init(
        beforeCursor: String,
        afterCursor: String = "",
        target: BenchmarkAppTarget,
        detectedLanguage: String? = nil,
        typingContext: String? = nil,
        placeholder: String? = nil,
        labels: [String] = [],
        traits: BenchmarkTextFieldTraits = BenchmarkTextFieldTraits(),
        screenContext: String? = nil,
        clipboardContext: String? = nil,
        previousUserInputs: [String] = []
    ) {
        self.beforeCursor = beforeCursor
        self.afterCursor = afterCursor
        self.target = target
        self.detectedLanguage = detectedLanguage
        self.typingContext = typingContext
        self.placeholder = placeholder
        self.labels = labels
        self.traits = traits
        self.screenContext = screenContext
        self.clipboardContext = clipboardContext
        self.previousUserInputs = previousUserInputs
    }

    private enum CodingKeys: String, CodingKey {
        case beforeCursor
        case afterCursor
        case target
        case detectedLanguage
        case typingContext
        case placeholder
        case labels
        case traits
        case screenContext
        case clipboardContext
        case previousUserInputs
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.beforeCursor = try c.decode(String.self, forKey: .beforeCursor)
        self.afterCursor = try c.decodeIfPresent(String.self, forKey: .afterCursor) ?? ""
        self.target = try c.decode(BenchmarkAppTarget.self, forKey: .target)
        self.detectedLanguage = try c.decodeIfPresent(String.self, forKey: .detectedLanguage)
        self.typingContext = try c.decodeIfPresent(String.self, forKey: .typingContext)
        self.placeholder = try c.decodeIfPresent(String.self, forKey: .placeholder)
        self.labels = try c.decodeIfPresent([String].self, forKey: .labels) ?? []
        self.traits = try c.decodeIfPresent(BenchmarkTextFieldTraits.self, forKey: .traits) ?? BenchmarkTextFieldTraits()
        self.screenContext = try c.decodeIfPresent(String.self, forKey: .screenContext)
        self.clipboardContext = try c.decodeIfPresent(String.self, forKey: .clipboardContext)
        self.previousUserInputs = try c.decodeIfPresent([String].self, forKey: .previousUserInputs) ?? []
    }

    public func coreContext() -> TextFieldContext {
        TextFieldContext(
            beforeCursor: beforeCursor,
            afterCursor: afterCursor,
            target: target.coreTarget(),
            placeholder: placeholder,
            labels: labels,
            detectedLanguage: detectedLanguage,
            typingContext: typingContext,
            traits: traits.coreTraits()
        )
    }
}

public struct BenchmarkExpected: Codable, Equatable {
    public var kind: BenchmarkExpectedKind
    public var modelTarget: String?
    public var shownAcceptable: [String]
    public var allowedReasons: [String]

    public init(
        kind: BenchmarkExpectedKind,
        modelTarget: String? = nil,
        shownAcceptable: [String] = [],
        allowedReasons: [String] = []
    ) {
        self.kind = kind
        self.modelTarget = modelTarget
        self.shownAcceptable = shownAcceptable
        self.allowedReasons = allowedReasons
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case modelTarget
        case shownAcceptable
        case allowedReasons
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.kind = try c.decode(BenchmarkExpectedKind.self, forKey: .kind)
        self.modelTarget = try c.decodeIfPresent(String.self, forKey: .modelTarget)
        self.shownAcceptable = try c.decodeIfPresent([String].self, forKey: .shownAcceptable) ?? []
        self.allowedReasons = try c.decodeIfPresent([String].self, forKey: .allowedReasons) ?? []
    }

    public var acceptableShownTexts: [String] {
        var values = shownAcceptable
        if let modelTarget {
            values.insert(modelTarget, at: 0)
        }
        return values
    }
}

public struct BenchmarkLimits: Codable, Equatable {
    public var maxCompletionTokens: Int?
    public var maxDisplayWidth: Int?

    public init(maxCompletionTokens: Int? = nil, maxDisplayWidth: Int? = nil) {
        self.maxCompletionTokens = maxCompletionTokens
        self.maxDisplayWidth = maxDisplayWidth
    }
}

public struct KeyTypeBenchCase: Codable, Equatable {
    public var id: String
    public var split: BenchmarkSplit
    public var sourceGroup: String
    public var suites: [BenchmarkSuite]
    public var tags: [String]
    public var contextSources: BenchmarkContextSources
    public var source: BenchmarkSourceMetadata?
    public var context: BenchmarkTextFieldContext
    public var expected: BenchmarkExpected
    public var limits: BenchmarkLimits?

    public init(
        id: String,
        split: BenchmarkSplit,
        sourceGroup: String,
        suites: [BenchmarkSuite],
        tags: [String],
        contextSources: BenchmarkContextSources,
        source: BenchmarkSourceMetadata? = nil,
        context: BenchmarkTextFieldContext,
        expected: BenchmarkExpected,
        limits: BenchmarkLimits? = nil
    ) {
        self.id = id
        self.split = split
        self.sourceGroup = sourceGroup
        self.suites = suites
        self.tags = tags
        self.contextSources = contextSources
        self.source = source
        self.context = context
        self.expected = expected
        self.limits = limits
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case split
        case sourceGroup
        case suites
        case tags
        case contextSources
        case source
        case context
        case expected
        case limits
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.split = try c.decodeIfPresent(BenchmarkSplit.self, forKey: .split) ?? .eval
        self.sourceGroup = try c.decode(String.self, forKey: .sourceGroup)
        self.suites = try c.decodeIfPresent([BenchmarkSuite].self, forKey: .suites) ?? [.core]
        self.tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        self.contextSources = try c.decode(BenchmarkContextSources.self, forKey: .contextSources)
        self.source = try c.decodeIfPresent(BenchmarkSourceMetadata.self, forKey: .source)
        self.context = try c.decode(BenchmarkTextFieldContext.self, forKey: .context)
        self.expected = try c.decode(BenchmarkExpected.self, forKey: .expected)
        self.limits = try c.decodeIfPresent(BenchmarkLimits.self, forKey: .limits)
    }
}
