import AppKit
import SwiftUI

@main
struct OpenRecastApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("OpenRecast", id: "main") {
            RootView()
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@Observable
final class AppModel {
    enum Route: Equatable {
        case home
        case folder(Category, toolID: String?)
    }

    var route: Route = .home
    /// Files handed to the next tool panel that opens (from a drop on the home screen).
    var preload: [URL] = []

    func open(_ category: Category, tool: String? = nil, files: [URL] = []) {
        preload = files
        withAnimation(.spring(response: 0.45, dampingFraction: 0.86)) {
            route = .folder(category, toolID: tool)
        }
    }

    func goHome() {
        withAnimation(.spring(response: 0.45, dampingFraction: 0.86)) { route = .home }
    }
}

struct RootView: View {
    @State private var app = AppModel()

    var body: some View {
        ZStack {
            Backdrop()
            switch app.route {
            case .home:
                HomeView()
                    .transition(.opacity.combined(with: .scale(scale: 0.985)))
            case .folder(let category, let toolID):
                FolderView(category: category, toolID: toolID)
                    .transition(.opacity.combined(with: .offset(x: 28)))
            }
        }
        .environment(app)
        .frame(width: 940, height: 600)
    }
}
