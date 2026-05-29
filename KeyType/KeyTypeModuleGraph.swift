//
//  KeyTypeModuleGraph.swift
//  KeyType
//
//  Created by Codex on 5/29/26.
//

import AppCompatibility
import AutocompleteCore
import CompletionUI
import ConstrainedGeneration
import MacContextCapture
import ModelRuntime
import Prompting
import TextInsertion
import TokenProfiles

enum KeyTypeModuleGraph {
    static func makeMVPProbeContext() -> TextFieldContext {
        TextFieldContext(
            beforeCursor: "",
            target: AppTarget(
                bundleIdentifier: "com.pattonium.KeyType",
                appName: "KeyType"
            )
        )
    }

    static func makePromptBuilder() -> PromptBuilder {
        PromptBuilder()
    }

    static func makeCompatibilityStore() -> AppCompatibilityStore {
        AppCompatibilityStore()
    }
}
