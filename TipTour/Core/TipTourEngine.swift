//
//  TipTourEngine.swift
//  TipTour
//
//  Thin engine facade for callers that should not know about
//  CompanionManager. Keep this small: it centralizes observe + one-action
//  workflow submission before we add richer ground/act/record APIs.
//

import AppKit
import Foundation

struct TipTourEngineSubmissionResult: Encodable {
    let ok: Bool
    let reason: String?
    let message: String?
    let acceptedSteps: Int
    let ignoredSteps: Int
    let activeApp: String?
}

struct TipTourEngineObservation: Encodable {
    let ok: Bool
    let activeAppName: String?
    let activeBundleIdentifier: String?
    let activePlanGoal: String?
    let isAutopilotEnabled: Bool
    let isScreenshotStreamingEnabled: Bool
    let isAccurateGroundingEnabled: Bool
    let isCuaActionDriverEnabled: Bool
    let isHermesOrchestratorEnabled: Bool
    let detectionElementCount: Int
}

struct TipTourEngineTargetList: Encodable {
    let ok: Bool
    let refreshed: Bool
    let activeAppName: String?
    let activeBundleIdentifier: String?
    let targetCount: Int
    let targets: [LocalPerceptionTargetCache.SnapshotTarget]
}

struct TipTourEnginePlannedActionStep: Encodable {
    let type: String
    let label: String
    let hint: String
    let box2D: [Int]
    let matchedSource: String
    let matchedConfidence: Double
}

struct TipTourEngineWorkflowOutcome: Encodable {
    let status: String
    let reason: String?
    let message: String?
    let waitMs: Int
}

struct TipTourEngineActionValidation: Encodable {
    let stateChanged: Bool
    let requiredStateChange: Bool
    let beforeTargetCount: Int
    let afterTargetCount: Int
}

struct TipTourEngineActionAttempt: Encodable {
    let attemptNumber: Int
    let timestamp: String
    let target: LocalPerceptionTargetCache.SnapshotTarget
    let plannedStep: TipTourEnginePlannedActionStep
    let submission: TipTourEngineSubmissionResult
    let workflowOutcome: TipTourEngineWorkflowOutcome
    let validation: TipTourEngineActionValidation
}

struct TipTourEngineActionHistory: Encodable {
    let ok: Bool
    let attempts: [TipTourEngineActionAttempt]
}

struct TipTourEnginePlanNextActionResult: Encodable {
    let ok: Bool
    let reason: String?
    let message: String?
    let activeApp: String?
    let plannedStep: TipTourEnginePlannedActionStep?
    let submission: TipTourEngineSubmissionResult?
    let workflowOutcome: TipTourEngineWorkflowOutcome?
    let validation: TipTourEngineActionValidation?
    let attempts: [TipTourEngineActionAttempt]
    let repaired: Bool
    let targets: [LocalPerceptionTargetCache.SnapshotTarget]
}

@MainActor
final class TipTourEngine {
    private let isAutopilotEnabledProvider: () -> Bool
    private let isMultiStepTourGuideEnabledProvider: () -> Bool
    private let isScreenshotStreamingEnabledProvider: () -> Bool
    private let isAccurateGroundingEnabledProvider: () -> Bool
    private let isCuaActionDriverEnabledProvider: () -> Bool
    private let isHermesOrchestratorEnabledProvider: () -> Bool
    private let detectionElementCountProvider: () -> Int
    private let refreshLocalPerception: (String) async -> Void
    private let normalizeWorkflowSteps: ([WorkflowStep], String) -> [WorkflowStep]
    private let startWorkflowPlan: (WorkflowPlan) -> Void
    private var recentActionAttempts: [TipTourEngineActionAttempt] = []
    private let maximumRecentActionAttempts = 24
    private let workflowSettlementTimeoutSeconds: TimeInterval = 7.0

    init(
        isAutopilotEnabledProvider: @escaping () -> Bool,
        isMultiStepTourGuideEnabledProvider: @escaping () -> Bool,
        isScreenshotStreamingEnabledProvider: @escaping () -> Bool,
        isAccurateGroundingEnabledProvider: @escaping () -> Bool,
        isCuaActionDriverEnabledProvider: @escaping () -> Bool,
        isHermesOrchestratorEnabledProvider: @escaping () -> Bool,
        detectionElementCountProvider: @escaping () -> Int,
        refreshLocalPerception: @escaping (String) async -> Void,
        normalizeWorkflowSteps: @escaping ([WorkflowStep], String) -> [WorkflowStep],
        startWorkflowPlan: @escaping (WorkflowPlan) -> Void
    ) {
        self.isAutopilotEnabledProvider = isAutopilotEnabledProvider
        self.isMultiStepTourGuideEnabledProvider = isMultiStepTourGuideEnabledProvider
        self.isScreenshotStreamingEnabledProvider = isScreenshotStreamingEnabledProvider
        self.isAccurateGroundingEnabledProvider = isAccurateGroundingEnabledProvider
        self.isCuaActionDriverEnabledProvider = isCuaActionDriverEnabledProvider
        self.isHermesOrchestratorEnabledProvider = isHermesOrchestratorEnabledProvider
        self.detectionElementCountProvider = detectionElementCountProvider
        self.refreshLocalPerception = refreshLocalPerception
        self.normalizeWorkflowSteps = normalizeWorkflowSteps
        self.startWorkflowPlan = startWorkflowPlan
    }

    func observe() -> TipTourEngineObservation {
        let activeApp = NSWorkspace.shared.frontmostApplication
        return TipTourEngineObservation(
            ok: true,
            activeAppName: activeApp?.localizedName,
            activeBundleIdentifier: activeApp?.bundleIdentifier,
            activePlanGoal: WorkflowRunner.shared.activePlan?.goal,
            isAutopilotEnabled: isAutopilotEnabledProvider(),
            isScreenshotStreamingEnabled: isScreenshotStreamingEnabledProvider(),
            isAccurateGroundingEnabled: isAccurateGroundingEnabledProvider(),
            isCuaActionDriverEnabled: isCuaActionDriverEnabledProvider(),
            isHermesOrchestratorEnabled: isHermesOrchestratorEnabledProvider(),
            detectionElementCount: detectionElementCountProvider()
        )
    }

    func localPerceptionTargets(refresh: Bool, reason: String = "harness requested targets") async -> TipTourEngineTargetList {
        if refresh {
            await refreshLocalPerception(reason)
        }

        let activeApp = NSWorkspace.shared.frontmostApplication
        let targets = LocalPerceptionTargetCache.shared.currentTargets()
        return TipTourEngineTargetList(
            ok: true,
            refreshed: refresh,
            activeAppName: activeApp?.localizedName,
            activeBundleIdentifier: activeApp?.bundleIdentifier,
            targetCount: targets.count,
            targets: targets
        )
    }

    func actionHistory() -> TipTourEngineActionHistory {
        TipTourEngineActionHistory(
            ok: true,
            attempts: recentActionAttempts
        )
    }

    func planNextAction(
        goal: String,
        app: String?,
        requestedActionType: WorkflowStep.StepType,
        requestedTargetLabel: String?,
        execute: Bool,
        allowScreenshotPlanning: Bool,
        validateStateChange: Bool
    ) async -> TipTourEnginePlanNextActionResult {
        await refreshLocalPerception("harness plan-next-action")

        let targets = LocalPerceptionTargetCache.shared.currentTargets()
        guard !targets.isEmpty else {
            return TipTourEnginePlanNextActionResult(
                ok: false,
                reason: "no_local_targets",
                message: "No local YOLO/OCR targets are available yet. Turn on Accurate Grounding or wait for a fresh perception pass.",
                activeApp: NSWorkspace.shared.frontmostApplication?.localizedName,
                plannedStep: nil,
                submission: nil,
                workflowOutcome: nil,
                validation: nil,
                attempts: [],
                repaired: false,
                targets: []
            )
        }

        guard let matchedTarget = bestTarget(
            requestedLabel: requestedTargetLabel,
            goal: goal,
            targets: targets,
            excludingTargetIDs: []
        ) else {
            let reason = allowScreenshotPlanning ? "needs_screenshot_planner" : "target_not_found"
            let message = allowScreenshotPlanning
                ? "No local target matched. Screenshot planning can be added here, but this endpoint currently refuses to guess raw coordinates."
                : "No local target matched the requested label or goal."
            return TipTourEnginePlanNextActionResult(
                ok: false,
                reason: reason,
                message: message,
                activeApp: NSWorkspace.shared.frontmostApplication?.localizedName,
                plannedStep: nil,
                submission: nil,
                workflowOutcome: nil,
                validation: nil,
                attempts: [],
                repaired: false,
                targets: targets
            )
        }

        let plannedStep = plannedActionStep(
            actionType: requestedActionType,
            target: matchedTarget
        )

        guard execute else {
            return TipTourEnginePlanNextActionResult(
                ok: true,
                reason: nil,
                message: "Planned one grounded TipTour action.",
                activeApp: NSWorkspace.shared.frontmostApplication?.localizedName,
                plannedStep: plannedStep,
                submission: nil,
                workflowOutcome: nil,
                validation: nil,
                attempts: [],
                repaired: false,
                targets: targets
            )
        }

        let executionResult = await executeGroundedActionWithOneRepair(
            goal: goal,
            app: app,
            requestedActionType: requestedActionType,
            requestedTargetLabel: requestedTargetLabel,
            initialTarget: matchedTarget,
            initialTargets: targets,
            requireStateChange: validateStateChange
        )

        return TipTourEnginePlanNextActionResult(
            ok: executionResult.ok,
            reason: executionResult.reason,
            message: executionResult.message,
            activeApp: NSWorkspace.shared.frontmostApplication?.localizedName,
            plannedStep: executionResult.attempts.first?.plannedStep ?? plannedStep,
            submission: executionResult.attempts.last?.submission,
            workflowOutcome: executionResult.attempts.last?.workflowOutcome,
            validation: executionResult.attempts.last?.validation,
            attempts: executionResult.attempts,
            repaired: executionResult.repaired,
            targets: executionResult.latestTargets
        )
    }

    func submitSingleActionWorkflowPlan(_ plan: WorkflowPlan) -> TipTourEngineSubmissionResult {
        guard isAutopilotEnabledProvider() || isMultiStepTourGuideEnabledProvider() else {
            return TipTourEngineSubmissionResult(
                ok: false,
                reason: "autopilot_disabled",
                message: "TipTour Autopilot is off. Turn it on before external harnesses can execute actions.",
                acceptedSteps: 0,
                ignoredSteps: plan.steps.count,
                activeApp: NSWorkspace.shared.frontmostApplication?.localizedName
            )
        }

        guard isCuaActionDriverEnabledProvider() else {
            return TipTourEngineSubmissionResult(
                ok: false,
                reason: "action_driver_disabled",
                message: "CUA Driver is off. Turn it on before TipTour can execute desktop actions.",
                acceptedSteps: 0,
                ignoredSteps: plan.steps.count,
                activeApp: NSWorkspace.shared.frontmostApplication?.localizedName
            )
        }

        if let activePlan = WorkflowRunner.shared.activePlan {
            print("[Engine] superseding active plan \"\(activePlan.goal)\" with \"\(plan.goal)\"")
            WorkflowRunner.shared.stop()
        }

        let normalizedSteps = normalizeWorkflowSteps(
            plan.steps,
            plan.app ?? ""
        )
        guard let firstStep = normalizedSteps.first else {
            return TipTourEngineSubmissionResult(
                ok: false,
                reason: "empty_steps",
                message: "Workflow plan must contain at least one step.",
                acceptedSteps: 0,
                ignoredSteps: 0,
                activeApp: NSWorkspace.shared.frontmostApplication?.localizedName
            )
        }

        let singleActionPlan = WorkflowPlan(
            goal: plan.goal,
            app: plan.app,
            steps: [firstStep]
        )
        let ignoredSteps = max(0, normalizedSteps.count - 1)
        if ignoredSteps > 0 {
            print("[Engine] single-action mode: ignoring \(ignoredSteps) extra step(s)")
        }

        print("[Engine] accepted workflow plan \"\(singleActionPlan.goal)\" -> \(firstStep.label ?? "<unlabeled>")")
        startWorkflowPlan(singleActionPlan)

        return TipTourEngineSubmissionResult(
            ok: true,
            reason: nil,
            message: "Accepted one TipTour action.",
            acceptedSteps: 1,
            ignoredSteps: ignoredSteps,
            activeApp: NSWorkspace.shared.frontmostApplication?.localizedName
        )
    }

    private func bestTarget(
        requestedLabel: String?,
        goal: String,
        targets: [LocalPerceptionTargetCache.SnapshotTarget],
        excludingTargetIDs: Set<String>
    ) -> LocalPerceptionTargetCache.SnapshotTarget? {
        let availableTargets = targets.filter { !excludingTargetIDs.contains($0.id) }
        guard !availableTargets.isEmpty else { return nil }

        let query = requestedLabel?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let query, !query.isEmpty {
            return availableTargets
                .compactMap { target -> (target: LocalPerceptionTargetCache.SnapshotTarget, score: Double)? in
                    guard let score = labelMatchScore(query: query, label: target.label) else { return nil }
                    return (target, score + sourceScore(target.source) + min(target.confidence, 1.0))
                }
                .max { $0.score < $1.score }?
                .target
        }

        return availableTargets
            .compactMap { target -> (target: LocalPerceptionTargetCache.SnapshotTarget, score: Double)? in
                guard let score = labelMatchScore(query: goal, label: target.label) else { return nil }
                return (target, score + sourceScore(target.source) + min(target.confidence, 1.0))
            }
            .max { $0.score < $1.score }?
            .target
    }

    private func labelMatchScore(query: String, label: String) -> Double? {
        let queryWords = meaningfulWords(from: query)
        let labelWords = meaningfulWords(from: label)
        guard !queryWords.isEmpty, !labelWords.isEmpty else { return nil }

        let normalizedQuery = queryWords.joined(separator: " ")
        let normalizedLabel = labelWords.joined(separator: " ")
        if normalizedQuery == normalizedLabel { return 100 }
        if normalizedQuery.contains(normalizedLabel) || normalizedLabel.contains(normalizedQuery) {
            return 72
        }

        let sharedWords = Set(queryWords).intersection(Set(labelWords))
        guard !sharedWords.isEmpty else { return nil }
        return 36 + (Double(sharedWords.count) / Double(max(labelWords.count, 1)) * 28)
    }

    private func meaningfulWords(from text: String) -> [String] {
        let stopWords: Set<String> = [
            "the", "a", "an", "this", "that", "button", "menu", "item",
            "click", "press", "choose", "select"
        ]
        let words = text
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { !stopWords.contains($0) }
        return words.isEmpty
            ? text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
            : words
    }

    private func sourceScore(_ source: String) -> Double {
        source == "ocr" ? 4 : 1
    }

    private struct GroundedActionExecutionResult {
        let ok: Bool
        let reason: String?
        let message: String?
        let attempts: [TipTourEngineActionAttempt]
        let repaired: Bool
        let latestTargets: [LocalPerceptionTargetCache.SnapshotTarget]
    }

    private func executeGroundedActionWithOneRepair(
        goal: String,
        app: String?,
        requestedActionType: WorkflowStep.StepType,
        requestedTargetLabel: String?,
        initialTarget: LocalPerceptionTargetCache.SnapshotTarget,
        initialTargets: [LocalPerceptionTargetCache.SnapshotTarget],
        requireStateChange: Bool
    ) async -> GroundedActionExecutionResult {
        var attempts: [TipTourEngineActionAttempt] = []
        var attemptedTargetIDs = Set<String>()
        var currentTarget: LocalPerceptionTargetCache.SnapshotTarget? = initialTarget
        var targetsBeforeAttempt = initialTargets

        for attemptNumber in 1...2 {
            guard let target = currentTarget else {
                let lastAttempt = attempts.last
                let reason = lastAttempt?.validation.requiredStateChange == true
                    && lastAttempt?.validation.stateChanged == false
                    ? "state_unchanged"
                    : "repair_target_not_found"
                return GroundedActionExecutionResult(
                    ok: false,
                    reason: reason,
                    message: "The first target did not validate, and no alternate local target matched after refreshing perception.",
                    attempts: attempts,
                    repaired: attemptNumber > 1,
                    latestTargets: targetsBeforeAttempt
                )
            }

            attemptedTargetIDs.insert(target.id)
            let attempt = await executeGroundedActionAttempt(
                attemptNumber: attemptNumber,
                goal: goal,
                app: app,
                actionType: requestedActionType,
                target: target,
                targetsBeforeAttempt: targetsBeforeAttempt,
                requireStateChange: requireStateChange
            )
            attempts.append(attempt)
            recordActionAttempt(attempt)

            if attempt.submission.ok,
               attempt.workflowOutcome.status == "completed",
               (!attempt.validation.requiredStateChange || attempt.validation.stateChanged) {
                return GroundedActionExecutionResult(
                    ok: true,
                    reason: nil,
                    message: attemptNumber == 1
                        ? "Executed one grounded TipTour action."
                        : "Executed one grounded TipTour action after refreshing local perception.",
                    attempts: attempts,
                    repaired: attemptNumber > 1,
                    latestTargets: LocalPerceptionTargetCache.shared.currentTargets()
                )
            }

            guard attemptNumber == 1 else { break }
            await refreshLocalPerception("harness repair after failed grounded action")
            targetsBeforeAttempt = LocalPerceptionTargetCache.shared.currentTargets()
            currentTarget = bestTarget(
                requestedLabel: requestedTargetLabel,
                goal: goal,
                targets: targetsBeforeAttempt,
                excludingTargetIDs: attemptedTargetIDs
            )
        }

        let lastAttempt = attempts.last
        let reason: String
        if lastAttempt?.submission.ok == false {
            reason = lastAttempt?.submission.reason ?? "submission_failed"
        } else if lastAttempt?.workflowOutcome.status != "completed" {
            reason = lastAttempt?.workflowOutcome.reason ?? lastAttempt?.workflowOutcome.status ?? "workflow_not_completed"
        } else if lastAttempt?.validation.requiredStateChange == true,
                  lastAttempt?.validation.stateChanged == false {
            reason = "state_unchanged"
        } else {
            reason = "grounded_action_failed"
        }

        return GroundedActionExecutionResult(
            ok: false,
            reason: reason,
            message: "TipTour could not validate the grounded action after a local repair attempt.",
            attempts: attempts,
            repaired: attempts.count > 1,
            latestTargets: LocalPerceptionTargetCache.shared.currentTargets()
        )
    }

    private func executeGroundedActionAttempt(
        attemptNumber: Int,
        goal: String,
        app: String?,
        actionType: WorkflowStep.StepType,
        target: LocalPerceptionTargetCache.SnapshotTarget,
        targetsBeforeAttempt: [LocalPerceptionTargetCache.SnapshotTarget],
        requireStateChange: Bool
    ) async -> TipTourEngineActionAttempt {
        let step = workflowStep(
            actionType: actionType,
            target: target,
            id: "harness_planned_step_\(attemptNumber)"
        )
        let plannedStep = plannedActionStep(
            actionType: actionType,
            target: target
        )
        let submission = submitSingleActionWorkflowPlan(
            WorkflowPlan(
                goal: goal,
                app: app,
                steps: [step]
            )
        )

        let workflowOutcome: TipTourEngineWorkflowOutcome
        if submission.ok {
            workflowOutcome = await waitForWorkflowSettlement()
        } else {
            workflowOutcome = TipTourEngineWorkflowOutcome(
                status: "not_started",
                reason: submission.reason,
                message: submission.message,
                waitMs: 0
            )
        }

        await refreshLocalPerception("harness post-action validation")
        let targetsAfterAttempt = LocalPerceptionTargetCache.shared.currentTargets()
        let validation = validateTargetSetChange(
            beforeTargets: targetsBeforeAttempt,
            afterTargets: targetsAfterAttempt,
            requireStateChange: requireStateChange
        )

        return TipTourEngineActionAttempt(
            attemptNumber: attemptNumber,
            timestamp: Self.iso8601Formatter.string(from: Date()),
            target: target,
            plannedStep: plannedStep,
            submission: submission,
            workflowOutcome: workflowOutcome,
            validation: validation
        )
    }

    private func workflowStep(
        actionType: WorkflowStep.StepType,
        target: LocalPerceptionTargetCache.SnapshotTarget,
        id: String
    ) -> WorkflowStep {
        WorkflowStep(
            id: id,
            type: actionType,
            label: target.label,
            value: nil,
            direction: nil,
            amount: nil,
            by: nil,
            targetContext: .visibleElement,
            hint: "Use local perception target \"\(target.label)\"",
            hintX: nil,
            hintY: nil,
            box2DNormalized: target.normalizedBox2D,
            screenNumber: nil
        )
    }

    private func plannedActionStep(
        actionType: WorkflowStep.StepType,
        target: LocalPerceptionTargetCache.SnapshotTarget
    ) -> TipTourEnginePlannedActionStep {
        TipTourEnginePlannedActionStep(
            type: actionType.rawValue,
            label: target.label,
            hint: "Use local perception target \"\(target.label)\"",
            box2D: target.normalizedBox2D,
            matchedSource: target.source,
            matchedConfidence: target.confidence
        )
    }

    private func waitForWorkflowSettlement() async -> TipTourEngineWorkflowOutcome {
        let startedAt = Date()
        let deadline = startedAt.addingTimeInterval(workflowSettlementTimeoutSeconds)

        while Date() < deadline {
            if let pausedReason = WorkflowRunner.shared.pausedReason {
                return TipTourEngineWorkflowOutcome(
                    status: "paused",
                    reason: "workflow_paused",
                    message: pausedReason.humanReadable,
                    waitMs: Self.elapsedMilliseconds(since: startedAt)
                )
            }

            if let failedLabel = WorkflowRunner.shared.currentStepResolutionFailureLabel {
                return TipTourEngineWorkflowOutcome(
                    status: "resolution_failed",
                    reason: "target_not_resolved",
                    message: "Could not resolve \"\(failedLabel)\" within WorkflowRunner's retry budget.",
                    waitMs: Self.elapsedMilliseconds(since: startedAt)
                )
            }

            if WorkflowRunner.shared.activePlan == nil {
                return TipTourEngineWorkflowOutcome(
                    status: "completed",
                    reason: nil,
                    message: "WorkflowRunner completed the single action.",
                    waitMs: Self.elapsedMilliseconds(since: startedAt)
                )
            }

            try? await Task.sleep(nanoseconds: 100_000_000)
        }

        return TipTourEngineWorkflowOutcome(
            status: "timed_out",
            reason: "workflow_settlement_timeout",
            message: "WorkflowRunner did not complete or pause within \(workflowSettlementTimeoutSeconds)s.",
            waitMs: Self.elapsedMilliseconds(since: startedAt)
        )
    }

    private func validateTargetSetChange(
        beforeTargets: [LocalPerceptionTargetCache.SnapshotTarget],
        afterTargets: [LocalPerceptionTargetCache.SnapshotTarget],
        requireStateChange: Bool
    ) -> TipTourEngineActionValidation {
        TipTourEngineActionValidation(
            stateChanged: targetSetSignature(beforeTargets) != targetSetSignature(afterTargets),
            requiredStateChange: requireStateChange,
            beforeTargetCount: beforeTargets.count,
            afterTargetCount: afterTargets.count
        )
    }

    private func targetSetSignature(_ targets: [LocalPerceptionTargetCache.SnapshotTarget]) -> String {
        targets
            .map { target in
                let quantizedBox = target.normalizedBox2D
                    .map { coordinate in
                        Int((Double(coordinate) / 10.0).rounded()) * 10
                    }
                    .map(String.init)
                    .joined(separator: ",")
                return "\(target.source):\(target.label.lowercased()):\(quantizedBox)"
            }
            .sorted()
            .joined(separator: "|")
    }

    private func recordActionAttempt(_ attempt: TipTourEngineActionAttempt) {
        recentActionAttempts.append(attempt)
        if recentActionAttempts.count > maximumRecentActionAttempts {
            recentActionAttempts.removeFirst(recentActionAttempts.count - maximumRecentActionAttempts)
        }
    }

    private static func elapsedMilliseconds(since startDate: Date) -> Int {
        Int(Date().timeIntervalSince(startDate) * 1000)
    }

    private static let iso8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
