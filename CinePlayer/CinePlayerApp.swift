import Foundation
import SwiftUI
import SwiftData
#if os(iOS)
import UIKit
#endif
#if os(macOS)
import AppKit
#endif

@main
struct CinePlayerApp: App {
    @StateObject private var sessionStore = PlayerSessionStore.shared
    @StateObject private var playerModel = VideoPlayerModel()

    private let sharedModelContainer: ModelContainer = {
        let schema = Schema([PlaybackHistoryRecord.self])
        let persistentConfig = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false,
            cloudKitDatabase: .none
        )
        do {
            return try ModelContainer(for: schema, configurations: [persistentConfig])
        } catch {
            NSLog("GlassMPV failed to create persistent ModelContainer: %@", String(describing: error))
            let memoryConfig = ModelConfiguration(
                schema: schema,
                isStoredInMemoryOnly: true,
                cloudKitDatabase: .none
            )
            do {
                return try ModelContainer(for: schema, configurations: [memoryConfig])
            } catch {
                fatalError("Could not create ModelContainer: \(error)")
            }
        }
    }()

    #if os(iOS)
    @UIApplicationDelegateAdaptor(CinePlayerIOSAppDelegate.self) var iosAppDelegate
    #endif

    #if os(macOS)
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) var macAppDelegate
    @StateObject private var windowController = PlayerWindowController()
    @State private var aboutWindow: NSWindow?
    #endif

    var body: some Scene {
        #if os(macOS)
        Window("GlassMPV", id: "main-window") {
            rootContentView
        }
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("关于") {
                    showAboutWindow()
                }
            }
            CommandGroup(after: .newItem) {
                Button("打开文件…") {
                    macAppDelegate.openFileFromMenuOrDock()
                }
                .keyboardShortcut("o", modifiers: [.command])

                Button("打开URL…") {
                    macAppDelegate.openURLFromMenuOrDock()
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            }
        }
        #else
        WindowGroup {
            rootContentView
        }
        #endif
    }

    @ViewBuilder
    private var rootContentView: some View {
        ContentView()
            .environmentObject(sessionStore)
            .environmentObject(playerModel)
            .modelContainer(sharedModelContainer)
            #if os(macOS)
                .environmentObject(windowController)
            #else
                .onOpenURL { url in
                    if url.isFileURL {
                        sessionStore.open(url: url)
                    }
                    #if DEBUG
                    if !url.isFileURL,
                       url.scheme == "glassmpv" || url.scheme == "cineplayer",
                       url.host(percentEncoded: false) == "smoke",
                       let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                       let name = components.queryItems?.first(where: { $0.name == "file" })?.value,
                       !name.isEmpty,
                       let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
                    {
                        let targetURL = docs.appendingPathComponent((name as NSString).lastPathComponent)
                        sessionStore.open(url: targetURL)
                    }
                    #endif
                }
                #if DEBUG
                .task {
                    guard sessionStore.currentSource == nil,
                          let name = UserDefaults.standard.string(forKey: "smokeFile"),
                          !name.isEmpty,
                          let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
                    else { return }
                    try? await Task.sleep(for: .milliseconds(500))
                    let targetURL = docs.appendingPathComponent((name as NSString).lastPathComponent)
                    sessionStore.open(url: targetURL)
                }
                #endif
            #endif
    }

    #if os(macOS)
    private func showAboutWindow() {
        if let aboutWindow {
            aboutWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 500),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: AboutPage())
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        aboutWindow = window
    }
    #endif
}

#if os(iOS)
final class CinePlayerIOSAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _: UIApplication,
        supportedInterfaceOrientationsFor _: UIWindow?
    ) -> UIInterfaceOrientationMask {
        if UIDevice.current.userInterfaceIdiom != .phone {
            return .all
        }
        return PlatformServices.currentIOSPlayerOrientationLock()
    }
}
#endif
