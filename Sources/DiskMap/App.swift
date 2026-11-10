import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let startPath: String?
    private let snapshotPath: String?
    private var controller: MainWindowController?

    init(startPath: String?, snapshotPath: String?) {
        self.startPath = startPath
        self.snapshotPath = snapshotPath
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        NSApp.mainMenu = makeMenu()

        let controller = MainWindowController()
        controller.snapshotPath = snapshotPath
        self.controller = controller
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        if let startPath {
            controller.startScan(path: startPath)
        } else if let snapshotPath {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { controller.writeSnapshot(to: snapshotPath) }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: filename, isDirectory: &isDirectory), isDirectory.boolValue,
              let controller else { return false }
        controller.startScan(path: filename)
        return true
    }

    private func makeMenu() -> NSMenu {
        let main = NSMenu()
        func submenu(_ title: String) -> NSMenu {
            let item = NSMenuItem()
            let menu = NSMenu(title: title)
            item.submenu = menu
            main.addItem(item)
            return menu
        }
        func add(_ menu: NSMenu, _ title: String, _ action: Selector, _ key: String = "",
                 _ modifiers: NSEvent.ModifierFlags = .command) {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
        }
        let up = String(UnicodeScalar(NSUpArrowFunctionKey)!)
        let down = String(UnicodeScalar(NSDownArrowFunctionKey)!)
        let backspace = String(UnicodeScalar(NSBackspaceCharacter)!)

        let app = submenu("DiskMap")
        add(app, "About DiskMap", #selector(NSApplication.orderFrontStandardAboutPanel(_:)))
        app.addItem(.separator())
        add(app, "Open Privacy Settings…", #selector(MainWindowController.openPrivacySettings(_:)))
        app.addItem(.separator())
        add(app, "Hide DiskMap", #selector(NSApplication.hide(_:)), "h")
        add(app, "Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option])
        app.addItem(.separator())
        add(app, "Quit DiskMap", #selector(NSApplication.terminate(_:)), "q")

        let file = submenu("File")
        add(file, "Scan Macintosh HD", #selector(MainWindowController.scanDataVolume(_:)), "d", [.command, .shift])
        add(file, "Scan Home Folder", #selector(MainWindowController.scanHome(_:)), "h", [.command, .shift])
        add(file, "Scan Folder…", #selector(MainWindowController.chooseFolder(_:)), "o")
        file.addItem(.separator())
        add(file, "Rescan", #selector(MainWindowController.rescanOrStop(_:)), "r")
        add(file, "Disk Summary…", #selector(MainWindowController.showSummary(_:)), "i")
        file.addItem(.separator())
        add(file, "Reveal in Finder", #selector(MainWindowController.revealInFinder(_:)), "r", [.command, .shift])
        add(file, "Move to Trash…", #selector(MainWindowController.moveToTrash(_:)), backspace)
        file.addItem(.separator())
        add(file, "Close Window", #selector(NSWindow.performClose(_:)), "w")

        let edit = submenu("Edit")
        add(edit, "Copy Path", #selector(MainWindowController.copyPath(_:)), "c")

        let view = submenu("View")
        add(view, "Zoom In", #selector(MainWindowController.zoomIn(_:)), down)
        add(view, "Zoom Out", #selector(MainWindowController.zoomOut(_:)), up)
        add(view, "Zoom to Top", #selector(MainWindowController.zoomToRoot(_:)), up, [.command, .shift])
        view.addItem(.separator())
        add(view, "Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control])

        let window = submenu("Window")
        add(window, "Minimize", #selector(NSWindow.performMiniaturize(_:)), "m")
        add(window, "Zoom", #selector(NSWindow.performZoom(_:)))
        NSApp.windowsMenu = window
        return main
    }
}
