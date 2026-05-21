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

@MainActor
final class TipTourEngine {
    private let isAutopilotEnabledProvider: () -> Bool
    private let isMultiStepTourGuideEnabledProvider: () -> Bool
    private let isScreenshotStreamingEnabledProvider: () -> Bool
    private let isAccurateGroundingEnabledProvider: () -> Bool
    private let isCuaActionDriverEnabledProvider: () -> Bool
    private let isHermesOrchestratorEnabledProvider: () -> Bool
    private let detectionElementCountProvider: () -> Int
    private let normalizeWorkflowSteps: ([WorkflowStep], String) -> [WorkflowStep]
    private let startWorkflowPlan: (WorkflowPlan) -> Void

    init(
        isAutopilotEnabledProvider: @escaping () -> Bool,
        isMultiStepTourGuideEnabledProvider: @escaping () -> Bool,
        isScreenshotStreamingEnabledProvider: @escaping () -> Bool,
        isAccurateGroundingEnabledProvider: @escaping () -> Bool,
        isCuaActionDriverEnabledProvider: @escaping () -> Bool,
        isHermesOrchestratorEnabledProvider: @escaping () -> Bool,
        detectionElementCountProvider: @escaping () -> Int,
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
}
