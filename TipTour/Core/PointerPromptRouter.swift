//
//  PointerPromptRouter.swift
//  TipTour
//
//  Keeps input modes consistent by deciding which existing TipTour path
//  should handle a prompt before any voice/text-specific code gets involved.
//

import Foundation

struct PointerPromptRoute {
    enum Destination {
        case localAction(PointerActionRequest)
        case claudeOneStep
        case hermesLongTask
    }

    let destination: Destination
    let reason: String
}

enum PointerPromptRouter {
    static func route(
        prompt: String,
        targetAppName: String?,
        isHermesAutoEnabled: Bool
    ) -> PointerPromptRoute {
        if isHermesAutoEnabled, looksLikeLongRunningTask(prompt) {
            return PointerPromptRoute(
                destination: .hermesLongTask,
                reason: "long_running_task"
            )
        }

        if let localTargetLabel = directPointerTargetLabel(from: prompt) {
            return PointerPromptRoute(
                destination: .localAction(
                    PointerActionRequest(
                        goal: prompt,
                        app: targetAppName,
                        actionType: .click,
                        targetLabel: localTargetLabel,
                        targetID: nil,
                        targetMark: nil,
                        execute: true,
                        allowScreenshotPlanning: true,
                        validateStateChange: true
                    )
                ),
                reason: "direct_pointer_command"
            )
        }

        return PointerPromptRoute(
            destination: .claudeOneStep,
            reason: "one_step_planner"
        )
    }

    private static func directPointerTargetLabel(from prompt: String) -> String? {
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else { return nil }

        let lowercasedPrompt = trimmedPrompt.lowercased()
        let directPrefixes = [
            "click on ",
            "click the ",
            "click ",
            "tap on ",
            "tap the ",
            "tap ",
            "choose the ",
            "choose ",
            "select the ",
            "select ",
            "go to the ",
            "go to ",
            "open the ",
            "open "
        ]

        guard let matchedPrefix = directPrefixes.first(where: { lowercasedPrompt.hasPrefix($0) }) else {
            return nil
        }

        if looksLikeApplicationLaunch(lowercasedPrompt) {
            return nil
        }

        let labelStartIndex = trimmedPrompt.index(trimmedPrompt.startIndex, offsetBy: matchedPrefix.count)
        let rawLabel = String(trimmedPrompt[labelStartIndex...])
        let normalizedLabel = cleanDirectTargetLabel(rawLabel)
        return normalizedLabel.isEmpty ? nil : normalizedLabel
    }

    private static func cleanDirectTargetLabel(_ rawLabel: String) -> String {
        var label = rawLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        label = label.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`.,!?"))

        let lowercasedLabel = label.lowercased()
        let trailingPhrases = [
            " button",
            " menu",
            " menu item",
            " tab",
            " option",
            " dropdown"
        ]

        for phrase in trailingPhrases where lowercasedLabel.hasSuffix(phrase) {
            label = String(label.dropLast(phrase.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            break
        }

        return label.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`.,!?"))
    }

    private static func looksLikeApplicationLaunch(_ lowercasedPrompt: String) -> Bool {
        let applicationNames = [
            "open blender",
            "open chrome",
            "open google chrome",
            "open safari",
            "open xcode",
            "open terminal",
            "open notes",
            "open apple notes",
            "go to blender",
            "go to chrome",
            "go to google chrome",
            "go to safari",
            "go to xcode",
            "go to terminal",
            "go to notes",
            "go to apple notes"
        ]
        return applicationNames.contains { lowercasedPrompt.hasPrefix($0) }
    }

    private static func looksLikeLongRunningTask(_ prompt: String) -> Bool {
        let normalizedPrompt = prompt
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let longTaskSignals = [
            " and then ",
            " then ",
            " after that ",
            " workflow",
            " automate",
            " build ",
            " create ",
            " make ",
            " finish ",
            " repeat ",
            " until ",
            " house",
            " scene",
            " model "
        ]

        if longTaskSignals.contains(where: { normalizedPrompt.contains($0) }) {
            return true
        }

        let commandConjunctionCount = normalizedPrompt
            .components(separatedBy: " and ")
            .count - 1
        return commandConjunctionCount >= 2 || normalizedPrompt.count > 140
    }
}
