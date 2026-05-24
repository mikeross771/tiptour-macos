import AppKit
import SwiftUI

private final class TextCommandKeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class TextCommandPanelManager {
    private weak var companionManager: CompanionManager?
    private var panel: NSPanel?
    private var mouseTrackingTimer: Timer?
    private var currentPanelOrigin: CGPoint?
    private var lastMeasuredPanelSize = NSSize(width: 340, height: 64)

    private let panelMinimumWidth: CGFloat = 340
    private let panelMinimumHeight: CGFloat = 42
    private let screenEdgeInset: CGFloat = 12
    private let cursorClearance: CGFloat = 44
    private let horizontalOffsetFromCursor: CGFloat = 56
    private let verticalOffsetFromCursor: CGFloat = 32
    private let smoothingFactor: CGFloat = 0.34

    init(companionManager: CompanionManager) {
        self.companionManager = companionManager
    }

    func show() {
        guard let companionManager else { return }

        if panel == nil {
            createPanel(companionManager: companionManager)
        }

        positionPanel(animated: false)
        panel?.makeKeyAndOrderFront(nil)
        panel?.orderFrontRegardless()
        startMouseTracking()
    }

    func hide() {
        panel?.orderOut(nil)
        stopMouseTracking()
    }

    private func createPanel(companionManager: CompanionManager) {
        let textCommandView = TextCommandPanelView(companionManager: companionManager)
            .frame(width: 340)

        let hostingView = NSHostingView(rootView: textCommandView)
        hostingView.frame = NSRect(x: 0, y: 0, width: 340, height: 64)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = .clear
        hostingView.sizingOptions = [.intrinsicContentSize]

        let commandPanel = TextCommandKeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 64),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        commandPanel.isFloatingPanel = true
        commandPanel.level = .floating
        commandPanel.isOpaque = false
        commandPanel.backgroundColor = .clear
        commandPanel.hasShadow = false
        commandPanel.hidesOnDeactivate = false
        commandPanel.isExcludedFromWindowsMenu = true
        commandPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        commandPanel.isMovableByWindowBackground = false
        commandPanel.titleVisibility = .hidden
        commandPanel.titlebarAppearsTransparent = true
        commandPanel.contentView = hostingView

        panel = commandPanel
    }

    private func startMouseTracking() {
        stopMouseTracking()
        let trackingTimer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.positionPanel(animated: true)
            }
        }
        mouseTrackingTimer = trackingTimer
        RunLoop.main.add(trackingTimer, forMode: .common)
    }

    private func stopMouseTracking() {
        mouseTrackingTimer?.invalidate()
        mouseTrackingTimer = nil
        currentPanelOrigin = nil
    }

    private func positionPanel(animated: Bool) {
        guard let panel else { return }
        let mouseLocation = NSEvent.mouseLocation
        let targetScreen = NSScreen.screens.first { screen in
            screen.frame.contains(mouseLocation)
        } ?? NSScreen.main
        guard let screenFrame = targetScreen?.frame else { return }

        let panelSize = measuredPanelSize(for: panel)
        let targetOrigin = targetPanelOrigin(
            mouseLocation: mouseLocation,
            panelSize: panelSize,
            screenFrame: screenFrame
        )
        let nextOrigin = smoothedOrigin(
            currentOrigin: currentPanelOrigin,
            targetOrigin: targetOrigin,
            animated: animated
        )
        currentPanelOrigin = nextOrigin

        panel.setFrame(
            NSRect(x: nextOrigin.x, y: nextOrigin.y, width: panelSize.width, height: panelSize.height),
            display: true,
            animate: false
        )
    }

    private func measuredPanelSize(for panel: NSPanel) -> NSSize {
        let fittingSize = panel.contentView?.fittingSize ?? lastMeasuredPanelSize
        lastMeasuredPanelSize = NSSize(
            width: max(fittingSize.width, panelMinimumWidth),
            height: max(fittingSize.height, panelMinimumHeight)
        )
        return lastMeasuredPanelSize
    }

    private func targetPanelOrigin(
        mouseLocation: CGPoint,
        panelSize: NSSize,
        screenFrame: CGRect
    ) -> CGPoint {
        let candidateOrigins = [
            CGPoint(
                x: mouseLocation.x + horizontalOffsetFromCursor,
                y: mouseLocation.y - panelSize.height - verticalOffsetFromCursor
            ),
            CGPoint(
                x: mouseLocation.x + horizontalOffsetFromCursor,
                y: mouseLocation.y + verticalOffsetFromCursor
            ),
            CGPoint(
                x: mouseLocation.x - panelSize.width - horizontalOffsetFromCursor,
                y: mouseLocation.y - panelSize.height - verticalOffsetFromCursor
            ),
            CGPoint(
                x: mouseLocation.x - panelSize.width - horizontalOffsetFromCursor,
                y: mouseLocation.y + verticalOffsetFromCursor
            )
        ]

        let cursorSafetyRect = CGRect(
            x: mouseLocation.x - cursorClearance,
            y: mouseLocation.y - cursorClearance,
            width: cursorClearance * 2,
            height: cursorClearance * 2
        )

        let preferredOrigin = candidateOrigins.first { candidateOrigin in
            let panelRect = CGRect(origin: candidateOrigin, size: panelSize)
            return screenFrame.contains(panelRect) && !panelRect.intersects(cursorSafetyRect)
        } ?? candidateOrigins[0]

        return CGPoint(
            x: min(
                max(preferredOrigin.x, screenFrame.minX + screenEdgeInset),
                screenFrame.maxX - panelSize.width - screenEdgeInset
            ),
            y: min(
                max(preferredOrigin.y, screenFrame.minY + screenEdgeInset),
                screenFrame.maxY - panelSize.height - screenEdgeInset
            )
        )
    }

    private func smoothedOrigin(
        currentOrigin: CGPoint?,
        targetOrigin: CGPoint,
        animated: Bool
    ) -> CGPoint {
        guard animated, let currentOrigin else { return targetOrigin }

        let deltaX = targetOrigin.x - currentOrigin.x
        let deltaY = targetOrigin.y - currentOrigin.y
        if abs(deltaX) < 0.5, abs(deltaY) < 0.5 {
            return targetOrigin
        }

        return CGPoint(
            x: currentOrigin.x + deltaX * smoothingFactor,
            y: currentOrigin.y + deltaY * smoothingFactor
        )
    }
}
