//
//  PointerActionRequest.swift
//  TipTour
//
//  Shared one-action request shape for voice, text, and harness callers.
//

import Foundation

struct PointerActionRequest {
    let goal: String
    let app: String?
    let actionType: WorkflowStep.StepType
    let targetLabel: String?
    let targetID: String?
    let targetMark: Int?
    let execute: Bool
    let allowScreenshotPlanning: Bool
    let validateStateChange: Bool
}
