import SwiftUI
import Cocoa
internal import UniformTypeIdentifiers

struct WorkspacePreviewView: View {
    @ObservedObject var previewManager: PreviewManager

    private var computedWorkspaceHeight: CGFloat {
        let maxAppCount = previewManager.workspaceApps.values.map { $0.count }.max() ?? 0
        let safeAppCount = CGFloat(max(maxAppCount, 1))
        
        // (Count * 64) + ((Count - 1) * 12) + 32
        return (safeAppCount * 64) + ((safeAppCount - 1) * 12) + 32
    }

    var body: some View {
        VStack(spacing: 0) {
            if previewManager.windowSwitcherMode {
                // APP SWITCHER
                HStack(alignment: .center, spacing: 16) {
                    ForEach(previewManager.openWindows, id: \.windowID) { win in
                        WindowColumn(
                            window: win,
                            isSelected: win.windowID == previewManager.selectedWindowID
                        )
                        .onTapGesture {
                            previewManager.switchToWindow(win.windowID)
                        }
                    }
                }
                .padding(.vertical, 20)
                .padding(.horizontal, 20)
                .background(VisualEffectBlur(material: .hudWindow, blendingMode: .withinWindow))
                .background(Color(nsColor: .windowBackgroundColor).opacity(0.3))
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                
            } else {
                let workspaces = previewManager.workspaceApps.keys.sorted()
                let dynamicAppsHeight = computedWorkspaceHeight
                
                // WORKSPACE SWITCHER
                VStack(alignment: .center, spacing: 0) {
                    // Row 1: Titles
                    HStack(alignment: .center, spacing: 16) {
                        ForEach(workspaces, id: \.self) { ws in
                            Text(ws)
                                .font(.system(size: 24, weight: .black))
                                .foregroundColor(ws == previewManager.selectedWorkspace ? .white : .primary.opacity(0.7))
                                .frame(width: 110, alignment: .center)
                        }
                    }
                    .padding(.top, 24)
                    .padding(.bottom, 28)
                    
                    // Row 2: Icons
                    HStack(alignment: .top, spacing: 16) {
                        ForEach(workspaces, id: \.self) { ws in
                            let isCurrentWorkspace = (ws == previewManager.selectedWorkspace)
                            
                            VStack(spacing: 0) {
                                Spacer(minLength: 0)
                                
                                VStack(spacing: 12) {
                                    let apps = previewManager.workspaceApps[ws] ?? []
                                    if apps.isEmpty {
                                        Circle()
                                            .fill(Color.secondary.opacity(0.15))
                                            .frame(width: 52, height: 52)
                                    } else {
                                        ForEach(Array(apps.enumerated()), id: \.offset) { _, appName in
                                            AppIconView(
                                                appName: appName,
                                                isSelected: isCurrentWorkspace,
                                                size: 64
                                            )
                                        }
                                    }
                                }
                                
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 16)
                            .padding(.horizontal, 12)
                            .frame(width: 110, height: dynamicAppsHeight)
                            .background(isCurrentWorkspace ? Color(white: 0.25).opacity(0.6) : Color.clear, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .scaleEffect(isCurrentWorkspace ? 1.04 : 1.0)
                            .animation(.spring(response: 0.25, dampingFraction: 0.65), value: isCurrentWorkspace)
                            .onTapGesture {
                                previewManager.switchToWorkspace(ws)
                            }
                        }
                    }
                    .padding(.bottom, 20)
                }
                .padding(.horizontal, 20)
                .background(VisualEffectBlur(material: .hudWindow, blendingMode: .withinWindow))
                .background(Color(nsColor: .windowBackgroundColor).opacity(0.3))
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
        }
        .fixedSize(horizontal: true, vertical: true)
    }
}

struct WindowColumn: View {
    let window: AeroWindow
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .center, spacing: 8) {
            Spacer(minLength: 0)
            
            AppIconView(appName: window.appName, isSelected: isSelected, size: 64)
                .padding(.bottom, 4)
            
            VStack(alignment: .center, spacing: 2) {
                Text(window.appName)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(isSelected ? .white : .primary.opacity(0.9))
                    .lineLimit(1)
                    .truncationMode(.tail)
                
                Text(window.windowTitle)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundColor(isSelected ? .white.opacity(0.8) : .secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(width: 90)
            
            Spacer(minLength: 0)
        }
        .padding(.vertical, 16)
        .padding(.horizontal, 10)
        .frame(width: 110, height: 170)
        .background(
            isSelected ? Color(white: 0.25).opacity(0.6) : Color.clear,
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
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
    let size: CGFloat
    
    var body: some View {
        Image(nsImage: fetchIcon(for: appName))
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
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
