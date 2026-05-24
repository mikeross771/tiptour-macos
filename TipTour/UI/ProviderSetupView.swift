//
//  ProviderSetupView.swift
//  TipTour
//
//  Hidden setup drawer content for local provider keys.
//

import SwiftUI

struct ProviderSetupView: View {
    @ObservedObject var companionManager: CompanionManager

    @State private var devGeminiKeyInput: String = ""
    @State private var devGeminiKeyStatus: String = ""
    @State private var devClaudeKeyInput: String = ""
    @State private var devClaudeKeyStatus: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            providerHeader
            apiKeyRows
        }
        .onAppear {
            devGeminiKeyInput = KeychainStore.geminiAPIKey ?? ""
            devClaudeKeyInput = KeychainStore.claudeAPIKey ?? ""
        }
    }

    private var providerHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "waveform.badge.mic")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(DS.Colors.accent)

                Text("Provider keys")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(DS.Colors.textSecondary)
            }
        }
    }

    private var apiKeyRows: some View {
        VStack(spacing: 2) {
            byokKeyRow(
                title: "Gemini",
                placeholder: "AIzaSy...",
                input: $devGeminiKeyInput,
                save: {
                    KeychainStore.geminiAPIKey = devGeminiKeyInput
                },
                clear: {
                    devGeminiKeyInput = ""
                    KeychainStore.geminiAPIKey = nil
                },
                status: $devGeminiKeyStatus,
                hasSavedKey: hasSavedGeminiKey
            )

            byokKeyRow(
                title: "Claude",
                placeholder: "sk-ant-...",
                input: $devClaudeKeyInput,
                save: {
                    KeychainStore.claudeAPIKey = devClaudeKeyInput
                },
                clear: {
                    devClaudeKeyInput = ""
                    KeychainStore.claudeAPIKey = nil
                },
                status: $devClaudeKeyStatus,
                hasSavedKey: hasSavedClaudeKey
            )
        }
        .padding(.horizontal, -10)
    }

    private var hasSavedGeminiKey: Bool {
        !(KeychainStore.geminiAPIKey ?? "").isEmpty
    }

    private var hasSavedClaudeKey: Bool {
        !(KeychainStore.claudeAPIKey ?? "").isEmpty
    }

    private func byokKeyRow(
        title: String,
        placeholder: String,
        input: Binding<String>,
        save: @escaping () -> Void,
        clear: @escaping () -> Void,
        status: Binding<String>,
        hasSavedKey: Bool
    ) -> some View {
        let trimmedInput = input.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let saveDisabled = trimmedInput.isEmpty
        return HStack(spacing: 8) {
            Image(systemName: "key")
                .font(.system(size: 10))
                .foregroundColor(hasSavedKey ? DS.Colors.accent : DS.Colors.textTertiary)
                .frame(width: 16)

            Text(title)
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textSecondary)
                .frame(width: 70, alignment: .leading)

            SecureField(placeholder, text: input)
                .textFieldStyle(.plain)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(DS.Colors.textPrimary)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.white.opacity(0.05))
                )

            Button {
                save()
                status.wrappedValue = "Saved"
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    if status.wrappedValue == "Saved" { status.wrappedValue = "" }
                }
            } label: {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(saveDisabled ? DS.Colors.textTertiary : .white)
                    .frame(width: 22, height: 20)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(saveDisabled ? Color.white.opacity(0.06) : DS.Colors.accent)
                    )
            }
            .buttonStyle(.plain)
            .disabled(saveDisabled)
            .pointerCursor()
            .help("Save")

            Button {
                clear()
                status.wrappedValue = "Cleared"
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    if status.wrappedValue == "Cleared" { status.wrappedValue = "" }
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(DS.Colors.textTertiary)
                    .frame(width: 22, height: 20)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color.white.opacity(0.06))
                    )
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .help("Clear")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }
}
