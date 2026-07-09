import SwiftUI
import Cocoa
internal import UniformTypeIdentifiers

struct WorkspacePreviewView: View {
    @ObservedObject var previewManager: PreviewManager

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            
            HStack(alignment: .top, spacing: 16) {
                if previewManager.windowSwitcherMode {
                    ForEach(previewManager.openWindows, id: \.windowID) { win in
                        WindowColumn(
                            window: win,
                            isSelected: win.windowID == previewManager.selectedWindowID
                        )
                        .onTapGesture {
                            previewManager.switchToWindow(win.windowID)
                        }
                    }
                } else {
                    let workspaces = previewManager.workspaceApps.keys.sorted()
                    ForEach(Array(workspaces.enumerated()), id: \.element) { index, ws in
                        WorkspaceColumn(
                            workspace: ws,
                            apps: previewManager.workspaceApps[ws] ?? [],
                            isSelected: ws == previewManager.selectedWorkspace
                        )
                        .onTapGesture {
                            previewManager.switchToWorkspace(ws)
                        }
                    }
                }
            }
            .padding(.vertical, 24)
            .padding(.horizontal, 24)
            .background(VisualEffectBlur(material: .hudWindow, blendingMode: .withinWindow))
            .background(Color(nsColor: .windowBackgroundColor).opacity(0.3))
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
            
            Spacer(minLength: 0)
        }
        .frame(maxWidth: 1200, maxHeight: 500)
    }
}

struct WindowColumn: View {
    let window: AeroWindow
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .center, spacing: 12) {
            AppIconView(appName: window.appName, isSelected: isSelected)
            
            Text(window.appName)
                .font(.system(size: 14, weight: .black))
                .foregroundColor(isSelected ? .white : .primary.opacity(0.7))
                .lineLimit(1)
                .frame(maxWidth: 80)
        }
        .padding(.vertical, 16)
        .padding(.horizontal, 14)
        .frame(minWidth: 75)
        .background(isSelected ? Color(white: 0.25).opacity(0.6) : Color.clear, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .scaleEffect(isSelected ? 1.04 : 1.0)
        .animation(.spring(response: 0.25, dampingFraction: 0.65), value: isSelected)
    }
}

struct WorkspaceColumn: View {
    let workspace: String
    let apps: [String]
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .center, spacing: 12) {
            Text(workspace)
                .font(.system(size: 18, weight: .black))
                .foregroundColor(isSelected ? .white : .primary.opacity(0.7))
            
            VStack(spacing: 10) {
                if apps.isEmpty {
                    Circle()
                        .fill(Color.secondary.opacity(0.15))
                        .frame(width: 28, height: 28)
                } else {
                    ForEach(apps, id: \.self) { appName in
                        AppIconView(appName: appName, isSelected: isSelected)
                    }
                }
            }
        }
        .padding(.vertical, 16)
        .padding(.horizontal, 14)
        .frame(minWidth: 75)
        .background(isSelected ? Color(white: 0.25).opacity(0.6) : Color.clear, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .scaleEffect(isSelected ? 1.04 : 1.0)
        .animation(.spring(response: 0.25, dampingFraction: 0.65), value: isSelected)
    }
}

struct VisualEffectBlur: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

struct AppIconView: View {
    let appName: String
    let isSelected: Bool
    
    var body: some View {
        Image(nsImage: fetchIcon(for: appName))
            .resizable()
            .scaledToFit()
            .frame(width: 36, height: 36)
            .shadow(color: Color.black.opacity(0.15), radius: 3, y: 1)
    }
    
    private func fetchIcon(for name: String) -> NSImage {
        if let runningApp = NSWorkspace.shared.runningApplications.first(where: {
            $0.localizedName?.lowercased() == name.lowercased()
        }), let icon = runningApp.icon {
            return icon
        }
        
        let standardPaths = [
            "/Applications/\(name).app",
            "/Applications/Utilities/\(name).app",
            "\(NSHomeDirectory())/Applications/\(name).app",
            "/System/Applications/\(name).app"
        ]
        
        for path in standardPaths {
            if FileManager.default.fileExists(atPath: path) {
                return NSWorkspace.shared.icon(forFile: path)
            }
        }
        
        return NSWorkspace.shared.icon(for: .application)
    }
}
