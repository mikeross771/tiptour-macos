import Foundation
import Darwin

struct NanoClawConnectionStatus: Equatable {
    enum Mode: Equatable {
        case api
        case cli
        case localChat
        case none
    }

    var state: HermesConnectionState
    var mode: Mode
    var baseURL: String
    var cliExecutablePath: String
    var detail: String
    var detectedInstallPath: String?

    static let idle = NanoClawConnectionStatus(
        state: .idle,
        mode: .none,
        baseURL: TipTourDefaults.nanoClawAPIBaseURL,
        cliExecutablePath: TipTourDefaults.nanoClawCLIExecutablePath,
        detail: "NanoClaw has not been checked yet.",
        detectedInstallPath: nil
    )
}

struct NanoClawInstallInspection: Equatable {
    let nanoClawHome: String?
    let cliExecutablePath: String?
    let localChatDirectory: String?
    let isInstalled: Bool
    let isConfigured: Bool
}

struct NanoClawAgentStreamResult {
    let responseText: String
    let sessionID: String?
}

struct NanoClawAgentClient {
    private struct ChatRequest: Encodable {
        let model: String
        let messages: [Message]
        let stream: Bool
        let sessionID: String?

        enum CodingKeys: String, CodingKey {
            case model
            case messages
            case stream
            case sessionID = "session_id"
        }
    }

    private struct Message: Encodable {
        let role: String
        let content: String
    }

    func streamPrompt(
        _ prompt: String,
        resumeSessionID: String?,
        onChunk: @escaping (String) async -> Void,
        onToolProgress: @escaping (String) async -> Void,
        onStatus: @escaping (String) async -> Void = { _ in }
    ) async throws -> NanoClawAgentStreamResult {
        let status = await testAPIConnection(baseURL: TipTourDefaults.nanoClawAPIBaseURL)
        if status.state == .connected {
            return try await streamPromptViaAPI(
                prompt,
                baseURL: status.baseURL,
                resumeSessionID: resumeSessionID,
                onChunk: onChunk,
                onToolProgress: onToolProgress,
                onStatus: onStatus
            )
        }

        if Self.resolveCLIExecutablePath(TipTourDefaults.nanoClawCLIExecutablePath) != nil {
            await onStatus("NanoClaw CLI ready - using claw")
            return try await streamPromptViaCLI(
                prompt,
                resumeSessionID: resumeSessionID,
                onChunk: onChunk,
                onStatus: onStatus
            )
        }

        await onStatus("NanoClaw local chat ready")
        return try await streamPromptViaLocalChat(
            prompt,
            resumeSessionID: resumeSessionID,
            onChunk: onChunk,
            onStatus: onStatus
        )
    }

    private func streamPromptViaAPI(
        _ prompt: String,
        baseURL: String,
        resumeSessionID: String?,
        onChunk: @escaping (String) async -> Void,
        onToolProgress: @escaping (String) async -> Void,
        onStatus: @escaping (String) async -> Void
    ) async throws -> NanoClawAgentStreamResult {
        let endpoint = Self.endpointURL(baseURL: baseURL, path: "/v1/chat/completions")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONEncoder().encode(
            ChatRequest(
                model: "nanoclaw-agent",
                messages: [
                    Message(role: "system", content: Self.systemPrompt()),
                    Message(role: "user", content: prompt)
                ],
                stream: true,
                sessionID: resumeSessionID
            )
        )

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        try validateHTTPResponse(response)
        await onStatus("NanoClaw connected - waiting for output")

        let sessionID = (response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "x-nanoclaw-session-id")
            ?? (response as? HTTPURLResponse)?
                .value(forHTTPHeaderField: "x-session-id")

        var accumulatedResponseText = ""
        var currentEventType = ""
        var currentDataLines: [String] = []

        func processSSEBlock() async throws -> Bool {
            let eventType = currentEventType
            let data = currentDataLines.joined(separator: "\n")
            currentEventType = ""
            currentDataLines.removeAll()

            guard !data.isEmpty else { return false }
            if data == "[DONE]" { return true }

            guard let object = decodeJSONObject(from: data) else {
                return false
            }

            if let errorMessage = streamErrorMessage(from: object) {
                throw NSError(
                    domain: "NanoClawAgentClient",
                    code: -2,
                    userInfo: [NSLocalizedDescriptionKey: errorMessage]
                )
            }

            let chunks = assistantContentChunks(from: object, eventType: eventType)
            for chunk in chunks where !chunk.isEmpty {
                accumulatedResponseText += chunk
                await onChunk(accumulatedResponseText)
            }

            if let progress = progressDisplayText(from: object, eventType: eventType) {
                await onToolProgress(progress)
            }
            return false
        }

        for try await line in bytes.lines {
            if line.isEmpty {
                if try await processSSEBlock() { break }
                continue
            }

            if line.hasPrefix("event: ") {
                currentEventType = String(line.dropFirst("event: ".count))
            } else if line.hasPrefix("event:") {
                currentEventType = String(line.dropFirst("event:".count)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("data: ") {
                currentDataLines.append(String(line.dropFirst("data: ".count)))
            } else if line.hasPrefix("data:") {
                currentDataLines.append(String(line.dropFirst("data:".count)).trimmingCharacters(in: .whitespaces))
            }
        }

        if !currentDataLines.isEmpty {
            _ = try await processSSEBlock()
        }

        return NanoClawAgentStreamResult(
            responseText: accumulatedResponseText,
            sessionID: sessionID ?? resumeSessionID
        )
    }

    private func streamPromptViaCLI(
        _ prompt: String,
        resumeSessionID: String?,
        onChunk: @escaping (String) async -> Void,
        onStatus: @escaping (String) async -> Void
    ) async throws -> NanoClawAgentStreamResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let result = try Self.runCLI(prompt: prompt, resumeSessionID: resumeSessionID)
                    Task {
                        await onStatus("NanoClaw CLI finished")
                        await onChunk(result.responseText)
                        continuation.resume(returning: result)
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func streamPromptViaLocalChat(
        _ prompt: String,
        resumeSessionID: String?,
        onChunk: @escaping (String) async -> Void,
        onStatus: @escaping (String) async -> Void
    ) async throws -> NanoClawAgentStreamResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let result = try Self.runLocalChat(
                        prompt: prompt,
                        resumeSessionID: resumeSessionID,
                        onOutput: { accumulatedText in
                            Task {
                                await onChunk(accumulatedText)
                            }
                        }
                    )
                    Task {
                        await onStatus("NanoClaw local chat finished")
                        await onChunk(result.responseText)
                        continuation.resume(returning: result)
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func systemPrompt(
        harnessBaseURL: String = "http://127.0.0.1:19474"
    ) -> String {
        """
    You are NanoClaw running behind TipTour.

    TipTour is the local macOS pointer, perception, and action layer. When a user asks for desktop help, use TipTour through its localhost HTTP harness instead of guessing coordinates yourself.

    TipTour endpoints:
    - GET \(harnessBaseURL)/v1/observe
    - GET \(harnessBaseURL)/v1/skills
    - GET \(harnessBaseURL)/v1/skills/active
    - GET \(harnessBaseURL)/v1/targets
    - GET \(harnessBaseURL)/v1/action-history
    - POST \(harnessBaseURL)/v1/plan-next-action
    - POST \(harnessBaseURL)/v1/workflow-plan

    Prefer one desktop action at a time. Loop deliberately: observe, perform exactly one action through TipTour, inspect the result/action history, then observe again before the next action. Do not send a multi-step plan and do not assume the starting app remains the target after an app switch.

    For simple visible clicks, call /v1/plan-next-action with JSON like:
    {"goal":"open the Add menu","app":"Blender","target_label":"Add","action":"click","execute":true}

    For keyboard or app actions, call /v1/workflow-plan with exactly one step:
    - Press a key: {"goal":"press return","app":"Target App","steps":[{"type":"pressKey","label":"Return"}]}
    - Type text/numbers: {"goal":"type value","app":"Target App","steps":[{"type":"type","value":"hello"}]}
    - Keyboard shortcut: {"goal":"select all","app":"Target App","steps":[{"type":"keyboardShortcut","label":"Cmd+A"}]}
    - Open or switch apps: {"goal":"open Chrome","app":"Google Chrome","steps":[{"type":"openApp","label":"Google Chrome"}]}

    Keep user-facing replies short. Explain what you are doing while tools run. Do not claim an action succeeded until TipTour returns success or a useful observation.
    """
    }

    func detectLocalConnection() async -> NanoClawConnectionStatus {
        let inspection = Self.inspectLocalInstallation()
        let candidateBaseURLs = uniqueNormalizedBaseURLs([
            TipTourDefaults.nanoClawAPIBaseURL,
            "http://127.0.0.1:10961",
            "http://127.0.0.1:8742",
            "http://127.0.0.1:8644"
        ])

        for candidateBaseURL in candidateBaseURLs {
            let status = await testAPIConnection(baseURL: candidateBaseURL)
            switch status.state {
            case .connected, .wrongServer:
                return NanoClawConnectionStatus(
                    state: status.state,
                    mode: status.mode,
                    baseURL: status.baseURL,
                    cliExecutablePath: TipTourDefaults.nanoClawCLIExecutablePath,
                    detail: status.detail,
                    detectedInstallPath: inspection.nanoClawHome
                )
            default:
                continue
            }
        }

        if let cliExecutablePath = inspection.cliExecutablePath {
            return NanoClawConnectionStatus(
                state: .connected,
                mode: .cli,
                baseURL: candidateBaseURLs.first ?? "http://127.0.0.1:10961",
                cliExecutablePath: cliExecutablePath,
                detail: "NanoClaw CLI is available. Ctrl+K long tasks will run through claw.",
                detectedInstallPath: inspection.nanoClawHome
            )
        }

        if let localChatDirectory = inspection.localChatDirectory {
            return NanoClawConnectionStatus(
                state: .connected,
                mode: .localChat,
                baseURL: candidateBaseURLs.first ?? "http://127.0.0.1:10961",
                cliExecutablePath: TipTourDefaults.nanoClawCLIExecutablePath,
                detail: "NanoClaw local chat is available at \(localChatDirectory).",
                detectedInstallPath: inspection.nanoClawHome
            )
        }

        if inspection.isInstalled {
            return NanoClawConnectionStatus(
                state: .notRunning,
                mode: .none,
                baseURL: candidateBaseURLs.first ?? "http://127.0.0.1:10961",
                cliExecutablePath: TipTourDefaults.nanoClawCLIExecutablePath,
                detail: "NanoClaw appears installed, but no local API or claw CLI was reachable.",
                detectedInstallPath: inspection.nanoClawHome
            )
        }

        return NanoClawConnectionStatus(
            state: .notFound,
            mode: .none,
            baseURL: "http://127.0.0.1:10961",
            cliExecutablePath: TipTourDefaults.nanoClawCLIExecutablePath,
            detail: "No NanoClaw API server or claw CLI was found.",
            detectedInstallPath: inspection.nanoClawHome
        )
    }

    func testConnection(baseURL: String) async -> NanoClawConnectionStatus {
        let apiStatus = await testAPIConnection(baseURL: baseURL)
        guard apiStatus.state != .notRunning else {
            let inspection = Self.inspectLocalInstallation()
            if let cliExecutablePath = inspection.cliExecutablePath {
                return NanoClawConnectionStatus(
                    state: .connected,
                    mode: .cli,
                    baseURL: apiStatus.baseURL,
                    cliExecutablePath: cliExecutablePath,
                    detail: "NanoClaw CLI is available. The optional HTTP API is not running.",
                    detectedInstallPath: inspection.nanoClawHome
                )
            }
            if let localChatDirectory = inspection.localChatDirectory {
                return NanoClawConnectionStatus(
                    state: .connected,
                    mode: .localChat,
                    baseURL: apiStatus.baseURL,
                    cliExecutablePath: TipTourDefaults.nanoClawCLIExecutablePath,
                    detail: "NanoClaw local chat is available at \(localChatDirectory). The optional HTTP API is not running.",
                    detectedInstallPath: inspection.nanoClawHome
                )
            }
            return apiStatus
        }
        return apiStatus
    }

    func testAPIConnection(baseURL: String) async -> NanoClawConnectionStatus {
        let normalizedBaseURL = Self.normalizedBaseURL(baseURL)
        if Self.loopbackHTTPPortIsClosed(baseURL: normalizedBaseURL) {
            return NanoClawConnectionStatus(
                state: .notRunning,
                mode: .none,
                baseURL: normalizedBaseURL,
                cliExecutablePath: TipTourDefaults.nanoClawCLIExecutablePath,
                detail: "No NanoClaw API server is listening on \(normalizedBaseURL).",
                detectedInstallPath: nil
            )
        }

        do {
            if let models = try? await jsonObject(baseURL: normalizedBaseURL, path: "/v1/models") {
                let looksLikeNanoClaw = Self.responseLooksLikeNanoClaw(models)
                return NanoClawConnectionStatus(
                    state: .connected,
                    mode: .api,
                    baseURL: normalizedBaseURL,
                    cliExecutablePath: TipTourDefaults.nanoClawCLIExecutablePath,
                    detail: looksLikeNanoClaw
                        ? "NanoClaw-compatible API is reachable at \(normalizedBaseURL)."
                        : "OpenAI-compatible API is reachable at \(normalizedBaseURL); TipTour will use it as the NanoClaw adapter.",
                    detectedInstallPath: nil
                )
            }

            let health = try await httpStatus(baseURL: normalizedBaseURL, path: "/health")
            guard (200..<300).contains(health) else {
                return NanoClawConnectionStatus(
                    state: .notRunning,
                    mode: .none,
                    baseURL: normalizedBaseURL,
                    cliExecutablePath: TipTourDefaults.nanoClawCLIExecutablePath,
                    detail: "No healthy NanoClaw API answered on \(normalizedBaseURL).",
                    detectedInstallPath: nil
                )
            }

            return NanoClawConnectionStatus(
                state: .connected,
                mode: .api,
                baseURL: normalizedBaseURL,
                cliExecutablePath: TipTourDefaults.nanoClawCLIExecutablePath,
                detail: "NanoClaw-compatible API is reachable at \(normalizedBaseURL).",
                detectedInstallPath: nil
            )
        } catch {
            return NanoClawConnectionStatus(
                state: .notRunning,
                mode: .none,
                baseURL: normalizedBaseURL,
                cliExecutablePath: TipTourDefaults.nanoClawCLIExecutablePath,
                detail: "No NanoClaw API server answered on \(normalizedBaseURL).",
                detectedInstallPath: nil
            )
        }
    }

    static func inspectLocalInstallation() -> NanoClawInstallInspection {
        let fileManager = FileManager.default
        let homeDirectory = fileManager.homeDirectoryForCurrentUser.path
        let environmentHome = ProcessInfo.processInfo.environment["NANOCLAW_DIR"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let candidates = [
            environmentHome,
            "\(homeDirectory)/nanoclaw",
            "\(homeDirectory)/NanoClaw",
            "\(homeDirectory)/.nanoclaw",
            "\(homeDirectory)/Documents/nanoclaw",
            "\(homeDirectory)/Documents/NanoClaw",
            "\(homeDirectory)/Documents/mywork/nanoclaw",
            "\(homeDirectory)/Documents/mywork/NanoClaw"
        ]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
        let expandedCandidates = uniquePaths(
            candidates + candidates.map { "\($0)/nanoclaw" }
        )

        let nanoClawHome = bestNanoClawHome(from: expandedCandidates)
        let cliExecutablePath = resolveCLIExecutablePath(TipTourDefaults.nanoClawCLIExecutablePath)
        let localChatDirectory = nanoClawHome.flatMap { looksLikeNanoClawLocalChat($0) ? $0 : nil }
            ?? expandedCandidates.first(where: looksLikeNanoClawLocalChat)
        let isInstalled = nanoClawHome != nil || cliExecutablePath != nil || localChatDirectory != nil
        let isConfigured = nanoClawHome.map { home in
            fileManager.fileExists(atPath: "\(home)/.env")
                || fileManager.fileExists(atPath: "\(home)/data")
                || fileManager.fileExists(atPath: "\(home)/store")
        } ?? false

        return NanoClawInstallInspection(
            nanoClawHome: nanoClawHome,
            cliExecutablePath: cliExecutablePath,
            localChatDirectory: localChatDirectory,
            isInstalled: isInstalled,
            isConfigured: isConfigured
        )
    }

    static func normalizedBaseURL(_ rawURL: String) -> String {
        var value = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty {
            value = "http://127.0.0.1:10961"
        }
        if !value.lowercased().hasPrefix("http://") && !value.lowercased().hasPrefix("https://") {
            value = "http://\(value)"
        }
        while value.hasSuffix("/") {
            value.removeLast()
        }
        if value.lowercased().hasSuffix("/v1") {
            value.removeLast(3)
        }
        return value
    }

    static func endpointURL(baseURL: String, path: String) -> URL {
        let normalizedBaseURL = normalizedBaseURL(baseURL)
        let normalizedPath = path.hasPrefix("/") ? path : "/\(path)"
        return URL(string: normalizedBaseURL + normalizedPath)
            ?? URL(string: "http://127.0.0.1:10961\(normalizedPath)")!
    }

    private static func runCLI(
        prompt: String,
        resumeSessionID: String?
    ) throws -> NanoClawAgentStreamResult {
        guard let cliExecutablePath = resolveCLIExecutablePath(TipTourDefaults.nanoClawCLIExecutablePath) else {
            throw NSError(
                domain: "NanoClawAgentClient",
                code: -10,
                userInfo: [NSLocalizedDescriptionKey: "NanoClaw CLI was not found. Install the NanoClaw claw command or run a compatible API server."]
            )
        }

        let fileManager = FileManager.default
        let temporaryDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("tiptour-nanoclaw-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: temporaryDirectory)
        }

        let stdoutURL = temporaryDirectory.appendingPathComponent("stdout.txt")
        let stderrURL = temporaryDirectory.appendingPathComponent("stderr.txt")
        fileManager.createFile(atPath: stdoutURL.path, contents: nil)
        fileManager.createFile(atPath: stderrURL.path, contents: nil)

        let stdoutHandle = try FileHandle(forWritingTo: stdoutURL)
        let stderrHandle = try FileHandle(forWritingTo: stderrURL)
        defer {
            try? stdoutHandle.close()
            try? stderrHandle.close()
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: cliExecutablePath)
        var arguments: [String] = []
        if let resumeSessionID,
           !resumeSessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            arguments.append(contentsOf: ["-s", resumeSessionID])
        }
        arguments.append(contentsOf: ["--timeout", "900", "\(Self.systemPrompt())\n\n\(prompt)"])
        process.arguments = arguments
        process.standardOutput = stdoutHandle
        process.standardError = stderrHandle

        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = defaultShellPath()
        if let nanoClawHome = inspectLocalInstallation().nanoClawHome {
            environment["NANOCLAW_DIR"] = nanoClawHome
        }
        process.environment = environment

        try process.run()

        let timeoutWorkItem = DispatchWorkItem {
            if process.isRunning {
                process.terminate()
            }
        }
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 900, execute: timeoutWorkItem)
        process.waitUntilExit()
        timeoutWorkItem.cancel()

        let stdoutText = (try? String(contentsOf: stdoutURL, encoding: .utf8)) ?? ""
        let stderrText = (try? String(contentsOf: stderrURL, encoding: .utf8)) ?? ""
        let responseText = stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
        let sessionID = sessionID(from: stderrText) ?? resumeSessionID

        guard process.terminationStatus == 0 else {
            let errorText = stderrText
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw NSError(
                domain: "NanoClawAgentClient",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: errorText.isEmpty ? "NanoClaw CLI exited with status \(process.terminationStatus)." : errorText]
            )
        }

        return NanoClawAgentStreamResult(responseText: responseText, sessionID: sessionID)
    }

    private static func runLocalChat(
        prompt: String,
        resumeSessionID: String?,
        onOutput: @escaping (String) -> Void
    ) throws -> NanoClawAgentStreamResult {
        let inspection = inspectLocalInstallation()
        guard let localChatDirectory = inspection.localChatDirectory else {
            throw NSError(
                domain: "NanoClawAgentClient",
                code: -11,
                userInfo: [NSLocalizedDescriptionKey: "NanoClaw local chat was not found. Run NanoClaw setup or install the claw CLI."]
            )
        }
        guard let pnpmPath = resolveCLIExecutablePath("pnpm") else {
            throw NSError(
                domain: "NanoClawAgentClient",
                code: -12,
                userInfo: [NSLocalizedDescriptionKey: "pnpm was not found. NanoClaw local chat needs pnpm on PATH."]
            )
        }

        let processPrompt = "\(Self.systemPrompt(harnessBaseURL: "http://host.docker.internal:19474"))\n\n\(prompt)"
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let outputLock = NSLock()
        var stdoutText = ""
        var stderrText = ""
        var lastPublishedText = ""

        let process = Process()
        process.executableURL = URL(fileURLWithPath: pnpmPath)
        process.currentDirectoryURL = URL(fileURLWithPath: localChatDirectory, isDirectory: true)
        process.arguments = ["run", "chat", processPrompt]
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = defaultShellPath()
        environment["NANOCLAW_DIR"] = localChatDirectory
        process.environment = environment

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }

            outputLock.lock()
            stdoutText += text
            let filteredText = filterLocalChatOutput(stdoutText)
            let shouldPublish = !filteredText.isEmpty && filteredText != lastPublishedText
            if shouldPublish {
                lastPublishedText = filteredText
            }
            outputLock.unlock()

            if shouldPublish {
                onOutput(filteredText)
            }
        }

        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            outputLock.lock()
            stderrText += text
            outputLock.unlock()
        }

        try process.run()

        let timeoutWorkItem = DispatchWorkItem {
            if process.isRunning {
                process.terminate()
            }
        }
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 150, execute: timeoutWorkItem)
        process.waitUntilExit()
        timeoutWorkItem.cancel()
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil

        outputLock.lock()
        let responseText = filterLocalChatOutput(stdoutText)
        let errorOutputText = stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
        outputLock.unlock()

        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "NanoClawAgentClient",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: errorOutputText.isEmpty ? "NanoClaw local chat exited with status \(process.terminationStatus)." : errorOutputText]
            )
        }

        return NanoClawAgentStreamResult(responseText: responseText, sessionID: resumeSessionID)
    }

    private static func filterLocalChatOutput(_ output: String) -> String {
        output
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { line in
                let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmedLine.isEmpty else { return false }
                guard !trimmedLine.hasPrefix(">") else { return false }
                guard !trimmedLine.hasPrefix("nanoclaw@") else { return false }
                return true
            }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func validateHTTPResponse(_ response: URLResponse) throws {
        guard let httpResponse = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw NSError(
                domain: "NanoClawAgentClient",
                code: httpResponse.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "NanoClaw API request failed with HTTP \(httpResponse.statusCode)."]
            )
        }
    }

    private func httpStatus(baseURL: String, path: String) async throws -> Int {
        var request = URLRequest(url: Self.endpointURL(baseURL: baseURL, path: path))
        request.httpMethod = "GET"
        request.timeoutInterval = 0.8
        let (_, response) = try await URLSession.shared.data(for: request)
        return (response as? HTTPURLResponse)?.statusCode ?? -1
    }

    private func jsonObject(baseURL: String, path: String) async throws -> [String: Any]? {
        var request = URLRequest(url: Self.endpointURL(baseURL: baseURL, path: path))
        request.httpMethod = "GET"
        request.timeoutInterval = 1.0
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let statusCode = (response as? HTTPURLResponse)?.statusCode,
              (200..<300).contains(statusCode) else {
            return nil
        }
        return decodeJSONObject(from: String(decoding: data, as: UTF8.self))
    }

    private func uniqueNormalizedBaseURLs(_ baseURLs: [String]) -> [String] {
        var seen = Set<String>()
        return baseURLs.compactMap { rawURL in
            let normalizedURL = Self.normalizedBaseURL(rawURL)
            guard !seen.contains(normalizedURL) else { return nil }
            seen.insert(normalizedURL)
            return normalizedURL
        }
    }

    private static func looksLikeNanoClawHome(_ path: String) -> Bool {
        let fileManager = FileManager.default
        return fileManager.fileExists(atPath: "\(path)/nanoclaw.sh")
            || fileManager.fileExists(atPath: "\(path)/package.json")
            || fileManager.fileExists(atPath: "\(path)/scripts/claw")
            || fileManager.fileExists(atPath: "\(path)/data")
            || fileManager.fileExists(atPath: "\(path)/store")
    }

    private static func looksLikeNanoClawLocalChat(_ path: String) -> Bool {
        let fileManager = FileManager.default
        return fileManager.fileExists(atPath: "\(path)/package.json")
            && fileManager.fileExists(atPath: "\(path)/scripts/chat.ts")
            && fileManager.fileExists(atPath: "\(path)/data/cli.sock")
    }

    private static func bestNanoClawHome(from paths: [String]) -> String? {
        paths
            .filter(looksLikeNanoClawHome)
            .max { scoreNanoClawHome($0) < scoreNanoClawHome($1) }
    }

    private static func scoreNanoClawHome(_ path: String) -> Int {
        let fileManager = FileManager.default
        var score = 0
        if fileManager.fileExists(atPath: "\(path)/.env") { score += 10 }
        if fileManager.fileExists(atPath: "\(path)/data/cli.sock") { score += 8 }
        if fileManager.fileExists(atPath: "\(path)/dist/index.js") { score += 6 }
        if fileManager.fileExists(atPath: "\(path)/node_modules") { score += 4 }
        if fileManager.fileExists(atPath: "\(path)/package.json") { score += 2 }
        return score
    }

    private static func uniquePaths(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        return paths.compactMap { rawPath in
            let standardizedPath = NSString(string: rawPath).standardizingPath
            guard !seen.contains(standardizedPath) else { return nil }
            seen.insert(standardizedPath)
            return standardizedPath
        }
    }

    private static func resolveCLIExecutablePath(_ rawPath: String) -> String? {
        let trimmedPath = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else { return nil }

        let fileManager = FileManager.default
        if trimmedPath.hasPrefix("/") {
            return fileManager.isExecutableFile(atPath: trimmedPath) ? trimmedPath : nil
        }

        let homeDirectory = fileManager.homeDirectoryForCurrentUser.path
        let candidatePaths = defaultShellPath()
            .split(separator: ":")
            .map(String.init)
            .map { path in
                path.replacingOccurrences(of: "~", with: homeDirectory) + "/\(trimmedPath)"
            }

        return candidatePaths.first(where: { fileManager.isExecutableFile(atPath: $0) })
    }

    private static func defaultShellPath() -> String {
        let homeDirectory = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            "\(homeDirectory)/bin",
            "\(homeDirectory)/.local/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin"
        ].joined(separator: ":")
    }

    private static func loopbackHTTPPortIsClosed(baseURL: String) -> Bool {
        guard let components = URLComponents(string: normalizedBaseURL(baseURL)),
              let host = components.host?.lowercased(),
              host == "127.0.0.1" || host == "localhost"
        else {
            return false
        }

        let port = components.port ?? (components.scheme == "https" ? 443 : 80)
        return !loopbackPortIsOpen(port)
    }

    private static func loopbackPortIsOpen(_ port: Int) -> Bool {
        guard (1...65535).contains(port) else { return false }

        let socketDescriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socketDescriptor >= 0 else { return false }
        defer {
            Darwin.close(socketDescriptor)
        }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.connect(
                    socketDescriptor,
                    sockaddrPointer,
                    socklen_t(MemoryLayout<sockaddr_in>.size)
                ) == 0
            }
        }
    }

    private static func responseLooksLikeNanoClaw(_ object: [String: Any]) -> Bool {
        let description = String(describing: object).lowercased()
        return description.contains("nanoclaw")
            || description.contains("nano-claw")
            || description.contains("claw")
    }

    private static func sessionID(from text: String) -> String? {
        let patterns = [
            #"(?im)session\s*(?:id)?\s*[:=]\s*([A-Za-z0-9._:-]+)"#,
            #"(?im)-s\s+([A-Za-z0-9._:-]+)"#
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            guard let match = regex.firstMatch(in: text, range: range),
                  match.numberOfRanges >= 2,
                  let valueRange = Range(match.range(at: 1), in: text) else {
                continue
            }
            let value = String(text[valueRange])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private func decodeJSONObject(from data: String) -> [String: Any]? {
        guard
            let jsonObject = try? JSONSerialization.jsonObject(with: Data(data.utf8)),
            let object = jsonObject as? [String: Any]
        else {
            return nil
        }
        return object
    }

    private func streamErrorMessage(from object: [String: Any]) -> String? {
        if let error = object["error"] as? [String: Any],
           let message = error["message"] as? String,
           !message.isEmpty {
            return message
        }
        if let error = object["error"] as? String, !error.isEmpty {
            return error
        }
        return nil
    }

    private func assistantContentChunks(from object: [String: Any], eventType: String) -> [String] {
        var chunks: [String] = []

        if let choices = object["choices"] as? [[String: Any]] {
            for choice in choices {
                if let delta = choice["delta"] as? [String: Any],
                   let content = delta["content"] as? String,
                   !content.isEmpty {
                    chunks.append(content)
                }
                if let message = choice["message"] as? [String: Any],
                   let content = message["content"] as? String,
                   !content.isEmpty {
                    chunks.append(content)
                }
                if let text = choice["text"] as? String, !text.isEmpty {
                    chunks.append(text)
                }
            }
        }

        if eventType == "response.output_text.delta",
           let delta = object["delta"] as? String,
           !delta.isEmpty {
            chunks.append(delta)
        }

        for key in ["content", "text", "response"] {
            if let value = object[key] as? String, !value.isEmpty {
                chunks.append(value)
            }
        }

        return chunks
    }

    private func progressDisplayText(from object: [String: Any], eventType: String) -> String? {
        let lowercasedEventType = eventType.lowercased()
        let looksLikeProgressEvent = lowercasedEventType.contains("progress")
            || lowercasedEventType.contains("tool")
            || lowercasedEventType.contains("status")
            || object["tool"] != nil
            || object["toolCallId"] != nil
            || object["status"] != nil
            || object["label"] != nil
        guard looksLikeProgressEvent else { return nil }

        let label = firstString(in: object, keys: ["label", "message", "preview", "text", "content"])
        let tool = firstString(in: object, keys: ["tool", "name", "function", "type"])
        let status = firstString(in: object, keys: ["status", "state"])
        let baseText = label ?? tool ?? status ?? eventType
        guard !baseText.isEmpty else { return nil }

        switch status?.lowercased() {
        case "completed", "complete", "done", "success", "succeeded":
            return "Finished \(label ?? tool ?? "tool")"
        case "failed", "error":
            return "Failed \(label ?? tool ?? "tool")"
        default:
            return baseText
        }
    }

    private func firstString(in object: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = object[key] as? String {
                let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmedValue.isEmpty {
                    return trimmedValue
                }
            }
        }
        return nil
    }
}
