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
        NSApplication.shared.terminate(nil)
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
        let panelWidth: CGFloat = 800
        let panelHeight: CGFloat = 500
        
        if previewWindow == nil {
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight),
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
            hostingView.translatesAutoresizingMaskIntoConstraints = false
            
            let contentView = NSView(frame: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight))
            contentView.addSubview(hostingView)
            panel.contentView = contentView
            
            NSLayoutConstraint.activate([
                hostingView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
                hostingView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
                hostingView.topAnchor.constraint(equalTo: contentView.topAnchor),
                hostingView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
            ])
            
            previewWindow = panel
        }
        
        if let panel = previewWindow, let screen = NSScreen.main {
            panel.setFrame(NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight), display: true)
            
            let rawFrame = screen.frame
            let x = rawFrame.minX + (rawFrame.width - panelWidth) / 2
            let y = rawFrame.minY + (rawFrame.height - panelHeight) / 2
            
            panel.setFrameOrigin(NSPoint(x: x, y: y))
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
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
