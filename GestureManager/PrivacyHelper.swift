import Cocoa

class PrivacyHelper {
    static func isProcessTrustedWithPrompt() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        let isAccessibilityPermissionGranted = AXIsProcessTrustedWithOptions(options as CFDictionary)
        
        if isAccessibilityPermissionGranted {
            return true
        } else {
            promptForAccessibilityPermissionFromSandbox()
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
    _: CGEventTapProxy,
    _: CGEventType,
    cgEvent: CGEvent,
    _: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    debugPrint("Should never happen!")
    return Unmanaged.passUnretained(cgEvent)
}
