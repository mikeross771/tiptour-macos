import AppKit
import Combine
import CoreGraphics
import Foundation

final class GlobalTextCommandShortcutMonitor: ObservableObject {
    let shortcutPressedPublisher = PassthroughSubject<Void, Never>()

    private var globalEventTap: CFMachPort?
    private var globalEventTapRunLoopSource: CFRunLoopSource?
    private var isShortcutCurrentlyPressed = false

    deinit {
        stop()
    }

    func start() {
        guard globalEventTap == nil else { return }

        let monitoredEventTypes: [CGEventType] = [.keyDown, .keyUp, .flagsChanged]
        let eventMask = monitoredEventTypes.reduce(CGEventMask(0)) { currentMask, eventType in
            currentMask | (CGEventMask(1) << eventType.rawValue)
        }

        let eventTapCallback: CGEventTapCallBack = { _, eventType, event, userInfo in
            guard let userInfo else {
                return Unmanaged.passUnretained(event)
            }

            let shortcutMonitor = Unmanaged<GlobalTextCommandShortcutMonitor>
                .fromOpaque(userInfo)
                .takeUnretainedValue()

            return shortcutMonitor.handleGlobalEventTap(
                eventType: eventType,
                event: event
            )
        }

        guard let globalEventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: eventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            print("⚠️ Global text command: couldn't create CGEvent tap")
            return
        }

        guard let globalEventTapRunLoopSource = CFMachPortCreateRunLoopSource(
            kCFAllocatorDefault,
            globalEventTap,
            0
        ) else {
            CFMachPortInvalidate(globalEventTap)
            print("⚠️ Global text command: couldn't create event tap run loop source")
            return
        }

        self.globalEventTap = globalEventTap
        self.globalEventTapRunLoopSource = globalEventTapRunLoopSource

        CFRunLoopAddSource(CFRunLoopGetMain(), globalEventTapRunLoopSource, .commonModes)
        CGEvent.tapEnable(tap: globalEventTap, enable: true)
    }

    func stop() {
        isShortcutCurrentlyPressed = false

        if let globalEventTapRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), globalEventTapRunLoopSource, .commonModes)
            self.globalEventTapRunLoopSource = nil
        }

        if let globalEventTap {
            CFMachPortInvalidate(globalEventTap)
            self.globalEventTap = nil
        }
    }

    private func handleGlobalEventTap(
        eventType: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        if eventType == .tapDisabledByTimeout || eventType == .tapDisabledByUserInput {
            if let globalEventTap {
                CGEvent.tapEnable(tap: globalEventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let modifierFlags = NSEvent.ModifierFlags(rawValue: UInt(event.flags.rawValue))
        let isControlK = keyCode == 40
            && modifierFlags.contains(.control)
            && !modifierFlags.contains(.option)
            && !modifierFlags.contains(.command)
            && !modifierFlags.contains(.shift)

        switch eventType {
        case .keyDown where isControlK && !isShortcutCurrentlyPressed:
            isShortcutCurrentlyPressed = true
            shortcutPressedPublisher.send(())
        case .keyUp, .flagsChanged:
            if !isControlK {
                isShortcutCurrentlyPressed = false
            }
        default:
            break
        }

        return Unmanaged.passUnretained(event)
    }
}
