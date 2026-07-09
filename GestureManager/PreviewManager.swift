import Cocoa
import Foundation
import SwiftUI
import Combine
import os

enum NavigationDirection {
    case left
    case right
}

enum DirectionSwipe {
    case next
    case prev

    var value: String {
        switch self {
        case .next: return "next"
        case .prev: return "prev"
        }
    }
}

enum PreviewError: Error {
    case ExecutionError(String)
}

class SocketInfo: ObservableObject {
    @Published var socketConnected: Bool = true
}

struct AeroWindow {
    let windowID: String
    let appName: String
    let windowTitle: String
}

@MainActor
class PreviewManager: ObservableObject {

    private enum FingerDirection {
        case left; case right; case up; case down
    }

    @Published var socketInfo = SocketInfo()
    @Published var workspaceApps: [String: [String]] = [:]
    @Published var openWindows: [AeroWindow] = []
    @Published var showPreview = false
    @Published var selectedWorkspace: String = ""
    @Published var selectedWindowID: String = ""
    @Published var windowSwitcherMode = false

    var onShowPreview: (() -> Void)?
    var onHidePreview: (() -> Void)?

    private var eventTap: CFMachPort? = nil
    private var accDisY: Float = 0
    private var accDisX: Float = 0
    private var prevTouchPositions: [String: NSPoint] = [:]
    private var gestureInProgress = false
    private var verticalLocked = false
    private var gestureStartTime: Date?
    private var previewThresholdMs: Double = 100.0
    private var navigationMode = false
    private var hasOpenedLaunchNext = false
    private var ignoreNextDown = false
    private var gestureActionTriggered = false
    private var lastNavigatedDate: Date = Date()
    private var dynamicFingerCount = 3
    private var cursorLockPosition: NSPoint? = nil
    private var lastTapReleaseTime: Date? = nil
    private var isCooldownActive = false

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "PreviewAerospace",
        category: "Swipe"
    )

    private func runAerospaceCLI(args: [String], stdin: String = "") -> Result<String, PreviewError> {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/aerospace")
        task.arguments = args

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        task.standardOutput = outputPipe
        task.standardError = errorPipe

        if !stdin.isEmpty {
            let inputPipe = Pipe()
            task.standardInput = inputPipe
            if let data = stdin.data(using: .utf8) {
                try? inputPipe.fileHandleForWriting.write(contentsOf: data)
                try? inputPipe.fileHandleForWriting.close()
            }
        }

        do {
            try task.run()
            task.waitUntilExit()

            if task.terminationStatus != 0 {
                let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                let errorString = String(data: errorData, encoding: .utf8) ?? "Unknown CLI Error"
                return .failure(.ExecutionError(errorString))
            }

            let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let outputString = String(data: outputData, encoding: .utf8) ?? ""
            return .success(outputString)
        } catch {
            return .failure(.ExecutionError(error.localizedDescription))
        }
    }

    func start() {
        if eventTap != nil { return }
        logger.info("PreviewManager start")

        eventTap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: NSEvent.EventTypeMask.gesture.rawValue,
            callback: { proxy, type, cgEvent, me in
                let wrapper = Unmanaged<PreviewManager>.fromOpaque(me!).takeUnretainedValue()
                return wrapper.eventHandler(proxy: proxy, eventType: type, cgEvent: cgEvent)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )

        guard let eventTap else { return }

        let runLoopSource = CFMachPortCreateRunLoopSource(nil, eventTap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, CFRunLoopMode.commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.runSketchybarTrigger()
        }
    }

    private func eventHandler(proxy: CGEventTapProxy, eventType: CGEventType, cgEvent: CGEvent) -> Unmanaged<CGEvent>? {
        if eventType.rawValue == NSEvent.EventType.gesture.rawValue, let nsEvent = NSEvent(cgEvent: cgEvent) {
            touchEventHandler(nsEvent)
        } else if eventType == .tapDisabledByUserInput || eventType == .tapDisabledByTimeout {
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
        }
        return Unmanaged.passUnretained(cgEvent)
    }

    private func touchEventHandler(_ nsEvent: NSEvent) {
        let touches = nsEvent.allTouches()
        
        let activeTouches = touches.filter {
            switch $0.phase {
            case .began, .moved, .stationary: return true
            default: return false
            }
        }

        if activeTouches.isEmpty {
            if gestureInProgress {
                logger.info("Fingers left the glass. Tearing down all active UI overlays.")
                cursorLockPosition = nil
                handleGestureEnd()
                
                if showPreview {
                    hidePreview()
                }
            }
            return
        }

        let count = activeTouches.count

        if navigationMode {
            if count < 1 || count > 4 { return }
            if let lockPos = cursorLockPosition {
                CGWarpMouseCursorPosition(lockPos)
            }
        } else {
            if count != 3 && count != 4 {
                if count == 0 { resetGesture() }
                return
            }
        }

        if !gestureInProgress {
            if let lastRelease = lastTapReleaseTime, Date().timeIntervalSince(lastRelease) * 1000 < 100 {
                return
            }

            gestureInProgress = true
            dynamicFingerCount = count
            gestureActionTriggered = false
            accDisX = 0; accDisY = 0
            prevTouchPositions.removeAll()
            gestureStartTime = Date()
            navigationMode = showPreview
            hasOpenedLaunchNext = false
            verticalLocked = false
            isCooldownActive = false
        } else if !navigationMode && count > dynamicFingerCount {
            dynamicFingerCount = count
        }

        if isCooldownActive { return }
        
        if dynamicFingerCount == 3 && ignoreNextDown {
            var downCountTemp = 0
            for touch in activeTouches {
                let id = "\(touch.identity)"
                if let prev = prevTouchPositions[id] {
                    if Float(touch.normalizedPosition.y - prev.y) < 0 {
                        downCountTemp += 1
                    }
                }
            }
            
            if downCountTemp >= 2 {
                gestureActionTriggered = true
                ignoreNextDown = false
                logger.info("Downward swipe intercepted and successfully ignored via ignoreNextDown flag.")
                return
            }
        }

        if gestureActionTriggered && !navigationMode { return }

        var directions: [FingerDirection] = []
        var totalX: Float = 0
        var totalY: Float = 0

        for touch in activeTouches {
            let id = "\(touch.identity)"
            let pos = touch.normalizedPosition

            guard let prev = prevTouchPositions[id] else {
                prevTouchPositions[id] = pos
                continue
            }

            let dx = Float(pos.x - prev.x)
            let dy = Float(pos.y - prev.y)
            
            let velocityMultiplier = 4.0 / Float(count)
            totalX += dx * velocityMultiplier
            totalY += dy * velocityMultiplier

            let direction: FingerDirection = abs(dx) > abs(dy) ? (dx > 0 ? .right : .left) : (dy > 0 ? .up : .down)
            directions.append(direction)
            prevTouchPositions[id] = pos
        }

        if directions.count < count || count == 0 { return }

        if abs(totalY) > abs(totalX) && !navigationMode {
            verticalLocked = true
        }

        accDisX += totalX
        accDisY += totalY

        let leftCount  = directions.filter { $0 == .left }.count
        let rightCount = directions.filter { $0 == .right }.count
        let upCount    = directions.filter { $0 == .up }.count
        let downCount  = directions.filter { $0 == .down }.count

        if downCount == dynamicFingerCount {
            guard let startTime = gestureStartTime else { return }
            let elapsed = Date().timeIntervalSince(startTime) * 1000

            if elapsed > previewThresholdMs {
                if !showPreview {
                    let totalMovement = abs(accDisX) + abs(accDisY)
                    if totalMovement < 0.015 { return }

                    gestureActionTriggered = true
                    windowSwitcherMode = (dynamicFingerCount == 4)
                    
                    let currentMouseLocation = NSEvent.mouseLocation
                    if let screens = NSScreen.screens.first {
                        cursorLockPosition = NSPoint(x: currentMouseLocation.x, y: screens.frame.height - currentMouseLocation.y)
                    }
                    
                    triggerPreview()
                    navigationMode = true
                }
                return
            }
        }

        let movementThreshold: Float = 0.008
        if abs(totalX) < movementThreshold && abs(totalY) < movementThreshold { return }

        if navigationMode {
            let strideThreshold: Float = 0.12
            let now = Date()
            
            if now.timeIntervalSince(lastNavigatedDate) > 0.10 {
                if leftCount >= 1 || totalX < -strideThreshold {
                    navigateItems(direction: .left)
                    accDisX = 0
                    prevTouchPositions.removeAll()
                    lastNavigatedDate = now
                } else if rightCount >= 1 || totalX > strideThreshold {
                    navigateItems(direction: .right)
                    accDisX = 0
                    prevTouchPositions.removeAll()
                    lastNavigatedDate = now
                }
            }
            return
        }

        if dynamicFingerCount == 3 {
            if upCount == 3 {
                gestureActionTriggered = true
                ignoreNextDown = true
                logger.info("3 fingers swiped up. ignoreNextDown armed.")
                return
            }

            let absoluteVerticalDiscrepancy = abs(totalY)
            let isSplitGesture = (downCount == 2 && upCount == 1 && absoluteVerticalDiscrepancy < 0.02) ||
                                 (upCount == 2 && downCount == 1 && absoluteVerticalDiscrepancy < 0.02)

            if isSplitGesture {
                gestureActionTriggered = true
                openLaunchNext()
                return
            }

            if (leftCount >= 2) && !verticalLocked {
                gestureActionTriggered = true
                switchWorkspaceDirectional(direction: .prev)
                return
            }

            if (rightCount >= 2) && !verticalLocked {
                gestureActionTriggered = true
                switchWorkspaceDirectional(direction: .next)
                return
            }
        }
    }

    private func openLaunchNext() {
        guard !hasOpenedLaunchNext else { return }
        hasOpenedLaunchNext = true

        let appURL = URL(fileURLWithPath: "/Applications/LaunchNext.app")
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true

        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { [weak self] _, error in
            if let error = error {
                self?.logger.error("Failed to open LaunchNext.app: \(error.localizedDescription)")
            } else {
                self?.logger.info("Successfully opened LaunchNext.app")
            }
        }
    }

    private func navigateItems(direction: NavigationDirection) {
        if windowSwitcherMode {
            guard !openWindows.isEmpty else { return }
            
            let currentIndex = openWindows.firstIndex(where: { $0.windowID == selectedWindowID }) ?? 0
            let newIndex: Int
            switch direction {
            case .right: newIndex = min(currentIndex + 1, openWindows.count - 1)
            case .left:  newIndex = max(currentIndex - 1, 0)
            }
            
            if openWindows.indices.contains(newIndex) {
                selectedWindowID = openWindows[newIndex].windowID
            }
        } else {
            let sortedWorkspaces = workspaceApps.keys.sorted()
            guard !sortedWorkspaces.isEmpty else { return }
            
            let currentIndex = sortedWorkspaces.firstIndex(of: selectedWorkspace) ?? 0
            let newIndex: Int
            switch direction {
            case .right: newIndex = min(currentIndex + 1, sortedWorkspaces.count - 1)
            case .left:  newIndex = max(currentIndex - 1, 0)
            }

            if sortedWorkspaces.indices.contains(newIndex) && newIndex != currentIndex {
                selectedWorkspace = sortedWorkspaces[newIndex]
            }
        }
    }

    private func handleGestureEnd() {
        guard gestureInProgress else { return }
        
        logger.info("Gesture engine handling wrap-up actions.")

        if !showPreview {
            lastTapReleaseTime = Date()
        }

        if showPreview {
            if let startTime = gestureStartTime, Date().timeIntervalSince(startTime) * 1000 < previewThresholdMs {
                let hasNavigated = windowSwitcherMode ? (!selectedWindowID.isEmpty) : (!selectedWorkspace.isEmpty)
                if !hasNavigated || abs(accDisY) > 0.05 {
                    logger.info("Awkward/Fast long swipe detected during preview. Tearing down overlay.")
                    hidePreview()
                    resetGesture()
                    return
                }
            }

            if windowSwitcherMode {
                if !selectedWindowID.isEmpty {
                    switchToWindow(selectedWindowID)
                }
            } else {
                if !selectedWorkspace.isEmpty {
                    switchToWorkspace(selectedWorkspace)
                }
            }
            resetGesture()
        } else {
            if let startTime = gestureStartTime, !gestureActionTriggered, !isCooldownActive {
                let durationMs = Date().timeIntervalSince(startTime) * 1000
                
                if durationMs < previewThresholdMs && abs(accDisY) > 0.01 {
                    if dynamicFingerCount == 3 {
                        logger.info("Quick workspace switch triggered via short 3-finger placement duration: \(durationMs)ms")
                        resetGesture()
                        quickSwitchWorkspace()
                        return
                    } else if dynamicFingerCount == 4 {
                        logger.info("Quick app switch triggered via short 4-finger flick: \(durationMs)ms")
                        resetGesture()
                        switchToLastUsedApp()
                        return
                    }
                }
            }
            resetGesture()
        }
    }
    
    private func resetGesture() {
        gestureInProgress = false
        accDisY = 0; accDisX = 0
        prevTouchPositions.removeAll()
        verticalLocked = false
        gestureStartTime = nil
        navigationMode = false
        hasOpenedLaunchNext = false
        gestureActionTriggered = false
        isCooldownActive = false
        showPreview = false
    }

    private func quickSwitchWorkspace() {
        let res = runAerospaceCLI(args: ["list-workspaces", "--monitor", "focused", "--empty", "no", "--count"])
        guard case .success(let stdout) = res else { return }

        let countString = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let count = Int(countString) ?? 0

        if count >= 2 {
            _ = runAerospaceCLI(args: ["workspace-back-and-forth"])
        }
    }
    
    private func switchToLastUsedApp() {
        let src = CGEventSource(stateID: .combinedSessionState)
        
        let cmdDown = CGEvent(keyboardEventSource: src, virtualKey: 55, keyDown: true)
        let tabDown = CGEvent(keyboardEventSource: src, virtualKey: 48, keyDown: true)
        let tabUp = CGEvent(keyboardEventSource: src, virtualKey: 48, keyDown: false)
        let cmdUp = CGEvent(keyboardEventSource: src, virtualKey: 55, keyDown: false)
        
        tabDown?.flags = .maskCommand
        tabUp?.flags = .maskCommand
        
        cmdDown?.post(tap: .cgSessionEventTap)
        tabDown?.post(tap: .cgSessionEventTap)
        tabUp?.post(tap: .cgSessionEventTap)
        cmdUp?.post(tap: .cgSessionEventTap)
    }

    private func triggerPreview() {
        if windowSwitcherMode {
            fetchOpenWindows()
        } else {
            fetchWorkspaceApps()
        }
    }

    private func hidePreview() {
        DispatchQueue.main.async {
            self.showPreview = false
            self.workspaceApps = [:]
            self.openWindows = []
            self.selectedWorkspace = ""
            self.selectedWindowID = ""
            self.windowSwitcherMode = false
            self.onHidePreview?()
        }
    }

    func fetchOpenWindows() {
        let res = runAerospaceCLI(args: ["list-windows", "--all", "--format", "window-id=%{window-id},app-name=%{app-name},window-title=%{window-title}"])
        guard case .success(let stdout) = res else { return }

        var parsedWindows: [AeroWindow] = []
        stdout.split(separator: "\n").forEach { line in
            let parts = line.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            var wID = "", app = "", title = ""
            for part in parts {
                if part.hasPrefix("window-id=") { wID = part.replacingOccurrences(of: "window-id=", with: "") }
                if part.hasPrefix("app-name=") { app = part.replacingOccurrences(of: "app-name=", with: "") }
                if part.hasPrefix("window-title=") { title = part.replacingOccurrences(of: "window-title=", with: "") }
            }
            if !wID.isEmpty {
                parsedWindows.append(AeroWindow(windowID: wID, appName: app, windowTitle: title))
            }
        }

        let focusRes = runAerospaceCLI(args: ["list-windows", "--focused", "--format", "%{window-id}"])
        var focusedID = ""
        if case .success(let out) = focusRes {
            focusedID = out.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        DispatchQueue.main.async {
            self.openWindows = parsedWindows
            self.selectedWindowID = parsedWindows.first(where: { $0.windowID == focusedID })?.windowID ?? parsedWindows.first?.windowID ?? ""
            self.showPreview = true
            self.onShowPreview?()
        }
    }

    func fetchWorkspaceApps() {
        let res = runAerospaceCLI(args: ["list-windows", "--all", "--format", "workspace=%{workspace}, app=%{app-name}"])
        guard case .success(let stdout) = res else { return }

        var workspaces: [String: [String]] = [:]
        stdout.split(separator: "\n").forEach { line in
            let comps = line.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            guard comps.count == 2 else { return }

            let ws = comps[0].replacingOccurrences(of: "workspace=", with: "")
            let app = comps[1].replacingOccurrences(of: "app=", with: "")
            workspaces[ws, default: []].append(app)
        }

        let focusRes = runAerospaceCLI(args: ["list-workspaces", "--focused"])
        var currentWorkspace = ""

        if case .success(let ws) = focusRes {
            currentWorkspace = ws.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        DispatchQueue.main.async {
            self.workspaceApps = workspaces
            let nonEmpty = workspaces.filter { !$0.value.isEmpty }.keys.sorted()

            if let apps = workspaces[currentWorkspace], !apps.isEmpty {
                self.selectedWorkspace = currentWorkspace
            } else {
                self.selectedWorkspace = nonEmpty.first ?? currentWorkspace
            }

            self.showPreview = true
            self.onShowPreview?()
        }
    }

    func switchToWorkspace(_ workspace: String) {
        _ = runAerospaceCLI(args: ["workspace", workspace])
        hidePreview()
    }

    func switchToWindow(_ windowID: String) {
        _ = runAerospaceCLI(args: ["focus", "--window-id", windowID])
        hidePreview()
    }

    private func runSketchybarTrigger() {
        let task = Process()
        task.launchPath = "/bin/bash"
        task.arguments = ["-c", "/opt/homebrew/bin/sketchybar --trigger aerospace_workspace_change"]
        try? task.run()
    }

    private func switchWorkspaceDirectional(direction: DirectionSwipe) {
        let listResult = runAerospaceCLI(args: ["list-workspaces", "--monitor", "focused", "--empty", "no"])
        guard case .success(let output) = listResult else { return }

        let filtered = output
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0 != "􀎡" }
            .joined(separator: "\n")

        _ = runAerospaceCLI(args: ["workspace", direction.value, "--stdin"], stdin: filtered)
    }
}
