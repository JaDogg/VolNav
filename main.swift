import Cocoa
import ApplicationServices

// MARK: - App Registry
//
// Single source of truth: add a bundle ID once here and it is automatically
// included in the supported-apps check AND gets the right tab shortcut.
// Two shortcut schemes exist on macOS:
//   .shiftBracket  ->  Cmd+Shift+] / Cmd+Shift+[
//   .optionArrow   ->  Cmd+Option+Right / Cmd+Option+Left

enum TabShortcut {
    case shiftBracket   // Cmd+Shift+] / Cmd+Shift+[
    case optionArrow    // Cmd+Option+Right / Cmd+Option+Left
}

/// Maps every supported bundle ID to its tab-switching shortcut scheme.
/// To add a new app: insert one line here — nothing else needs to change.
let appRegistry: [String: TabShortcut] = [

    // Browsers — Safari & Finder
    "com.apple.Safari":                     .shiftBracket,
    "com.apple.SafariTechnologyPreview":    .shiftBracket,
    "com.apple.finder":                     .shiftBracket,

    // Browsers — Chromium-based
    "com.google.Chrome":                    .optionArrow,
    "com.google.Chrome.beta":               .optionArrow,
    "com.google.Chrome.dev":                .optionArrow,
    "com.google.Chrome.canary":             .optionArrow,
    "com.microsoft.edgemac":                .optionArrow,
    "com.microsoft.edgemac.Beta":           .optionArrow,
    "com.microsoft.edgemac.Dev":            .optionArrow,
    "com.brave.Browser":                    .optionArrow,
    "com.brave.Browser.beta":               .optionArrow,
    "com.brave.Browser.nightly":            .optionArrow,
    "com.operasoftware.Opera":              .optionArrow,
    "com.vivaldi.Vivaldi":                  .optionArrow,
    "company.thebrowser.Browser":           .optionArrow,   // Arc

    // Browsers — Firefox-based
    "org.mozilla.firefox":                  .optionArrow,
    "org.mozilla.firefoxdeveloperedition":  .optionArrow,
    "org.mozilla.nightly":                  .optionArrow,
    "com.zen-browser.app":                  .optionArrow,   // Zen Browser

    // Terminals
    "com.apple.Terminal":                   .shiftBracket,
    "com.googlecode.iterm2":                .shiftBracket,
    "dev.warp.Warp-Stable":                 .shiftBracket,
    "com.mitchellh.ghostty":                .shiftBracket,
    "net.kovidgoyal.kitty":                 .shiftBracket,
    "co.zeit.hyper":                        .shiftBracket,

    // Editors — VSCode family
    "com.microsoft.VSCode":                 .optionArrow,
    "com.microsoft.VSCodeInsiders":         .optionArrow,
    "com.vscodium.codium":                  .optionArrow,   // VSCodium
    "com.todesktop.230313mzl4w4u92":        .optionArrow,   // Cursor
    "com.exafunction.windsurf":             .optionArrow,   // Windsurf

    // Editors — other
    "com.apple.dt.Xcode":                   .shiftBracket,
    "com.sublimetext.4":                    .shiftBracket,
    "com.sublimetext.3":                    .shiftBracket,
    "com.panic.Nova":                       .shiftBracket,

    // Editors — JetBrains IDEs
    "com.jetbrains.intellij":               .shiftBracket,  // IntelliJ IDEA Ultimate
    "com.jetbrains.intellij.ce":            .shiftBracket,  // IntelliJ IDEA Community
    "com.jetbrains.pycharm":                .shiftBracket,  // PyCharm Professional
    "com.jetbrains.pycharm.ce":             .shiftBracket,  // PyCharm Community
    "com.jetbrains.clion":                  .shiftBracket,
    "com.jetbrains.webstorm":               .shiftBracket,
    "com.jetbrains.goland":                 .shiftBracket,
    "com.jetbrains.rider":                  .shiftBracket,
    "com.jetbrains.rubymine":               .shiftBracket,
    "com.jetbrains.datagrip":               .shiftBracket,
    "com.jetbrains.fleet":                  .shiftBracket,
    "com.jetbrains.AppCode":                .shiftBracket,
]

/// Derived automatically — no need to maintain a separate list.
let supportedApps: Set<String> = Set(appRegistry.keys)

let NX_KEYTYPE_SOUND_UP:   Int64 = 0
let NX_KEYTYPE_SOUND_DOWN: Int64 = 1
let NX_KEYTYPE_MUTE:       Int64 = 7

/// Sentinel stamped on synthetic key events so our tap never re-intercepts them.
let kSyntheticEventMarker: Int64 = 0xDEADBEEF

/// CGEventType rawValue 14 = NX system-defined (media keys, volume, etc.)
let systemDefinedEventType = CGEventType(rawValue: 14)!

struct TabKeyStroke {
    let keyCode: CGKeyCode
    let flags: CGEventFlags
}

// MARK: - Global State

var eventTap: CFMachPort?
var runLoopSource: CFRunLoopSource?
var shortcutsEnabled = true
var cycleAllApplications = true
let kPrefCycleAllApplications = "CycleAllApplicationsEnabled"

// MRU list of regular apps (most recent first)
var appMRU: [pid_t] = []

// MARK: - App Switching (MRU)

func seedMRU() {
    let me = NSRunningApplication.current.processIdentifier
    let regularApps = NSWorkspace.shared.runningApplications
        .filter { $0.activationPolicy == .regular }
    if let front = NSWorkspace.shared.frontmostApplication,
       front.activationPolicy == .regular {
        appMRU = [front.processIdentifier] + regularApps
            .map { $0.processIdentifier }
            .filter { $0 != front.processIdentifier }
    } else {
        appMRU = regularApps.map { $0.processIdentifier }
    }
    // Do not include this utility app in MRU.
    appMRU.removeAll { $0 == me }
}

func nextAppPID(forward: Bool) -> pid_t? {
    guard !appMRU.isEmpty else { return nil }
    if let front = NSWorkspace.shared.frontmostApplication,
       front.activationPolicy == .regular {
        let currentPID = front.processIdentifier
        if let idx = appMRU.firstIndex(of: currentPID) {
            return forward
                ? appMRU[(idx + 1) % appMRU.count]
                : appMRU[(idx - 1 + appMRU.count) % appMRU.count]
        }
    }
    return appMRU.first
}

func activateApp(pid: pid_t) {
    if let app = NSRunningApplication(processIdentifier: pid) {
        app.activate(options: [])
    }
}

// MARK: - Window Cycling

func cycleWindows(forward: Bool) {
    // Local helpers to avoid any scope resolution issues.
    func axStringAttr(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let str = value as? String else { return nil }
        return str
    }

    func isCycleableWin(_ window: AXUIElement) -> Bool {
        guard let role = axStringAttr(window, kAXRoleAttribute as String),
              role == kAXWindowRole as String else { return false }

        if let subrole = axStringAttr(window, kAXSubroleAttribute as String) {
            let excluded: Set<String> = [
                "AXSheet",
                "AXDrawer",
                "AXDialog",
                "AXFloatingWindow",
                "AXSystemDialog",
            ]
            if excluded.contains(subrole) { return false }
        }

        var minimizedRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minimizedRef) == .success,
           let minimized = minimizedRef as? Bool, minimized {
            return false
        }

        return true
    }

    if cycleAllApplications {
        // Switch apps using MRU list without posting Cmd+Tab.
        if let pid = nextAppPID(forward: forward) {
            activateApp(pid: pid)
        }
        return
    } else {
        // Cycle only within the frontmost application's windows.
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return }
        let pid = frontApp.processIdentifier
        let appRef = AXUIElementCreateApplication(pid)

        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appRef, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let allWindows = windowsRef as? [AXUIElement]
        else { return }

        var windows = allWindows.filter { isCycleableWin($0) }
        if windows.count <= 1 {
            var childrenRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(appRef, kAXChildrenAttribute as CFString, &childrenRef) == .success,
               let children = childrenRef as? [AXUIElement] {
                let candidateWindows = children.filter {
                    axStringAttr($0, kAXRoleAttribute as String) == (kAXWindowRole as String)
                }
                let filtered = candidateWindows.filter { isCycleableWin($0) }
                if filtered.count > 1 {
                    windows = filtered
                }
            }
        }

        guard windows.count > 1 else { return }

        // Resolve the currently focused window, falling back to index 0 when focus is unresolvable.
        var focusedRef: CFTypeRef?
        let hasFocused = AXUIElementCopyAttributeValue(
            appRef, kAXFocusedWindowAttribute as CFString, &focusedRef
        ) == .success

        let currentIndex: Int
        if hasFocused, let focused = focusedRef {
            currentIndex = windows.firstIndex(where: { CFEqual($0, focused) }) ?? 0
        } else {
            currentIndex = 0
        }

        let nextIndex = forward
            ? (currentIndex + 1) % windows.count
            : (currentIndex - 1 + windows.count) % windows.count

        let target = windows[nextIndex]

        // Raise first so the window comes visually to front, then grant it focus.
        AXUIElementPerformAction(target, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(appRef, kAXFocusedWindowAttribute as CFString, target)

        // Fallback for Electron and other apps that ignore kAXFocusedWindowAttribute writes.
        AXUIElementPerformAction(target, kAXPressAction as CFString)
    }
}

// MARK: - Tab Cycling

/// Returns the keystroke to switch tabs for the given bundle ID,
/// derived directly from appRegistry — no duplication.
func tabKeystrokeForApp(bundleID: String, isVolumeUp: Bool) -> TabKeyStroke? {
    switch appRegistry[bundleID] {
    case .shiftBracket:
        return TabKeyStroke(
            keyCode: isVolumeUp ? 30 : 33,      // ] = 30, [ = 33
            flags: [.maskCommand, .maskShift]
        )
    case .optionArrow:
        return TabKeyStroke(
            keyCode: isVolumeUp ? 124 : 123,    // Right = 124, Left = 123
            flags: [.maskCommand, .maskAlternate]
        )
    case nil:
        return nil
    }
}

/// Returns the keystroke to open a new tab for the given bundle ID.
/// Defaults to Command+T, with exceptions for VSCode-like apps that use Command+N.
func newTabKeystrokeForApp(bundleID: String) -> TabKeyStroke? {
    // VSCode family uses Command+N to create a new untitled tab/file.
    let vscodeLike: Set<String> = [
        "com.microsoft.VSCode",
        "com.microsoft.VSCodeInsiders",
        "com.vscodium.codium",
        "com.todesktop.230313mzl4w4u92", // Cursor
        "com.exafunction.windsurf"       // Windsurf
    ]

    if vscodeLike.contains(bundleID) {
        return TabKeyStroke(
            keyCode: 45,                    // N
            flags: [.maskCommand]
        )
    } else {
        return TabKeyStroke(
            keyCode: 17,                    // T
            flags: [.maskCommand]
        )
    }
}

func postKeyStroke(_ keystroke: TabKeyStroke) {
    guard let source = CGEventSource(stateID: .hidSystemState),
          let down = CGEvent(keyboardEventSource: source,
                             virtualKey: keystroke.keyCode,
                             keyDown: true),
          let up   = CGEvent(keyboardEventSource: source,
                             virtualKey: keystroke.keyCode,
                             keyDown: false)
    else { return }

    down.flags = keystroke.flags
    up.flags   = keystroke.flags

    // Mark as synthetic so our tap passes these straight through.
    down.setIntegerValueField(.eventSourceUserData, value: kSyntheticEventMarker)
    up.setIntegerValueField(.eventSourceUserData,   value: kSyntheticEventMarker)

    // Post below our own tap so there's no chance of re-interception.
    down.post(tap: .cgAnnotatedSessionEventTap)
    up.post(tap: .cgAnnotatedSessionEventTap)
}

// MARK: - Event Tap Callback

func eventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {

    // macOS silently disables taps that take too long or are flagged by the user.
    // Re-enable immediately so we never silently stop working.
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
        return Unmanaged.passRetained(event)
    }

    guard type == systemDefinedEventType else {
        return Unmanaged.passRetained(event)
    }

    // Pass through any synthetic events we generated ourselves.
    if event.getIntegerValueField(.eventSourceUserData) == kSyntheticEventMarker {
        return Unmanaged.passRetained(event)
    }

    guard shortcutsEnabled else {
        return Unmanaged.passRetained(event)
    }

    // Bridge to NSEvent to correctly read NX media key data.
    // CGEvent's raw fields don't expose data1/data2 directly; NSEvent does.
    guard let nsEvent = NSEvent(cgEvent: event),
          nsEvent.type == .systemDefined
    else {
        return Unmanaged.passRetained(event)
    }

    // data1 layout: bits 31–16 = NX key code,
    //               bits 15–8  = key state (0xA = down, 0xB = up),
    //               bits 7–0   = repeat count.
    let keyCode  = Int64((nsEvent.data1 & 0xFFFF0000) >> 16)
    let keyFlags = Int64(nsEvent.data1 & 0x0000FFFF)
    let keyDown  = ((keyFlags & 0xFF00) >> 8) == 0xA

    // Pass key-up events through — consuming them can confuse system audio logic.
    guard keyDown else {
        return Unmanaged.passRetained(event)
    }

    guard keyCode == NX_KEYTYPE_SOUND_UP || keyCode == NX_KEYTYPE_SOUND_DOWN || keyCode == NX_KEYTYPE_MUTE else {
        return Unmanaged.passRetained(event)
    }
    
    if (keyCode == NX_KEYTYPE_MUTE) {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let bundleID = app.bundleIdentifier,
              supportedApps.contains(bundleID),
              let newTabKeyStroke = newTabKeystrokeForApp(bundleID: bundleID)
        else { return nil }
        postKeyStroke(newTabKeyStroke)
        return nil
    }

    let forward = keyCode == NX_KEYTYPE_SOUND_UP

    let globalFlags = CGEventSource.flagsState(.hidSystemState)

    // If Shift is held, let the system handle volume normally.
    if globalFlags.contains(.maskShift) {
        return Unmanaged.passRetained(event)
    }

    if globalFlags.contains(.maskCommand) {
        // Perform AX operations on the main thread to avoid tap timeouts and AX threading issues.
        DispatchQueue.main.async {
            cycleWindows(forward: forward)
        }
    } else {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let bundleID = app.bundleIdentifier,
              supportedApps.contains(bundleID),
              let stroke = tabKeystrokeForApp(bundleID: bundleID, isVolumeUp: forward)
        else { return nil }

        postKeyStroke(stroke)
    }

    // Consume the volume event so the system doesn't also change the volume.
    return nil
}

// MARK: - AppDelegate

class AppDelegate: NSObject, NSApplicationDelegate {

    var statusItem: NSStatusItem!
    var toggleMenuItem: NSMenuItem!
    var scopeMenuItem: NSMenuItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        requestAccessibility()
        // Load persisted preference (default remains true when unset)
        if UserDefaults.standard.object(forKey: kPrefCycleAllApplications) != nil {
            cycleAllApplications = UserDefaults.standard.bool(forKey: kPrefCycleAllApplications)
        }
        // Track app activation to maintain an MRU list
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(appDidActivate(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
        seedMRU()
        setupMenuBar()
        setupEventTap()
    }

    func requestAccessibility() {
        let options: NSDictionary = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
        ]
        AXIsProcessTrustedWithOptions(options)
    }

    func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        updateStatusIcon()

        let menu = NSMenu()

        let permissionItem = NSMenuItem(
            title: "Check Accessibility Permission",
            action: #selector(checkPermission),
            keyEquivalent: ""
        )
        permissionItem.target = self
        menu.addItem(permissionItem)

        toggleMenuItem = NSMenuItem(
            title: "Enable Shortcuts",
            action: #selector(toggleShortcuts),
            keyEquivalent: ""
        )
        toggleMenuItem.state = .on
        toggleMenuItem.target = self
        menu.addItem(toggleMenuItem)
        
        let scopeTitle = "Cycle Across All Apps"
        scopeMenuItem = NSMenuItem(
            title: scopeTitle,
            action: #selector(toggleCycleScope),
            keyEquivalent: ""
        )
        scopeMenuItem.state = cycleAllApplications ? .on : .off
        scopeMenuItem.target = self
        menu.addItem(scopeMenuItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    /// Updates the menu bar icon and opacity to reflect the current enabled state.
    func updateStatusIcon() {
        let symbolName = shortcutsEnabled
            ? "arrow.left.arrow.right"
            : "arrow.left.arrow.right"          // same icon, dimmed below
        statusItem.button?.image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: shortcutsEnabled ? "Tab Switcher (on)" : "Tab Switcher (off)"
        )
        statusItem.button?.alphaValue = shortcutsEnabled ? 1.0 : 0.4
    }

    @objc func checkPermission() {
        let trusted = AXIsProcessTrusted()
        let alert = NSAlert()
        alert.messageText = trusted
            ? "✅ Accessibility Granted"
            : "❌ Accessibility Not Granted"
        alert.informativeText = trusted
            ? "The app can intercept volume keys and control windows."
            : "Open System Settings → Privacy & Security → Accessibility and enable this app."
        alert.runModal()
    }

    @objc func toggleShortcuts(_ sender: NSMenuItem) {
        shortcutsEnabled.toggle()
        sender.state = shortcutsEnabled ? .on : .off
        updateStatusIcon()
    }
    
    @objc func appDidActivate(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        let pid = app.processIdentifier
        // Track only user-facing apps; include hidden or windowless as requested.
        guard app.activationPolicy == .regular else { return }
        appMRU.removeAll { $0 == pid }
        appMRU.insert(pid, at: 0)
    }
    
    @objc func toggleCycleScope(_ sender: NSMenuItem) {
        cycleAllApplications.toggle()
        sender.state = cycleAllApplications ? .on : .off
        UserDefaults.standard.set(cycleAllApplications, forKey: kPrefCycleAllApplications)
    }

    @objc func quit() {
        NSApplication.shared.terminate(nil)
    }

    func setupEventTap() {
        // Include the tap-disabled pseudo-events so the watchdog in the callback
        // can re-enable the tap if macOS disables it due to timeout.
        let mask: CGEventMask =
            (1 << systemDefinedEventType.rawValue) |
            (1 << CGEventType.tapDisabledByTimeout.rawValue) |
            (1 << CGEventType.tapDisabledByUserInput.rawValue)

        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: eventTapCallback,
            userInfo: nil
        )

        guard let tap = eventTap else {
            // Most likely cause: accessibility permission not yet granted.
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = "Could Not Install Event Tap"
                alert.informativeText = "Please grant Accessibility permission in System Settings → Privacy & Security → Accessibility, then relaunch."
                alert.runModal()
            }
            return
        }

        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }
}

// MARK: - Entry Point

let app      = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
