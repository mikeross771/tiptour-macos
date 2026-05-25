//
//  TipTourTests.swift
//  TipTourTests
//
//  Created by thorfinn on 3/2/26.
//

import Testing
@testable import TipTour

struct TipTourTests {

    @Test func firstPermissionRequestUsesSystemPromptOnly() async throws {
        let presentationDestination = WindowPositionManager.permissionRequestPresentationDestination(
            hasPermissionNow: false,
            hasAttemptedSystemPrompt: false
        )

        #expect(presentationDestination == .systemPrompt)
    }

    @Test func repeatedPermissionRequestOpensSystemSettings() async throws {
        let presentationDestination = WindowPositionManager.permissionRequestPresentationDestination(
            hasPermissionNow: false,
            hasAttemptedSystemPrompt: true
        )

        #expect(presentationDestination == .systemSettings)
    }

    @Test func knownGrantedScreenRecordingPermissionSkipsTheGate() async throws {
        let shouldTreatPermissionAsGranted = WindowPositionManager.shouldTreatScreenRecordingPermissionAsGrantedForSessionLaunch(
            hasScreenRecordingPermissionNow: false,
            hasPreviouslyConfirmedScreenRecordingPermission: true
        )

        #expect(shouldTreatPermissionAsGranted)
    }

    @Test func multiAppPromptRoutesToHermesBeforePointerShortcut() async throws {
        let route = PointerPromptRouter.route(
            prompt: "Go to Chrome and download an asset and then put it in Blender",
            targetAppName: "Blender",
            isHermesAutoEnabled: true
        )

        if case .hermesLongTask = route.destination {
            #expect(route.reason == "long_running_task")
        } else {
            Issue.record("Expected long multi-app command to route to Hermes")
        }
    }

    @Test func goToApplicationIsNotTreatedAsLocalClickTarget() async throws {
        let route = PointerPromptRouter.route(
            prompt: "go to Chrome",
            targetAppName: "Blender",
            isHermesAutoEnabled: true
        )

        if case .localAction = route.destination {
            Issue.record("Expected app switch command not to become a Blender-local click")
        }
    }

    @Test func directVisibleClickStillRoutesLocally() async throws {
        let route = PointerPromptRouter.route(
            prompt: "click Add",
            targetAppName: "Blender",
            isHermesAutoEnabled: true
        )

        if case .localAction(let request) = route.destination {
            #expect(request.app == "Blender")
            #expect(request.targetLabel == "Add")
        } else {
            Issue.record("Expected direct click to stay on the local pointer path")
        }
    }

}
