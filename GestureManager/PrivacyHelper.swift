import Cocoa

class PrivacyHelper {
    static func isProcessTrustedWithPrompt() -> Bool {
        let isAccessibilityPermissionGranted = AXIsProcessTrustedWithOptions(
            [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
                as CFDictionary
        )
        if isAccessibilityPermissionGranted {
            return true
        } else {
            PrivacyHelper.promptForAccessibilityPermissionFromSandbox()
            return false
        }
    }

    private static func promptForAccessibilityPermissionFromSandbox() {
        _ = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: NSEvent.EventTypeMask.gesture.rawValue,
            callback: dummyEventHandler,
            userInfo: nil
        )
    }
}

private func dummyEventHandler(
    proxy: CGEventTapProxy,
    eventType: CGEventType,
    cgEvent: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    debugPrint("Should never happen!")
    return Unmanaged.passUnretained(cgEvent)
}
