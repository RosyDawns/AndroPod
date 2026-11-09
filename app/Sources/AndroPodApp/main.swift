import AppKit
import SwiftUI

if CommandLine.arguments.contains("--self-test") {
    exit(SelfTest.run())
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var model: AppModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let model = AppModel()


        self.model = model

        let root = MainView().environmentObject(model)


        let hosting = NSHostingView(rootView: root)


        hosting.frame = NSRect(x: 0, y: 0, width: 880, height: 600)
        hosting.autoresizingMask = [.width, .height]

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 880, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "AndroPod"
        window.contentView = hosting
        window.minSize = NSSize(width: 760, height: 520)
        // Setting contentView can resize the window to the hosting view's ideal
        // size; pin it afterwards so the grid keeps its intended proportions.
        window.setContentSize(NSSize(width: 880, height: 600))
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.setContentSize(NSSize(width: 880, height: 600))
        self.window = window

        // Do not call NSApp.activate(ignoringOtherApps:) here. On this OS it
        // aborts the process (SIGABRT) with no message, which is why the app
        // kept vanishing right after launch. makeKeyAndOrderFront is enough.
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }


    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.regular)
application.run()
