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

    private let panelSize = NSSize(width: 340, height: 64)
    private let screenEdgeInset: CGFloat = 12
    private let cursorClearance: CGFloat = 44
    private let horizontalOffsetFromCursor: CGFloat = 56
    private let verticalOffsetFromCursor: CGFloat = 32
    private let trackingInterval: TimeInterval = 1.0 / 60.0
    private let smoothingFactor: CGFloat = 0.24
    private let fadeDuration: TimeInterval = 0.12

    init(companionManager: CompanionManager) {
        self.companionManager = companionManager
    }

    func show() {
        guard let companionManager else { return }

        if panel == nil {
            createPanel(companionManager: companionManager)
        }

        let mouseLocation = NSEvent.mouseLocation
        currentPanelOrigin = nil

        panel?.alphaValue = 0
        positionPanel(at: mouseLocation, animated: false)
        panel?.makeKeyAndOrderFront(nil)
        panel?.orderFrontRegardless()
        fadePanel(to: 1)
        startMouseTracking()
    }

    func hide() {
        panel?.orderOut(nil)
        stopMouseTracking()
    }

    private func createPanel(companionManager: CompanionManager) {
        let textCommandView = TextCommandPanelView(companionManager: companionManager)
            .frame(width: panelSize.width, height: panelSize.height)

        let hostingView = NSHostingView(rootView: textCommandView)
        hostingView.frame = NSRect(origin: .zero, size: panelSize)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = .clear
        hostingView.sizingOptions = []

        let commandPanel = TextCommandKeyablePanel(
            contentRect: NSRect(origin: .zero, size: panelSize),
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
        let trackingTimer = Timer(timeInterval: trackingInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleMouseTrackingTick()
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

    private func handleMouseTrackingTick() {
        guard let panel, panel.isVisible else { return }
        positionPanel(at: NSEvent.mouseLocation, animated: true)
    }

    private func positionPanel(at mouseLocation: CGPoint, animated: Bool) {
        guard let panel else { return }
        let targetScreen = NSScreen.screens.first { screen in
            screen.frame.contains(mouseLocation)
        } ?? NSScreen.main
        guard let screenFrame = targetScreen?.frame else { return }

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

        let currentFrame = panel.frame
        let positionChanged = abs(currentFrame.minX - nextOrigin.x) > 0.35
            || abs(currentFrame.minY - nextOrigin.y) > 0.35
        guard positionChanged || currentFrame.size != panelSize else { return }

        panel.setFrame(
            NSRect(x: nextOrigin.x, y: nextOrigin.y, width: panelSize.width, height: panelSize.height),
            display: true,
            animate: false
        )
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

    private func fadePanel(to alphaValue: CGFloat) {
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = fadeDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().alphaValue = alphaValue
        }
    }
}
