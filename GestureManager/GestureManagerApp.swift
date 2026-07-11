import SwiftUI
import Cocoa

func checkAccessibilityPermissions() {
    let options = [
        kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true
    ]
    if !AXIsProcessTrustedWithOptions(options as CFDictionary) {
        let bundleID = Bundle.main.bundleIdentifier ?? "GestureManager"
        _ = try? Process.run(
            URL(filePath: "/usr/bin/tccutil"),
            arguments: ["reset", "Accessibility", bundleID]
        )
        NSApp.terminate(nil)
    }
}

@main
struct GestureManagerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var previewManager: PreviewManager!
    var previewWindow: NSPanel?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        checkAccessibilityPermissions()
        
        previewManager = PreviewManager()
        previewManager.onShowPreview = { [weak self] in
            self?.showPreviewWindow()
        }
        previewManager.onHidePreview = { [weak self] in
            self?.hidePreviewWindow()
        }
        previewManager.start()
    }
    
    private func showPreviewWindow() {
        if previewWindow == nil {
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 0, height: 0),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.level = .statusBar
            panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .transient]
            panel.isMovableByWindowBackground = false
            panel.hasShadow = false
            panel.ignoresMouseEvents = false
            
            let hostingView = NSHostingView(rootView: WorkspacePreviewView(previewManager: previewManager))
            hostingView.sizingOptions = [.intrinsicContentSize]
            
            panel.contentView = hostingView
            previewWindow = panel
        }
        
        if let panel = previewWindow, let screen = NSScreen.main {
            panel.contentView?.layoutSubtreeIfNeeded()
            
            let targetSize = panel.contentView?.intrinsicContentSize ?? NSSize(width: 400, height: 200)
            let rawFrame = screen.frame
            let x = rawFrame.minX + (rawFrame.width - targetSize.width) / 2
            let y = rawFrame.minY + (rawFrame.height - targetSize.height) / 2.2
            
            panel.setFrame(NSRect(x: x, y: y, width: targetSize.width, height: targetSize.height), display: true, animate: false)
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.10
                panel.animator().alphaValue = 1.0
            }
        }
    }
    
    private func hidePreviewWindow() {
        guard let panel = previewWindow else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            panel.animator().alphaValue = 0
        }, completionHandler: {
            panel.orderOut(nil)
        })
    }
}
