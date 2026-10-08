import Cocoa
import CodexProfileCore

#if !TESTING
    @main
#endif
enum Main {
    static func main() {
        // Let an explicitly authorized password manager/KV retrieval pipe a key
        // into the signed app. Never accept the secret as a process argument.
        if CommandLine.arguments.contains("--import-glm-key-from-stdin") {
            guard CommandLine.arguments.dropFirst().elementsEqual(["--import-glm-key-from-stdin"]) else {
                fputs("Usage: CodexMultiSwitcher --import-glm-key-from-stdin\n", stderr)
                exit(64)
            }
            do {
                var input = Data()
                while let chunk = try FileHandle.standardInput.read(upToCount: 1024), !chunk.isEmpty {
                    input.append(chunk)
                    guard input.count <= 8192 else { throw GLMCredentialStore.Failure.invalidKey }
                }
                guard let key = String(data: input, encoding: .utf8) else {
                    throw GLMCredentialStore.Failure.invalidKey
                }
                try GLMCredentialStore.save(key)
                print("GLM key saved in this app's Keychain item.")
                exit(0)
            } catch {
                // Fixed messages only: errors and input must not echo a key.
                fputs("Could not import the GLM key. Check the key format and Keychain access.\n", stderr)
                exit(1)
            }
        }
        #if CODEX_MULTI_SWITCHER_PREVIEW || CODEX_MULTI_SWITCHER_LOCAL
            // A double-clickable preview must always use its own profile home,
            // even when launched by Finder without development environment vars.
            let previewHome = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/Codex Multi Switcher Preview")
            guard setenv("CODEX_PROFILE_HOME", previewHome.path, 1) == 0 else {
                fatalError("Unable to configure the preview profile home")
            }
        #endif
        #if CODEX_MULTI_SWITCHER_LOCAL
            let realCodexHome = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".codex")
            guard setenv("CODEX_PROFILE_LIVE_HOME", realCodexHome.path, 1) == 0 else {
                fatalError("Unable to configure the live Codex home")
            }
            guard setenv("CLAUDE_PROFILE_USER_HOME", FileManager.default.homeDirectoryForCurrentUser.path, 1) == 0 else {
                fatalError("Unable to configure the live Claude home")
            }
        #elseif CODEX_MULTI_SWITCHER_PREVIEW
            unsetenv("CODEX_PROFILE_LIVE_HOME")
            unsetenv("CLAUDE_PROFILE_USER_HOME")
        #endif
        let app = NSApplication.shared
        let showInDock = UserDefaults.standard.object(forKey: "showInDock") as? Bool ?? true
        app.setActivationPolicy(showInDock ? .regular : .accessory)

        let appMenu = NSMenu()
        appMenu.addItem(
            withTitle: "Hide Codex Multi Switcher",
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h")
        let hideOthers = appMenu.addItem(
            withTitle: "Hide Others",
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(
            withTitle: "Show All",
            action: #selector(NSApplication.unhideAllApplications(_:)),
            keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "Quit Codex Multi Switcher",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q")
        let appMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        appMenuItem.submenu = appMenu

        let fileMenu = NSMenu(title: "File")
        let showUsageMenuItem = fileMenu.addItem(
            withTitle: "Show Usage Menu",
            action: #selector(AppDelegate.showUsageMenu),
            keyEquivalent: "U")
        fileMenu.addItem(.separator())
        fileMenu.addItem(
            withTitle: "Close Window",
            action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: "w")
        let fileMenuItem = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        fileMenuItem.submenu = fileMenu

        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let editMenuItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        editMenuItem.submenu = editMenu

        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(
            withTitle: "Minimize",
            action: #selector(NSWindow.performMiniaturize(_:)),
            keyEquivalent: "m")
        let windowMenuItem = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
        windowMenuItem.submenu = windowMenu

        let mainMenu = NSMenu()
        mainMenu.addItem(appMenuItem)
        mainMenu.addItem(fileMenuItem)
        mainMenu.addItem(editMenuItem)
        mainMenu.addItem(windowMenuItem)
        app.mainMenu = mainMenu

        let delegate = AppDelegate()
        showUsageMenuItem.target = delegate
        app.delegate = delegate
        app.run()
    }
}
