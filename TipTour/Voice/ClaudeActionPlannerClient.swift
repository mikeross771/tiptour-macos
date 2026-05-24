import Foundation

struct ClaudeActionPlannerResult {
    let plan: WorkflowPlan
}

struct ClaudeActionPlannerClient {
    private struct MessagesRequest: Encodable {
        let model: String
        let maxTokens: Int
        let system: String
        let messages: [Message]

        enum CodingKeys: String, CodingKey {
            case model
            case maxTokens = "max_tokens"
            case system
            case messages
        }
    }

    private struct Message: Encodable {
        let role: String
        let content: [ContentBlock]
    }

    private struct ContentBlock: Encodable {
        let type: String
        let text: String?
        let source: ImageSource?

        static func text(_ text: String) -> ContentBlock {
            ContentBlock(type: "text", text: text, source: nil)
        }

        static func image(jpegData: Data) -> ContentBlock {
            ContentBlock(
                type: "image",
                text: nil,
                source: ImageSource(
                    type: "base64",
                    mediaType: "image/jpeg",
                    data: jpegData.base64EncodedString()
                )
            )
        }
    }

    private struct ImageSource: Encodable {
        let type: String
        let mediaType: String
        let data: String

        enum CodingKeys: String, CodingKey {
            case type
            case mediaType = "media_type"
            case data
        }
    }

    private struct MessagesResponse: Decodable {
        let content: [ResponseContentBlock]
    }

    private struct ResponseContentBlock: Decodable {
        let type: String
        let text: String?
    }

    func planNextAction(
        transcript: String,
        targetAppName: String?,
        captures: [CompanionScreenCapture],
        localTargets: [LocalPerceptionTargetCache.SnapshotTarget],
        appSkillInstructions: String?,
        focusHighlightContext: String?,
        apiKey: String
    ) async throws -> ClaudeActionPlannerResult {
        var contentBlocks: [ContentBlock] = [
            .text(userPrompt(
                transcript: transcript,
                targetAppName: targetAppName,
                captures: captures,
                localTargets: localTargets,
                appSkillInstructions: appSkillInstructions,
                focusHighlightContext: focusHighlightContext
            ))
        ]
        for capture in captures.prefix(2) {
            contentBlocks.append(.image(jpegData: capture.imageData))
        }

        let requestBody = MessagesRequest(
            model: "claude-sonnet-4-5-20250929",
            maxTokens: 1200,
            system: Self.systemPrompt,
            messages: [Message(role: "user", content: contentBlocks)]
        )

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONEncoder().encode(requestBody)

        let (data, response) = try await URLSession.shared.data(for: request)
        try ProviderRequestDiagnostics.validateHTTPResponse(
            response,
            data: data,
            serviceName: "Claude planner request",
            errorDomain: "ClaudeActionPlannerClient"
        )

        let decoded: MessagesResponse
        do {
            decoded = try JSONDecoder().decode(MessagesResponse.self, from: data)
        } catch {
            let responsePreview = ProviderRequestDiagnostics.responsePreview(from: data)
            throw NSError(
                domain: "ClaudeActionPlannerClient",
                code: -3,
                userInfo: [
                    NSLocalizedDescriptionKey: "Could not read Claude response JSON: \(error.localizedDescription). Response preview: \(responsePreview.isEmpty ? "<empty>" : responsePreview)"
                ]
            )
        }
        let text = decoded.content
            .compactMap(\.text)
            .joined(separator: "\n")

        if let result = parsePlannerResult(from: text) {
            return result
        }

        throw NSError(
            domain: "ClaudeActionPlannerClient",
            code: -2,
            userInfo: [NSLocalizedDescriptionKey: "Claude did not return a valid single-action workflow plan. Response text: \(Self.truncated(text, maxLength: 600))"]
        )
    }

    private static let systemPrompt = """
    You are TipTour's text-command desktop action planner. Convert the user's typed request plus current screen context into exactly one next desktop action.

    Return only JSON. No Markdown. No prose outside JSON.

    Schema:
    {
      "goal": "the user's goal",
      "app": "target app name if known",
      "steps": [
        {
          "type": "click | rightClick | doubleClick | openApp | openURL | keyboardShortcut | pressKey | type | setValue | scroll | observe",
          "label": "visible target label, app name, key, shortcut, or text",
          "target_id": "exact id from the local target list when clicking a visible target",
          "target_mark": 12,
          "value": "text, URL, or shortcut value when needed",
          "targetContext": "visibleElement | currentHighlight | currentSelection | focusedElement",
          "hint": "short action hint"
        }
      ]
    }

    Rules:
    - Emit exactly one step. TipTour will observe the result and ask again if more work remains.
    - Prefer visible local targets from the target list when clicking. If a listed target is the intended target, include its exact target_id and target_mark.
    - For menus, click the next visible menu item only. Do not skip ahead to submenu items that are not visible yet.
    - keyboardShortcut labels must be literal shortcuts like Cmd+A or Cmd+Shift+F. Never use semantic names like Select All, Copy, Paste, or Delete as keyboardShortcut labels.
    - pressKey labels must be one physical key like A, X, Delete, Return, or Escape.
    - If the app is not open and the user names it, use openApp.
    - If a confirmation menu is visible, choose the confirmation as the next action.
    - If the user refers to "this", "this area", "the highlighted part", or a provided TipTour focus highlight, set targetContext to currentHighlight for the step.
    - If replacing or editing highlighted text, emit one type/setValue/pressKey step against currentHighlight or currentSelection. Do not click the text first.
    - If there is not enough context, use observe with a useful hint.
    """

    private func userPrompt(
        transcript: String,
        targetAppName: String?,
        captures: [CompanionScreenCapture],
        localTargets: [LocalPerceptionTargetCache.SnapshotTarget],
        appSkillInstructions: String?,
        focusHighlightContext: String?
    ) -> String {
        let encodedTargets: String
        if let targetData = try? JSONEncoder().encode(Array(localTargets.prefix(120))),
           let targetJSON = String(data: targetData, encoding: .utf8) {
            encodedTargets = targetJSON
        } else {
            encodedTargets = "[]"
        }

        let screenSummary = captures.map { capture in
            "\(capture.label): \(capture.screenshotWidthInPixels)x\(capture.screenshotHeightInPixels) pixels, displayFrame=\(capture.displayFrame)"
        }.joined(separator: "\n")

        return """
        User typed:
        \(transcript)

        Target app under the user or frontmost app:
        \(targetAppName ?? "unknown")

        App skill instructions:
        \(appSkillInstructions ?? "none")

        Current TipTour focus highlight:
        \(focusHighlightContext ?? "none")

        Screenshots attached:
        \(captures.isEmpty ? "none" : screenSummary)

        Local UI/OCR targets available without screenshot streaming:
        \(encodedTargets)

        Produce the single next action now.
        """
    }

    private func parsePlannerResult(from text: String) -> ClaudeActionPlannerResult? {
        guard let jsonText = extractFirstJSONObject(from: text) else {
            return nil
        }

        if let plan = WorkflowPlan.parse(from: jsonText) {
            return ClaudeActionPlannerResult(plan: plan)
        }

        return nil
    }

    private func extractFirstJSONObject(from text: String) -> String? {
        var depth = 0
        var startIndex: String.Index?
        for index in text.indices {
            let character = text[index]
            if character == "{" {
                if depth == 0 { startIndex = index }
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0, let startIndex {
                    return String(text[startIndex...index])
                }
            }
        }
        return nil
    }

    private static func truncated(_ text: String, maxLength: Int) -> String {
        guard text.count > maxLength else { return text }
        let endIndex = text.index(text.startIndex, offsetBy: maxLength)
        return String(text[..<endIndex]) + "..."
    }
}
