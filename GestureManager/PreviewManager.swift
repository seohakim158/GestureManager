import Cocoa
import Foundation
import SwiftUI
import Combine

enum DirectionSwipe {
    case next
    case prev
    case left
    case right

    var value: String {
        switch self {
        case .next: return "next"
        case .prev: return "prev"
        default: return ""
        }
    }
}

enum PreviewError: Error {
    case ExecutionError(String)
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

    @Published var workspaceApps: [String: [String]] = [:]
    @Published var openWindows: [AeroWindow] = []
    @Published var showPreview = false
    @Published var selectedWorkspace: String = ""
    @Published var selectedWindowID: String = ""
    @Published var windowSwitcherMode = false

    var onShowPreview: (() -> Void)?
    var onHidePreview: (() -> Void)?

    private var eventTap: CFMachPort? = nil
    private var accDisX: Float = 0
    private var prevTouchPositions: [String: NSPoint] = [:]
    private var gestureInProgress = false
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

        let mask = NSEvent.EventTypeMask.gesture.rawValue | NSEvent.EventTypeMask.keyDown.rawValue

        eventTap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
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
        if eventType == .keyDown && showPreview && windowSwitcherMode {
            if let nsEvent = NSEvent(cgEvent: cgEvent) {
                if nsEvent.charactersIgnoringModifiers?.lowercased() == "q" {
                    closeSelectedWindow()
                    return nil
                }
            }
        }
        
        if eventType.rawValue == NSEvent.EventType.gesture.rawValue, let nsEvent = NSEvent(cgEvent: cgEvent) {
            touchEventHandler(nsEvent)
        } else if eventType == .tapDisabledByUserInput || eventType == .tapDisabledByTimeout {
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
        }
        return Unmanaged.passUnretained(cgEvent)
    }

    private func closeSelectedWindow() {
        let windowIDToClose = selectedWindowID
        guard !windowIDToClose.isEmpty else { return }
        
        guard let currentIndex = openWindows.firstIndex(where: { $0.windowID == windowIDToClose }) else { return }
        
        _ = runAerospaceCLI(args: ["close", "--quit-if-last-window", "--window-id", windowIDToClose])
        
        var nextSelectedID = ""
        if openWindows.count > 1 {
            if currentIndex < openWindows.count - 1 {
                nextSelectedID = openWindows[currentIndex + 1].windowID
            } else {
                nextSelectedID = openWindows[currentIndex - 1].windowID
            }
        }
        
        fetchOpenWindows()
        
        DispatchQueue.main.async {
            if !nextSelectedID.isEmpty {
                self.selectedWindowID = nextSelectedID
            }
        }
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
            if count == 1 && !gestureInProgress {
                return
            }
            if count != 3 && count != 4 {
                if count == 0 { resetGesture() }
                return
            }
        }

        if !gestureInProgress {
            let incomingCount = activeTouches.count
            
            if let lastRelease = lastTapReleaseTime {
                let elapsedMs = Date().timeIntervalSince(lastRelease) * 1000
                let requiredCooldown: Double = (incomingCount == 3) ? 0.0 : 100.0
                
                if elapsedMs < requiredCooldown {
                    return
                }
            }

            gestureInProgress = true
            dynamicFingerCount = count
            gestureActionTriggered = false
            accDisX = 0
            prevTouchPositions.removeAll()
            gestureStartTime = Date()
            navigationMode = showPreview
            hasOpenedLaunchNext = false
        } else if !navigationMode && count > dynamicFingerCount {
            dynamicFingerCount = count
        }
        
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

        accDisX += totalX

        let leftCount  = directions.filter { $0 == .left }.count
        let rightCount = directions.filter { $0 == .right }.count
        let upCount    = directions.filter { $0 == .up }.count
        let downCount  = directions.filter { $0 == .down }.count

        if downCount == dynamicFingerCount {
            guard let startTime = gestureStartTime else { return }
            let elapsed = Date().timeIntervalSince(startTime) * 1000

            if elapsed > previewThresholdMs {
                if !showPreview {
                    let totalMovement = abs(accDisX) + abs(totalY)
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
                return
            }

            let isStrictSplitGesture = (downCount == 2 && upCount == 1) || (upCount == 2 && downCount == 1)

            if isStrictSplitGesture {
                gestureActionTriggered = true
                openLaunchNext()
                return
            }

            if (leftCount >= 2) {
                gestureActionTriggered = true
                switchWorkspaceDirectional(direction: .prev)
                return
            }

            if (rightCount >= 2) {
                gestureActionTriggered = true
                switchWorkspaceDirectional(direction: .next)
                return
            }
        }
    }

    private func handleGestureEnd() {
        guard gestureInProgress else { return }

        if !showPreview {
            lastTapReleaseTime = Date()
        }

        if showPreview {
            if let startTime = gestureStartTime, Date().timeIntervalSince(startTime) * 1000 < previewThresholdMs {
                let hasNavigated = windowSwitcherMode ? (!selectedWindowID.isEmpty) : (!selectedWorkspace.isEmpty)
                if !hasNavigated || abs(accDisX) > 0.05 {
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
            if let startTime = gestureStartTime, !gestureActionTriggered {
                let durationMs = Date().timeIntervalSince(startTime) * 1000
                
                if durationMs < previewThresholdMs {
                    if dynamicFingerCount == 3 {
                        resetGesture()
                        quickSwitchWorkspace()
                        return
                    } else if dynamicFingerCount == 4 {
                        resetGesture()
                        switchToLastUsedApp()
                        return
                    }
                }
            }
            resetGesture()
        }
    }

    private func openLaunchNext() {
        guard !hasOpenedLaunchNext else { return }
        hasOpenedLaunchNext = true

        let appURL = URL(fileURLWithPath: "/Applications/LaunchNext.app")
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true

        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { _, _ in }
    }

    private func navigateItems(direction: DirectionSwipe) {
        if windowSwitcherMode {
            guard !openWindows.isEmpty else { return }
            
            let currentIndex = openWindows.firstIndex(where: { $0.windowID == selectedWindowID }) ?? 0
            let newIndex: Int
            switch direction {
            case .right: newIndex = min(currentIndex + 1, openWindows.count - 1)
            case .left:  newIndex = max(currentIndex - 1, 0)
            default:     return
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
            default:     return
            }

            if sortedWorkspaces.indices.contains(newIndex) && newIndex != currentIndex {
                selectedWorkspace = sortedWorkspaces[newIndex]
            }
        }
    }
    
    private func resetGesture() {
        gestureInProgress = false
        accDisX = 0
        prevTouchPositions.removeAll()
        gestureStartTime = nil
        navigationMode = false
        hasOpenedLaunchNext = false
        gestureActionTriggered = false
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
        let res = runAerospaceCLI(args: ["list-windows", "--all", "--format", "window-id=%{window-id},app-name=%{app-name},window-title=%{window-title},workspace=%{workspace}"])
        guard case .success(let stdout) = res else { return }

        var intermediateWindows: [(window: AeroWindow, workspace: String)] = []
        
        stdout.split(separator: "\n").forEach { line in
            let parts = line.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            var wID = "", app = "", title = "", ws = ""
            for part in parts {
                if part.hasPrefix("window-id=") { wID = part.replacingOccurrences(of: "window-id=", with: "") }
                if part.hasPrefix("app-name=") { app = part.replacingOccurrences(of: "app-name=", with: "") }
                if part.hasPrefix("window-title=") { title = part.replacingOccurrences(of: "window-title=", with: "") }
                if part.hasPrefix("workspace=") { ws = part.replacingOccurrences(of: "workspace=", with: "") }
            }
            if !wID.isEmpty {
                let windowItem = AeroWindow(windowID: wID, appName: app, windowTitle: title)
                intermediateWindows.append((window: windowItem, workspace: ws))
            }
        }

        intermediateWindows.sort {
            if $0.workspace != $1.workspace {
                return $0.workspace < $1.workspace
            }
            return $0.window.appName.localizedStandardCompare($1.window.appName) == .orderedAscending
        }

        let parsedWindows = intermediateWindows.map { $0.window }

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

    nonisolated private func runSketchybarTrigger() {
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
