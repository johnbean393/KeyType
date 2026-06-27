//
//  ShortcutsSettingsView.swift
//  KeyType
//
//  The "Shortcuts" Settings pane: the keys used to accept a suggestion. Split out of SettingsView so
//  each sidebar category lives in its own file.
//

import SwiftUI

struct ShortcutsSettingsView: View {
    @Bindable var settings: SettingsStore

    var body: some View {
        Form {
            Section {
                KeyRecorderView(
                    title: "Accept word",
                    subtitle: "Inserts the next word of the suggestion.",
                    shortcut: settings.acceptWordShortcut,
                    onChange: { settings.acceptWordShortcut = $0 },
                    onClear: { settings.acceptWordShortcut = .unassigned },
                    onReset: settings.acceptWordShortcut != .defaultAcceptWord
                        ? { settings.acceptWordShortcut = .defaultAcceptWord } : nil
                )
                KeyRecorderView(
                    title: "Accept entire suggestion",
                    subtitle: "Inserts the whole suggestion at once.",
                    shortcut: settings.acceptFullShortcut,
                    onChange: { settings.acceptFullShortcut = $0 },
                    onClear: { settings.acceptFullShortcut = .unassigned },
                    onReset: settings.acceptFullShortcut != .defaultAcceptFull
                        ? { settings.acceptFullShortcut = .defaultAcceptFull } : nil
                )
                KeyRecorderView(
                    title: "Accept correction",
                    subtitle: "Replaces the misspelled word with the shown fix.",
                    shortcut: settings.acceptCorrectionShortcut,
                    onChange: { settings.acceptCorrectionShortcut = $0 },
                    onClear: { settings.acceptCorrectionShortcut = .unassigned },
                    onReset: settings.acceptCorrectionShortcut != .defaultAcceptCorrection
                        ? { settings.acceptCorrectionShortcut = .defaultAcceptCorrection } : nil
                )
            } header: {
                Text("Acceptance keys")
            } footer: {
                Text("Clear a shortcut to leave that action unassigned.")
            }
        }
        .formStyle(.grouped)
    }
}
