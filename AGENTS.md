# TipTour - Agent Instructions

<!-- This is the single source of truth for all AI coding agents. CLAUDE.md is a symlink to this file. -->
<!-- AGENTS.md spec: https://github.com/agentsmd/agents.md — supported by Claude Code, Cursor, Copilot, Gemini CLI, and others. -->

## Overview

macOS menu bar voice companion. Lives entirely in the macOS status bar (no dock icon, no main window). Clicking the menu bar icon opens a custom floating panel. Push-to-talk (Ctrl+Option) opens a Gemini Live realtime session — Gemini hears the user, optionally sees the user's screen via streaming JPEG screenshots, replies in voice, and calls one CUA action-plan tool to control the computer in Autopilot.

Source builds require the user to paste their own Gemini API key into the visible panel field; the key is stored in macOS Keychain. Distributed builds can optionally configure a Cloudflare Worker proxy via `TipTourWorkerBaseURL`, but the maintainer's Worker URL must never be hardcoded into the open-source app.

## Architecture

- **App Type**: Menu bar-only (`LSUIElement=true`), no dock icon or main window.
- **Framework**: SwiftUI (macOS native) with AppKit bridging for menu bar panel and cursor overlay.
- **Pattern**: MVVM with `@StateObject` / `@Published` state management.
- **Source Layout**: TipTour source is grouped by responsibility: `App/` for lifecycle and `CompanionManager`, `Core/` for the stable `TipTourEngine` facade, `Actions/` for action-driver boundaries, `Workflow/` for single-action plans and grounding, `Perception/` for screen/AX/DOM/OCR/local detection, `Harnesses/` for local external transports, `Plugins/` for connection metadata, `UI/` for panel/overlay views, `Voice/` for Gemini Live, `Recording/` for walkthrough capture, and `Utilities/` for cross-cutting helpers. Keep agent/source-map docs outside `TipTour/` because Xcode's synchronized app target treats Markdown files under `TipTour/` as bundled resources; use `docs/source-layout.md` for the folder map.
- **Voice Mode**: Gemini Live only. Single-model realtime WebSocket — bidirectional voice (PCM16 16kHz in, PCM16 24kHz out), optional vision (JPEG screenshots), text transcription, AND tool calling all in one streaming connection. A visible "Screenshots" privacy toggle in `CompanionPanelView` persists `isScreenshotStreamingEnabled`; when off, `GeminiLiveSession` does not capture/send screen JPEGs and tells Gemini to rely on voice, local labels, and tool results instead. One tool is exposed: `submit_workflow_plan(goal, app, steps)` for CUA actions, but the tool is now single-action only: Gemini may emit exactly one step per turn and the Swift handler clamps extra steps defensively. The legacy `point_at_element` path is disabled and no longer declared to Gemini. Workflow steps can include `targetContext` (`visibleElement`, `currentHighlight`, `currentSelection`, `focusedElement`) so Gemini can bind actions to the highlighted/selected/focused target generically instead of smuggling target intent through a click label. Gemini produces action steps itself inside its tool call — no separate planner model. API key comes from the user's local Keychain key in source builds, with optional Worker fallback only when `TipTourWorkerBaseURL` is configured. `CompanionManager` constructs the session directly — no protocol indirection (the previous OpenAI Realtime backend + `VoiceBackend` protocol were removed in the simplification refactor).
- **TipTour Engine Facade**: `TipTourEngine` is the small core-facing facade for callers that should not know about `CompanionManager`. It currently exposes observe + single-action workflow submission and routes into the existing `WorkflowRunner`; future `ground`, `act`, `record`, and `replay` APIs should grow here first instead of expanding transport/UI classes. It also enforces user connection toggles before accepting external action requests.
- **Local Harness Server**: TipTour also exposes a localhost-only HTTP harness (`TipTourHarnessServer`) on `127.0.0.1:19474` for external orchestrators such as Hermes. This keeps Hermes/OpenClaw/Composio outside the macOS app while letting them call TipTour as the local perception/action engine. The harness exposes health/capabilities/observe plus `POST /v1/workflow-plan`, accepts the same single-action workflow shape as Gemini, clamps external requests to one step, and routes through `TipTourEngine` + `WorkflowRunner` so Autopilot permissions, grounding, overlay flight, app-switch pauses, and CUA execution remain the single enforcement path.
- **Screen Capture**: ScreenCaptureKit (macOS 14.2+), multi-monitor support. The cursor screen is captured at native display pixel resolution for Gemini coordinate accuracy; secondary screens are downscaled to keep latency reasonable.
- **Voice Input**: `GeminiLiveSession` captures mic audio and streams it directly over the WebSocket. Hotkey is a listen-only CGEvent tap so modifier-only shortcuts (Ctrl+Option) work reliably in the background.
- **Focus Highlight Context**: Holding Ctrl+Shift activates a listen-only freeform highlight brush. `GlobalHighlightShortcutMonitor` records the mouse path, `OverlayWindow` renders the translucent stroke, and `CompanionManager` sends Gemini a `FocusHighlightContext` with the global rect, last painted hover point, topmost CUA window intersecting the painted region, AX element under the highlight, active selected text when it belongs to the highlighted element/window, and normalized screenshot `box_2d` when available. If the highlight intersects a text element but the user did not make a native macOS selection, TipTour asks AX for `AXRangeForPosition` at sampled painted points and expands the result to the highlighted word/range. The preferred tool-call shape is now generic: Gemini marks edit steps with `targetContext: "currentHighlight"` or `targetContext: "currentSelection"`, and `CompanionManager` binds that context to the available resolver (AX text range today, other target resolvers later). The intersected app is also pinned as the target app for follow-up workflows so commands like "rewrite this" or "change this area" stay inside the app/window the user highlighted instead of typing into whatever is frontmost later.
- **Action Grounding**: Gemini calls `submit_workflow_plan`; click-like steps are grounded by `ElementResolver`, which resolves the step `label` to pixel positions via a local-first lookup. Gemini may provide `point_2d` (`[y, x]`, normalized to 0-1000) and/or `box_2d` (`[y1, x1, y2, x2]`). TipTour prefers deterministic local geometry when available and only falls back to Gemini coordinates after local resolvers miss.
    1. **macOS Accessibility tree** — pixel-perfect, ~30ms. Works on Apple-native Mac apps, most Cocoa third-party apps, and Electron apps that respect `AXManualAccessibility` (set on every app focus — see below). Uses batched `AXUIElementCopyMultipleAttributeValues` reads for ~3-10× speedup over per-attribute reads on large trees (Xcode, Electron).
    2. **Browser DOM/CDP coordinates** — Chromium page geometry through CUA Driver Core's CDP client when a remote-debugging page target is available. This gives browser-web controls a deterministic DOM-rect fallback before vision coordinates.
    3. **Local perception cache (experimental branch only)** — the native overlay publishes the latest CoreML UI detections plus Apple Vision OCR into `LocalPerceptionTargetCache`, letting labels such as "Add" resolve without screenshot streaming or Gemini `box_2d`.
    4. **Native detector refinement (experimental branch only)** — local CoreML UI detections plus Apple Vision OCR refine Gemini's rough `box_2d` point for canvas/no-AX apps such as Blender. The detector uses the warm overlay cache when available and can run one fresh pass from the latest screenshot when the cache is cold.
    5. **Raw LLM coordinates from `box_2d`** — Gemini's own spatial grounding. Used only after AX, browser DOM, and native detector refinement miss.
    Blender is an exception on the experimental branch: it skips AX/CDP but still allows the native detector/OCR cache to refine a visible label before falling back to Gemini `box_2d`. WorkflowRunner also skips AX polling and AX-fingerprint post-click validation for Blender/no-AX apps because their AX tree does not reflect canvas UI changes.
- **Accurate Grounding + Native Detection Overlay**: The visible panel has an "Accurate Grounding" toggle that silently runs the restored native CoreML detector plus Apple Vision OCR and feeds `LocalPerceptionTargetCache`, so action grounding can resolve visible labels from local detections even when screenshot streaming to Gemini is off. The green/blue detection boxes are controlled separately by the Dev-only "Show Detection Overlay" toggle. Detection refreshes on enable, app activation, CUA click events, screen changes, and voice-session start instead of polling YOLO continuously.
- **Accessibility Tree**: `AccessibilityTreeResolver.swift` walks the user's target app's AX tree via `ApplicationServices`, matches elements by title/description/value, returns exact pixel frames in global AppKit coordinates. Uses the app/window under the mouse at hotkey press time, with frontmost app as fallback, so the query targets the app the user was actually pointing at, not TipTour's own menu bar. Highlight hit-testing uses CUA Driver Core's `WindowEnumerator.visibleWindows()` and `AXInput.elementAt(...)` to identify the topmost intersected app/window and element. **Pre-warmed on hotkey press** via `CompanionManager.prefetchAccessibilityTreeForTargetApp` — the AX walk overlaps the user's first words and Gemini's session setup, so the first CUA click/action step resolves against warm data.
- **AX hardening for Electron**: On every app activation (`NSWorkspace.didActivateApplicationNotification`), `CompanionManager.enableManualAccessibilityIfNeeded` sets `AXManualAccessibility=true` on the activated app's AX element. Electron apps (Framer, VS Code, Slack, Discord, Cursor, Notion, Figma desktop) honor this attribute and populate their full webpage AX tree; non-Electron apps return `kAXErrorAttributeUnsupported` which we silently ignore. Without this, Electron apps return ~0 candidates from AX walks. A `0.4s` `AXUIElementSetMessagingTimeout` is also applied at app launch on the system-wide element + per-app on activation, capping any single AX query from hanging the resolver longer than 400ms.
- **Single-action workflows**: `WorkflowRunner` consumes the single step emitted by Gemini's `submit_workflow_plan` tool. In Autopilot mode it drives that one action through CUA, then stops; Gemini must wait for the next user utterance/screen state before asking for the next action. The older teaching/tour-guide surface — visible checklist, step-by-step user-click guidance, and plan narration mode — is behind `isMultiStepTourGuideEnabled` and defaults OFF, but multi-step chains are still clamped to one step in this build. Each action is stamped with a fresh `operationToken` (UUID) so callbacks from a stale run can't mutate the current one after a rapid restart. The runner pauses automatically when the user Cmd-Tabs to an unrelated app, when an `AXSheet`/`AXDialog` modal appears mid-workflow, or when the post-click AX-tree fingerprint stays unchanged through a 350ms settle window for steps that depend on visible UI state changing.
- **Two operating modes — Autopilot (default) vs Teaching**: A toggle in the menu bar panel (`autopilotToggleRow` in `CompanionPanelView`) flips TipTour between "do it for me" (autopilot, default — TipTour clicks/types/presses keys for the user) and "show me how" (teaching — TipTour points, the user clicks). Teaching/tour-guide behavior is additionally gated by `isMultiStepTourGuideEnabled` and is off by default, but chained multi-step plans are disabled even when the flag is present. When Autopilot is ON, `WorkflowRunner` schedules an `ActionExecutor` click ~650ms after each cursor flight, and non-click step types (`.keyboardShortcut`, `.type`) are actionable for the single accepted step. State persisted to `UserDefaults` under `isAutopilotEnabled`. The pause-on-app-switch + modal + post-click-validator safety net applies to autopilot the same way it does to user-driven flows — autopilot rides the rails, doesn't bypass them.
- **Connection Toggles**: The menu bar panel has a small "Connections" section for user-controlled plugin-like integrations. `CUA Driver` defaults ON and gates all desktop action execution through `ActionExecutor`; when OFF, TipTour can still observe/ground but action plans are rejected before execution. `Hermes` defaults OFF and is reserved for the upcoming orchestrator plugin; when ON, TipTour may later auto-delegate long-running tasks to Hermes while Hermes can call TipTour back through the local harness.
- **Action execution** (Autopilot only): `ActionExecutor.swift` is the stable TipTour action facade; concrete delivery lives behind the `TipTourActionDriver` protocol. The default `CuaActionDriver` uses CUA Driver Core (`CuaDriverCore`) for low-level macOS input delivery. It supports app/URL launch, left/right/double clicks, keyboard shortcuts, single-key presses, typing, focused AX value setting, and keyboard-backed scrolling. Typing first tries direct AX selected-text insertion, then uses a clipboard-staged Cmd+V fallback for rich web editors like Google Docs. For focus-highlight text edits, it first applies the armed `AXSelectedTextRange` and refuses blind key-event fallback if that range cannot be restored, preventing highlighted-word edits from pasting into the wrong insertion point. TipTour still owns target selection, cursor visuals, Gemini/Hermes harness handling, and workflow safety checks.
- **Walkthrough recording**: `ScreenRecorder.swift` saves the user's walkthrough as an `.mov` to `~/Library/Application Support/TipTour/recordings/`. ScreenCaptureKit + AVAssetWriter, H.264 primary with HEVC fallback, 16-aligned dimensions for codec compatibility, serial sample-buffer queue to preserve FIFO ordering through the writer.
- **Concurrency**: `@MainActor` isolation, async/await throughout.
- **Analytics**: PostHog via `TipTourAnalytics.swift`.

### API Proxy (Cloudflare Worker)

Source builds call Gemini directly with the user's Keychain-stored API key. A Cloudflare Worker (`worker/src/index.ts`) is optional for distribution builds that set `TipTourWorkerBaseURL` in the app bundle.

| Route | Upstream | Purpose |
|-------|----------|---------|
| `GET /gemini-live-key` | — (returns secret) | Optional distribution-build route that returns a Gemini API key so the app can open a direct WebSocket to Gemini Live. |
| `POST /match-label` | `gemini-2.5-flash-lite` | Multilingual label matcher used by `ElementResolver`'s fallback when the LLM passes a label in one language and the AX tree has it in another. |

Worker secret: `GEMINI_API_KEY`.

### Key Architecture Decisions

**Menu Bar Panel Pattern**: The companion panel uses `NSStatusItem` for the menu bar icon and a custom borderless `NSPanel` for the floating control panel. This gives full control over appearance (dark, rounded corners, custom shadow) and avoids the standard macOS menu/popover chrome. The panel is non-activating so it doesn't steal focus. A global event monitor auto-dismisses it on outside clicks.

**Cursor Overlay**: A full-screen transparent `NSPanel` hosts the blue cursor companion. It's non-activating, joins all Spaces, and never steals focus. The cursor position, response text, waveform, and pointing animations all render in this overlay via SwiftUI through `NSHostingView`.

**Global Push-To-Talk Shortcut**: Background push-to-talk uses a listen-only `CGEvent` tap instead of an AppKit global monitor so modifier-based shortcuts like `Ctrl+Option` are detected more reliably while the app is running in the background.

**Toggle (not hold) push-to-talk**: Press Ctrl+Option once to open the Gemini Live session, press again to close it. The connection stays open between turns so the user can have a real conversation.

## Key Files

| File | Lines | Purpose |
|------|-------|---------|
| `TipTour/App/TipTourApp.swift` | ~111 | Menu bar app entry point. Uses `@NSApplicationDelegateAdaptor` with `CompanionAppDelegate` which creates `MenuBarPanelManager` and starts `CompanionManager`. No main window — the app lives entirely in the status bar. |
| `TipTour/App/CompanionManager.swift` | ~2316 | Central state machine. Owns the global hotkey, hover/window targeting, CUA-backed focus highlight hit-testing, selected-text context/range inference, screen capture, Gemini Live session, screenshot streaming privacy setting, tool handlers, permissions, AX hardening, AX-tree prefetch, feature flags, grounding refresh, connection toggles, local perception cache publishing, harness server, engine facade, and overlay management. |
| `TipTour/Core/TipTourEngine.swift` | ~150 | Thin engine facade for non-UI callers. Centralizes observe + single-action workflow submission so harnesses/plugins do not reach into `CompanionManager`; intended home for future `ground`, `act`, `record`, and `replay` API surfaces. |
| `TipTour/Harnesses/TipTourHarnessServer.swift` | ~289 | Localhost-only HTTP harness for Hermes and other external orchestrators. Exposes `/v1/health`, `/v1/capabilities`, `/v1/observe`, and `/v1/workflow-plan`, then hands accepted single-action plans to `TipTourEngine` instead of embedding any external agent runtime in the app. |
| `TipTour/Plugins/TipTourConnection.swift` | ~25 | Lightweight built-in connection model for plugin-like integrations such as CUA, Hermes, perception, and harnesses. |
| `TipTour/UI/MenuBarPanelManager.swift` | ~315 | NSStatusItem + custom NSPanel lifecycle. Creates the menu bar icon, manages the floating companion panel (show/hide/position), installs click-outside-to-dismiss monitor. |
| `TipTour/UI/CompanionPanelView.swift` | ~1264 | SwiftUI panel content. Status header, visible Gemini API key setup, permissions setup, workflow checklist, autopilot toggle, connection toggles, screenshot streaming privacy toggle, Accurate Grounding toggle, neko mode toggle, developer section with detection overlay toggle, footer. |
| `TipTour/UI/OverlayWindow.swift` | ~1435 | Full-screen transparent overlay hosting the blue cursor, focus highlight brush, optional Dev-only native detection boxes, response text, waveform, and spinner. Cursor animation, element pointing with bezier arcs, multi-monitor coordinate mapping. |
| `TipTour/UI/DetectionOverlayView.swift` | ~460 | SwiftUI Canvas overlay that renders local CoreML UI boxes, Apple Vision OCR text boxes, and a visual-only bubble cursor/flashlight lock-on for debugging target-aware cursor behavior. |
| `TipTour/UI/CompanionResponseOverlay.swift` | ~217 | SwiftUI view for the response text bubble and waveform displayed next to the cursor in the overlay. |
| `TipTour/UI/NekoCursorView.swift` | ~288 | Pixel-art cat cursor. Whimsical visual replacement for the blue triangle — toggleable, defaults off. |
| `TipTour/UI/DesignSystem.swift` | ~880 | Design system tokens — colors, corner radii, shared styles. All UI references `DS.Colors`, `DS.CornerRadius`, etc. |
| `TipTour/Workflow/WorkflowPlan.swift` | ~290 | Schema for Gemini/harness-emitted action plans, including generic `targetContext` grounding for visible elements, current highlight, current selection, and focused element. |
| `TipTour/Workflow/WorkflowRunner.swift` | ~1284 | Executes Gemini/harness-produced single-action plans. Resolves the accepted step, arms the click detector in Teaching mode, or executes click/type/key/open/scroll actions through the action facade in Autopilot mode. |
| `TipTour/Workflow/ElementResolver.swift` | ~518 | Unified single-entry resolver. Given a label and optional spatial hints, tries AX tree → browser DOM/CDP coordinates → local perception cache → native detector refinement → Gemini's raw coordinates. |
| `TipTour/Actions/TipTourActionDriver.swift` | ~69 | Action-driver protocol boundary. TipTour core asks for semantic desktop actions through this shape so CUA, AX, browser DOM, AppleScript, and test/no-op drivers can be swapped without changing workflow logic. |
| `TipTour/Actions/ActionExecutor.swift` | ~733 | Autopilot action facade plus default `CuaActionDriver`. Converts TipTour's resolved screen points and workflow actions into pid-targeted CUA app launch, URL open, clicks, hotkeys, key presses, AX/clipboard typing, value setting, highlighted text replacement, and scrolling. |
| `TipTour/Perception/AccessibilityTreeResolver.swift` | ~960 | Walks the frontmost app's macOS Accessibility tree, looks up elements by title/description/value, returns pixel-perfect frames. First-tier element-lookup path. |
| `TipTour/Perception/BrowserCoordinateResolver.swift` | ~215 | Chromium browser-page fallback. Uses CUA Driver Core's CDP client to match visible DOM elements by label and map viewport rects into global AppKit coordinates. |
| `TipTour/Perception/CompanionScreenCaptureUtility.swift` | ~187 | Multi-monitor screenshot capture using ScreenCaptureKit. Returns labeled image data for each connected display. |
| `TipTour/Perception/LocalPerceptionTargetCache.swift` | ~380 | Shared local target cache. Stores YOLO/OCR detections, enriches unlabeled UI boxes with OCR labels, matches spoken labels, and converts screenshot-pixel boxes into global AppKit coordinates. |
| `TipTour/Perception/NativeElementDetector.swift` | ~614 | Local CoreML YOLO + Apple Vision OCR detector. Used by the Dev overlay and optional resolver refinement before raw Gemini coordinates. |
| `TipTour/Perception/ScreenshotPerceptualHash.swift` | ~96 | dHash implementation. Deduplicates similar screenshots before sending to Gemini. |
| `TipTour/Voice/GeminiLiveClient.swift` | ~643 | WebSocket client for Google's Gemini Live API. Sends PCM16 audio, JPEG screenshots, and text; receives PCM16 audio chunks, transcripts, and tool calls. |
| `TipTour/Voice/GeminiLiveAudioPlayer.swift` | ~227 | Streaming PCM16 24kHz audio playback via AVAudioEngine + AVAudioPlayerNode. |
| `TipTour/Voice/GeminiLiveSession.swift` | ~953 | Orchestrator tying the WebSocket client + audio player + mic capture together. Owns the Gemini Live conversation lifecycle and optional screenshot streaming. |
| `TipTour/Voice/PCM16AudioConverter.swift` | ~90 | PCM16 audio conversion helpers for Gemini Live input/output. |
| `TipTour/Recording/ScreenRecorder.swift` | ~476 | Records the main display to `.mov` via ScreenCaptureKit + AVAssetWriter. Output to `~/Library/Application Support/TipTour/recordings/`. Currently unwired — call sites can opt in. |
| `TipTour/Utilities/ClickDetector.swift` | ~228 | Global listen-only CGEventTap that fires a callback when a left-mouse-down lands within a tolerance radius of an armed target. |
| `TipTour/Utilities/FocusHighlightContext.swift` | ~77 | Spatial model for the user's freeform highlight, intersected app/window identity, intersected AX element, and selected text context. |
| `TipTour/Utilities/GlobalPushToTalkShortcutMonitor.swift` | ~132 | System-wide push-to-talk monitor. Owns the listen-only `CGEvent` tap and publishes press/release transitions. |
| `TipTour/Utilities/GlobalHighlightShortcutMonitor.swift` | ~140 | System-wide Ctrl+Shift focus highlight monitor. Owns the listen-only `CGEvent` tap and publishes begin/move/end transitions. |
| `TipTour/Utilities/PushToTalkShortcut.swift` | ~40 | Encodes the single shortcut TipTour listens for (Ctrl+Option) and translates raw CGEvents into press/release transitions. |
| `TipTour/Utilities/WindowPositionManager.swift` | ~262 | Window placement logic, Screen Recording permission flow, and accessibility permission helpers. |
| `TipTour/Utilities/KeychainStore.swift` | ~108 | macOS Keychain wrapper for storing the user-pasted Gemini API key. |
| `TipTour/Utilities/RetryWithExponentialBackoff.swift` | ~67 | Utility helper for retry logic. |
| `TipTour/Utilities/TipTourAnalytics.swift` | ~106 | PostHog analytics integration for usage tracking. |
| `TipTour/Utilities/AppBundleConfiguration.swift` | ~28 | Runtime configuration reader for keys stored in the app bundle Info.plist. |
| `worker/src/index.ts` | ~140 | Cloudflare Worker proxy. Two routes: `/gemini-live-key` (Gemini Live API key) and `/match-label` (multilingual label matcher). |

## Build & Run

```bash
# Open in Xcode
open tiptour-macos.xcodeproj

# Select the TipTour scheme, set signing team, Cmd+R to build and run

# Known non-blocking warnings: Swift 6 concurrency warnings,
# deprecated onChange warning in OverlayWindow.swift. Do NOT attempt to fix these.
```

**Do NOT run `xcodebuild` from the terminal** — it invalidates TCC (Transparency, Consent, and Control) permissions and the app will need to re-request screen recording, accessibility, etc.

## Cloudflare Worker

```bash
cd worker
npm install

# Add secret
npx wrangler secret put GEMINI_API_KEY

# Deploy
npx wrangler deploy

# Local dev (create worker/.dev.vars with GEMINI_API_KEY=...)
npx wrangler dev
```

## Code Style & Conventions

### Variable and Method Naming

IMPORTANT: Follow these naming rules strictly. Clarity is the top priority.

- Be as clear and specific with variable and method names as possible
- **Optimize for clarity over concision.** A developer with zero context on the codebase should immediately understand what a variable or method does just from reading its name
- Use longer names when it improves clarity. Do NOT use single-character variable names
- Example: use `originalQuestionLastAnsweredDate` instead of `originalAnswered`
- When passing props or arguments to functions, keep the same names as the original variable. Do not shorten or abbreviate parameter names. If you have `currentCardData`, pass it as `currentCardData`, not `card` or `cardData`

### Code Clarity

- **Clear is better than clever.** Do not write functionality in fewer lines if it makes the code harder to understand
- Write more lines of code if additional lines improve readability and comprehension
- Make things so clear that someone with zero context would completely understand the variable names, method names, what things do, and why they exist
- When a variable or method name alone cannot fully explain something, add a comment explaining what is happening and why

### Swift/SwiftUI Conventions

- Use SwiftUI for all UI unless a feature is only supported in AppKit (e.g., `NSPanel` for floating windows)
- All UI state updates must be on `@MainActor`
- Use async/await for all asynchronous operations
- Comments should explain "why" not just "what", especially for non-obvious AppKit bridging
- AppKit `NSPanel`/`NSWindow` bridged into SwiftUI via `NSHostingView`
- All buttons must show a pointer cursor on hover
- For any interactive element, explicitly think through its hover behavior (cursor, visual feedback, and whether hover should communicate clickability)

### Do NOT

- Do not add features, refactor code, or make "improvements" beyond what was asked
- Do not add docstrings, comments, or type annotations to code you did not change
- Do not try to fix the known non-blocking warnings (Swift 6 concurrency, deprecated onChange)
- Do not run `xcodebuild` from the terminal — it invalidates TCC permissions

## Git Workflow

- Branch naming: `feature/description` or `fix/description`
- Commit messages: imperative mood, concise, explain the "why" not the "what"
- Do not force-push to main

## Self-Update Instructions

<!-- AI agents: follow these instructions to keep this file accurate. -->

When you make changes to this project that affect the information in this file, update this file to reflect those changes. Specifically:

1. **New files**: Add new source files to the "Key Files" table with their purpose and approximate line count
2. **Deleted files**: Remove entries for files that no longer exist
3. **Architecture changes**: Update the architecture section if you introduce new patterns, frameworks, or significant structural changes
4. **Build changes**: Update build commands if the build process changes
5. **New conventions**: If the user establishes a new coding convention during a session, add it to the appropriate conventions section
6. **Line count drift**: If a file's line count changes significantly (>50 lines), update the approximate count in the Key Files table

Do NOT update this file for minor edits, bug fixes, or changes that don't affect the documented architecture or conventions.
