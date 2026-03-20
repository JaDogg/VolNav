import Cocoa
import ApplicationServices
import ServiceManagement

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
    "md.obsidian":                          .shiftBracket,  // Obsidian

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
var supportedApps: Set<String> = Set(appRegistry.keys)

/// User-added apps (persisted in UserDefaults). Merged with appRegistry at runtime.
var userTabRegistry: [String: TabShortcut] = [:]
let kPrefUserTabShiftBracket = "UserTabAppsShiftBracket"
let kPrefUserTabOptionArrow  = "UserTabAppsOptionArrow"

/// Apps excluded from Cmd+Vol app cycling (persisted in UserDefaults).
var windowNavExcludedIDs: Set<String> = []
let kPrefWindowNavExcluded = "WindowNavExcludedApps"

func rebuildSupportedApps() {
    supportedApps = Set(appRegistry.keys).union(userTabRegistry.keys)
}

let NX_KEYTYPE_SOUND_UP:   Int64 = 0
let NX_KEYTYPE_SOUND_DOWN: Int64 = 1
let NX_KEYTYPE_MUTE:       Int64 = 7

/// Sentinel stamped on synthetic key events so our tap never re-intercepts them.
let kSyntheticEventMarker: Int64 = 0xDEADBEEF

/// How long the app-switch HUD stays on screen.
let kHUDDisplayDuration: TimeInterval = 1.5

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

var cycleCurrentMonitorOnly = false
let kPrefCycleCurrentMonitorOnly = "CycleCurrentMonitorOnly"

var shiftVolScrollMode = false
let kPrefShiftVolScrollMode = "ShiftVolScrollMode"

/// Returns the screen that contains the current mouse pointer.
func mouseScreen() -> NSScreen {
    let pt = NSEvent.mouseLocation
    return NSScreen.screens.first { NSMouseInRect(pt, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
}

/// Returns the screen that a given AX window's top-left origin falls on.
func screenForWindow(_ window: AXUIElement) -> NSScreen? {
    var posRef: CFTypeRef?
    var sizeRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &posRef) == .success,
          AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef) == .success,
          let posVal = posRef, let sizeVal = sizeRef else { return nil }
    var rawPos = CGPoint.zero
    var rawSize = CGSize.zero
    AXValueGetValue(posVal as! AXValue, .cgPoint, &rawPos)
    AXValueGetValue(sizeVal as! AXValue, .cgSize, &rawSize)
    // AX coordinates have origin at top-left of primary screen; flip to AppKit coords.
    let primaryH = NSScreen.screens.first?.frame.height ?? 0
    let winCenter = CGPoint(x: rawPos.x + rawSize.width / 2,
                            y: primaryH - rawPos.y - rawSize.height / 2)
    return NSScreen.screens.first { NSPointInRect(winCenter, $0.frame) }
}

var ignoredBundleIDs: Set<String> = []
let kPrefIgnoredApps = "IgnoredApps"

// MRU list of regular apps (most recent first)
var appMRU: [pid_t] = []

// MARK: - Cycle HUD

/// Displays the full app list (app cycling) or window list (window cycling)
/// with the next target highlighted.
class CycleHUD {
    static let shared = CycleHUD()
    private var panel: NSPanel!
    private var hideTask: DispatchWorkItem?

    private let kItemW: CGFloat = 80    // width of each app cell
    private let kItemH: CGFloat = 76    // icon(48) + label(16) + padding
    private let kPad:   CGFloat = 12    // panel edge padding
    private let kRowH:  CGFloat = 30    // height of each window row
    private let kListW: CGFloat = 420   // width of window list panel

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
            styleMask: [.hudWindow, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
    }

    /// Horizontal app grid. Pass the full unfiltered MRU list so excluded
    /// apps are visible (dimmed) but not navigated to.
    func showApps(pids: [pid_t], selectedPID: pid_t, excludedIDs: Set<String>) {
        typealias Entry = (app: NSRunningApplication, excluded: Bool)
        let entries: [Entry] = pids.compactMap {
            guard let a = NSRunningApplication(processIdentifier: $0) else { return nil }
            let excl = a.bundleIdentifier.map { excludedIDs.contains($0) } ?? false
            return (a, excl)
        }
        guard !entries.isEmpty else { return }

        let screenW  = mouseScreen().frame.width
        let maxW     = screenW - 40
        // Shrink items if needed, but not below 54 px
        let itemW    = min(kItemW, max(54, floor((maxW - kPad * 2) / CGFloat(entries.count))))
        let panelW   = min(itemW * CGFloat(entries.count) + kPad * 2, maxW)
        let panelH   = kItemH + kPad * 2
        let iconSize: CGFloat = min(48, itemW - 8)

        let cv = NSView(frame: NSRect(x: 0, y: 0, width: panelW, height: panelH))

        for (i, entry) in entries.enumerated() {
            let x          = kPad + CGFloat(i) * itemW
            let isSelected = entry.app.processIdentifier == selectedPID

            if isSelected {
                let bg = NSBox(frame: NSRect(x: x + 2, y: kPad + 2,
                                            width: itemW - 4, height: kItemH - 4))
                bg.boxType      = .custom
                bg.cornerRadius = 8
                bg.fillColor    = NSColor(white: 1.0, alpha: 0.25)
                bg.borderColor  = .clear
                cv.addSubview(bg)
            }

            let iconView = NSImageView(frame: NSRect(
                x: x + (itemW - iconSize) / 2,
                y: kPad + 20,
                width: iconSize, height: iconSize
            ))
            iconView.image        = entry.app.icon
            iconView.imageScaling = .scaleProportionallyDown
            iconView.alphaValue   = entry.excluded ? 0.3 : 1.0
            cv.addSubview(iconView)

            let lbl = NSTextField(frame: NSRect(x: x + 2, y: kPad + 3,
                                               width: itemW - 4, height: 15))
            lbl.isBezeled = false; lbl.drawsBackground = false
            lbl.isEditable = false; lbl.isSelectable = false
            lbl.alignment  = .center
            lbl.font       = NSFont.systemFont(ofSize: min(9, itemW / 8),
                                               weight: isSelected ? .semibold : .regular)
            lbl.textColor  = entry.excluded ? NSColor(white: 1, alpha: 0.35) : .white
            lbl.stringValue = entry.app.localizedName ?? ""
            lbl.cell?.truncatesLastVisibleLine = true
            lbl.cell?.lineBreakMode = .byTruncatingTail
            cv.addSubview(lbl)
        }

        present(view: cv, size: NSSize(width: panelW, height: panelH))
    }

    /// Vertical window list. All windows shown; selected row highlighted.
    func showWindows(titles: [String], selectedIndex: Int) {
        let screenH = mouseScreen().frame.height
        let rawH    = CGFloat(titles.count) * kRowH + kPad * 2
        let panelH  = min(rawH, screenH * 0.6)
        let panelW  = kListW

        // If the list is taller than the panel, scroll so the selected row is centred.
        let visibleRows = Int(floor((panelH - kPad * 2) / kRowH))
        let scrollStart = max(0, min(selectedIndex - visibleRows / 2,
                                     titles.count - visibleRows))

        let cv = NSView(frame: NSRect(x: 0, y: 0, width: panelW, height: panelH))

        for (i, title) in titles.enumerated() {
            let visRow = i - scrollStart
            guard visRow >= 0 && visRow < visibleRows else { continue }

            let y          = panelH - kPad - CGFloat(visRow + 1) * kRowH
            let isSelected = i == selectedIndex

            if isSelected {
                let bg = NSBox(frame: NSRect(x: kPad, y: y,
                                            width: panelW - kPad * 2, height: kRowH - 2))
                bg.boxType      = .custom
                bg.cornerRadius = 6
                bg.fillColor    = NSColor(white: 1.0, alpha: 0.25)
                bg.borderColor  = .clear
                cv.addSubview(bg)
            }

            let lbl = NSTextField(frame: NSRect(x: kPad + 8, y: y + 6,
                                               width: panelW - kPad * 2 - 16, height: kRowH - 12))
            lbl.isBezeled = false; lbl.drawsBackground = false
            lbl.isEditable = false; lbl.isSelectable = false
            lbl.font      = NSFont.systemFont(ofSize: 13,
                                              weight: isSelected ? .semibold : .regular)
            lbl.textColor = .white
            lbl.stringValue = title.isEmpty ? "(Untitled)" : title
            lbl.cell?.truncatesLastVisibleLine = true
            lbl.cell?.lineBreakMode = .byTruncatingMiddle
            cv.addSubview(lbl)
        }

        present(view: cv, size: NSSize(width: panelW, height: panelH))
    }

    private func present(view: NSView, size: NSSize) {
        panel.contentView?.subviews.forEach { $0.removeFromSuperview() }
        panel.setContentSize(size)
        view.frame = NSRect(origin: .zero, size: size)
        panel.contentView?.addSubview(view)
        let screen = mouseScreen()
        panel.setFrameOrigin(NSPoint(
            x: screen.frame.minX + (screen.frame.width  - size.width)  / 2,
            y: screen.frame.minY + (screen.frame.height - size.height) / 2
        ))
        panel.orderFrontRegardless()
        scheduleHide()
    }

    private func scheduleHide() {
        hideTask?.cancel()
        let task = DispatchWorkItem { [weak self] in self?.panel.orderOut(nil) }
        hideTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + kHUDDisplayDuration, execute: task)
    }
}

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

/// Returns true if the app has at least one visible (non-minimized) window on `screen`.
func appHasWindowOnScreen(_ pid: pid_t, screen: NSScreen) -> Bool {
    let appRef = AXUIElementCreateApplication(pid)
    var windowsRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(appRef, kAXWindowsAttribute as CFString, &windowsRef) == .success,
          let windows = windowsRef as? [AXUIElement] else { return false }
    return windows.contains { win in
        var minRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(win, kAXMinimizedAttribute as CFString, &minRef) == .success,
           let minimized = minRef as? Bool, minimized { return false }
        return screenForWindow(win) == screen
    }
}

func nextAppPID(forward: Bool) -> pid_t? {
    let targetScreen = cycleCurrentMonitorOnly ? mouseScreen() : nil
    // Filter out excluded apps on the fly so the MRU list stays intact.
    let mru = appMRU.filter { pid in
        guard let app = NSRunningApplication(processIdentifier: pid),
              let bid = app.bundleIdentifier else { return true }
        if windowNavExcludedIDs.contains(bid) { return false }
        if let screen = targetScreen { return appHasWindowOnScreen(pid, screen: screen) }
        return true
    }
    guard !mru.isEmpty else { return nil }
    if let front = NSWorkspace.shared.frontmostApplication,
       front.activationPolicy == .regular {
        let currentPID = front.processIdentifier
        if let idx = mru.firstIndex(of: currentPID) {
            return forward
                ? mru[(idx + 1) % mru.count]
                : mru[(idx - 1 + mru.count) % mru.count]
        }
    }
    return mru.first
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

    let targetScreen: NSScreen? = cycleCurrentMonitorOnly ? mouseScreen() : nil

    if cycleAllApplications {
        // Switch apps using MRU list without posting Cmd+Tab.
        if let pid = nextAppPID(forward: forward),
           let app = NSRunningApplication(processIdentifier: pid) {
            app.activate(options: [])
            // When filtering by monitor, show only apps on that screen (excluded ones dimmed).
            // Otherwise show the full unfiltered list so excluded apps are visible (dimmed).
            let hudPIDs: [pid_t]
            if let screen = targetScreen {
                hudPIDs = appMRU.filter { appHasWindowOnScreen($0, screen: screen) }
            } else {
                hudPIDs = appMRU
            }
            CycleHUD.shared.showApps(pids: hudPIDs, selectedPID: pid,
                                     excludedIDs: windowNavExcludedIDs)
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

        // When filtering by monitor, only cycle windows on the mouse screen.
        if let screen = targetScreen {
            windows = windows.filter { screenForWindow($0) == screen }
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

        // Show the full window list with the target highlighted.
        let titles = windows.map { axStringAttr($0, kAXTitleAttribute as String) ?? "" }
        CycleHUD.shared.showWindows(titles: titles, selectedIndex: nextIndex)
    }
}

// MARK: - Tab Cycling

/// Returns the keystroke to switch tabs for the given bundle ID,
/// checking appRegistry first then userTabRegistry.
func tabKeystrokeForApp(bundleID: String, isVolumeUp: Bool) -> TabKeyStroke? {
    switch appRegistry[bundleID] ?? userTabRegistry[bundleID] {
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

    // Read modifier flags and frontmost app once — reused by all branches below.
    let globalFlags = CGEventSource.flagsState(.hidSystemState)
    let frontBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""

    // Pass through events for apps that the user has chosen to ignore.
    if !frontBundleID.isEmpty && ignoredBundleIDs.contains(frontBundleID) {
        return Unmanaged.passRetained(event)
    }

    if keyCode == NX_KEYTYPE_MUTE {
        // Shift+Mute → toggle scroll mode (Shift+Vol emits Page Up/Down).
        if globalFlags.contains(.maskShift) {
            shiftVolScrollMode.toggle()
            UserDefaults.standard.set(shiftVolScrollMode, forKey: kPrefShiftVolScrollMode)
            DispatchQueue.main.async {
                (NSApp.delegate as? AppDelegate)?.updateScrollModeMenuItem()
            }
            return nil
        }
        guard !frontBundleID.isEmpty, supportedApps.contains(frontBundleID) else { return nil }

        if globalFlags.contains(.maskAlternate) {
            // Option+Mute → Close Tab (Cmd+W)
            postKeyStroke(TabKeyStroke(keyCode: 13, flags: [.maskCommand]))
        } else {
            guard let newTabKeyStroke = newTabKeystrokeForApp(bundleID: frontBundleID) else { return nil }
            postKeyStroke(newTabKeyStroke)
        }
        return nil
    }

    let forward = keyCode == NX_KEYTYPE_SOUND_UP

    // If Shift is held: scroll mode → Page Up/Down; otherwise real volume.
    if globalFlags.contains(.maskShift) {
        if shiftVolScrollMode {
            // Page Up = 116, Page Down = 121
            let keyCode: CGKeyCode = forward ? 116 : 121
            postKeyStroke(TabKeyStroke(keyCode: keyCode, flags: []))
            return nil
        }
        return Unmanaged.passRetained(event)
    }

    if globalFlags.contains(.maskCommand) {
        // Perform AX operations on the main thread to avoid tap timeouts and AX threading issues.
        DispatchQueue.main.async {
            cycleWindows(forward: forward)
        }
    } else {
        guard !frontBundleID.isEmpty,
              supportedApps.contains(frontBundleID),
              let stroke = tabKeystrokeForApp(bundleID: frontBundleID, isVolumeUp: forward)
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
    var launchAtLoginMenuItem: NSMenuItem!
    var appStatusMenuItem: NSMenuItem!
    var ignoreAppMenuItem: NSMenuItem!
    var addTabShiftMenuItem: NSMenuItem!
    var addTabOptionMenuItem: NSMenuItem!
    var removeTabMenuItem: NSMenuItem!
    var windowNavExcludeMenuItem: NSMenuItem!
    var currentMonitorMenuItem: NSMenuItem!
    var scrollModeMenuItem: NSMenuItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        requestAccessibility()
        // Load persisted preferences
        if UserDefaults.standard.object(forKey: kPrefCycleAllApplications) != nil {
            cycleAllApplications = UserDefaults.standard.bool(forKey: kPrefCycleAllApplications)
        }
        if UserDefaults.standard.object(forKey: kPrefCycleCurrentMonitorOnly) != nil {
            cycleCurrentMonitorOnly = UserDefaults.standard.bool(forKey: kPrefCycleCurrentMonitorOnly)
        }
        if UserDefaults.standard.object(forKey: kPrefShiftVolScrollMode) != nil {
            shiftVolScrollMode = UserDefaults.standard.bool(forKey: kPrefShiftVolScrollMode)
        }
        if let saved = UserDefaults.standard.array(forKey: kPrefIgnoredApps) as? [String] {
            ignoredBundleIDs = Set(saved)
        }
        if let shift = UserDefaults.standard.array(forKey: kPrefUserTabShiftBracket) as? [String] {
            shift.forEach { userTabRegistry[$0] = .shiftBracket }
        }
        if let option = UserDefaults.standard.array(forKey: kPrefUserTabOptionArrow) as? [String] {
            option.forEach { userTabRegistry[$0] = .optionArrow }
        }
        rebuildSupportedApps()
        if let excl = UserDefaults.standard.array(forKey: kPrefWindowNavExcluded) as? [String] {
            windowNavExcludedIDs = Set(excl)
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
        menu.delegate = self

        // ── Key Bindings section ──────────────────────────────────────────
        menu.addItem(makeSectionHeader("Key Bindings"))
        menu.addItem(makeBindingRow("Vol ↑↓", "Next / Prev Tab"))
        menu.addItem(makeBindingRow("Mute", "New Tab"))
        menu.addItem(makeBindingRow("Opt+Mute", "Close Tab"))
        menu.addItem(makeBindingRow("Shift+Vol", "Real Volume / Page Up·Down"))
        menu.addItem(makeBindingRow("Shift+Mute", "Toggle Scroll Mode"))
        menu.addItem(makeBindingRow("Cmd+Vol", "Cycle Apps"))

        menu.addItem(.separator())

        // ── Options section ───────────────────────────────────────────────
        menu.addItem(makeSectionHeader("Options"))

        toggleMenuItem = NSMenuItem(
            title: "Enable Shortcuts",
            action: #selector(toggleShortcuts),
            keyEquivalent: ""
        )
        toggleMenuItem.state = .on
        toggleMenuItem.target = self
        menu.addItem(toggleMenuItem)

        launchAtLoginMenuItem = NSMenuItem(
            title: "Launch at Login",
            action: #selector(toggleLaunchAtLogin),
            keyEquivalent: ""
        )
        launchAtLoginMenuItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        launchAtLoginMenuItem.target = self
        menu.addItem(launchAtLoginMenuItem)

        scopeMenuItem = NSMenuItem(
            title: "Cycle Across All Apps",
            action: #selector(toggleCycleScope),
            keyEquivalent: ""
        )
        scopeMenuItem.state = cycleAllApplications ? .on : .off
        scopeMenuItem.target = self
        menu.addItem(scopeMenuItem)

        currentMonitorMenuItem = NSMenuItem(
            title: "Current Monitor Only",
            action: #selector(toggleCurrentMonitor),
            keyEquivalent: ""
        )
        currentMonitorMenuItem.state = cycleCurrentMonitorOnly ? .on : .off
        currentMonitorMenuItem.target = self
        menu.addItem(currentMonitorMenuItem)

        scrollModeMenuItem = NSMenuItem(
            title: "Shift+Vol → Page Up/Down",
            action: #selector(toggleScrollMode),
            keyEquivalent: ""
        )
        scrollModeMenuItem.state = shiftVolScrollMode ? .on : .off
        scrollModeMenuItem.target = self
        menu.addItem(scrollModeMenuItem)

        menu.addItem(.separator())

        // ── Current app context ───────────────────────────────────────────
        appStatusMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        appStatusMenuItem.isEnabled = false
        menu.addItem(appStatusMenuItem)

        ignoreAppMenuItem = NSMenuItem(
            title: "Ignore App",
            action: #selector(toggleIgnoreApp),
            keyEquivalent: ""
        )
        ignoreAppMenuItem.target = self
        menu.addItem(ignoreAppMenuItem)

        addTabShiftMenuItem = NSMenuItem(
            title: "Add App as ⌘⇧] / ⌘⇧[ Tabs",
            action: #selector(addAppAsShiftBracket),
            keyEquivalent: ""
        )
        addTabShiftMenuItem.target = self
        menu.addItem(addTabShiftMenuItem)

        addTabOptionMenuItem = NSMenuItem(
            title: "Add App as ⌘⌥→ / ⌘⌥← Tabs",
            action: #selector(addAppAsOptionArrow),
            keyEquivalent: ""
        )
        addTabOptionMenuItem.target = self
        menu.addItem(addTabOptionMenuItem)

        removeTabMenuItem = NSMenuItem(
            title: "Remove App from Tab Navigation",
            action: #selector(removeAppFromTabNav),
            keyEquivalent: ""
        )
        removeTabMenuItem.target = self
        menu.addItem(removeTabMenuItem)

        windowNavExcludeMenuItem = NSMenuItem(
            title: "Exclude App from App Cycling",
            action: #selector(toggleWindowNavExclusion),
            keyEquivalent: ""
        )
        windowNavExcludeMenuItem.target = self
        menu.addItem(windowNavExcludeMenuItem)

        menu.addItem(.separator())

        // ── Info & permissions ────────────────────────────────────────────
        let countItem = NSMenuItem(
            title: "Supported Apps: \(appRegistry.count)",
            action: nil,
            keyEquivalent: ""
        )
        countItem.isEnabled = false
        menu.addItem(countItem)

        let permissionItem = NSMenuItem(
            title: "Open Accessibility Settings",
            action: #selector(openAccessibilitySettings),
            keyEquivalent: ""
        )
        permissionItem.target = self
        menu.addItem(permissionItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    // Returns a disabled bold section header menu item.
    private func makeSectionHeader(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        item.attributedTitle = NSAttributedString(string: title, attributes: attrs)
        item.isEnabled = false
        return item
    }

    // Returns a human-readable shortcut label for the given bundle ID.
    private func tabShortcutLabel(for bundleID: String) -> String {
        switch appRegistry[bundleID] ?? userTabRegistry[bundleID] {
        case .shiftBracket: return "⌘⇧] / ⌘⇧["
        case .optionArrow:  return "⌘⌥→ / ⌘⌥←"
        case nil:           return "not supported"
        }
    }

    // Returns a disabled row showing a key binding description.
    private func makeBindingRow(_ key: String, _ action: String) -> NSMenuItem {
        let item = NSMenuItem(title: "  \(key)  →  \(action)", action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    /// Updates the menu bar icon, opacity, and tooltip to reflect the current enabled state.
    func updateStatusIcon() {
        statusItem.button?.image = NSImage(
            systemSymbolName: "arrow.left.arrow.right",
            accessibilityDescription: shortcutsEnabled ? "VolNav (on)" : "VolNav (off)"
        )
        statusItem.button?.alphaValue = shortcutsEnabled ? 1.0 : 0.4
        statusItem.button?.toolTip = shortcutsEnabled
            ? "VolNav: volume keys → tab navigation"
            : "VolNav: shortcuts disabled"
    }

    @objc func openAccessibilitySettings() {
        NSWorkspace.shared.open(
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        )
    }

    @objc func toggleShortcuts(_ sender: NSMenuItem) {
        shortcutsEnabled.toggle()
        sender.state = shortcutsEnabled ? .on : .off
        updateStatusIcon()
    }

    @objc func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        let svc = SMAppService.mainApp
        do {
            if svc.status == .enabled {
                try svc.unregister()
                sender.state = .off
            } else {
                try svc.register()
                sender.state = .on
            }
        } catch {
            // Silent — most likely a permissions issue.
        }
    }

    @objc func toggleCycleScope(_ sender: NSMenuItem) {
        cycleAllApplications.toggle()
        sender.state = cycleAllApplications ? .on : .off
        UserDefaults.standard.set(cycleAllApplications, forKey: kPrefCycleAllApplications)
    }

    @objc func toggleCurrentMonitor(_ sender: NSMenuItem) {
        cycleCurrentMonitorOnly.toggle()
        sender.state = cycleCurrentMonitorOnly ? .on : .off
        UserDefaults.standard.set(cycleCurrentMonitorOnly, forKey: kPrefCycleCurrentMonitorOnly)
    }

    @objc func toggleScrollMode(_ sender: NSMenuItem) {
        shiftVolScrollMode.toggle()
        sender.state = shiftVolScrollMode ? .on : .off
        UserDefaults.standard.set(shiftVolScrollMode, forKey: kPrefShiftVolScrollMode)
    }

    func updateScrollModeMenuItem() {
        scrollModeMenuItem?.state = shiftVolScrollMode ? .on : .off
    }

    @objc func toggleIgnoreApp(_ sender: NSMenuItem) {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let bundleID = app.bundleIdentifier else { return }
        if ignoredBundleIDs.contains(bundleID) {
            ignoredBundleIDs.remove(bundleID)
        } else {
            ignoredBundleIDs.insert(bundleID)
        }
        UserDefaults.standard.set(Array(ignoredBundleIDs), forKey: kPrefIgnoredApps)
    }

    @objc func appDidActivate(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        let pid = app.processIdentifier
        // Track only user-facing apps; include hidden or windowless as requested.
        guard app.activationPolicy == .regular else { return }
        appMRU.removeAll { $0 == pid }
        appMRU.insert(pid, at: 0)
    }

    private func saveUserTabRegistry() {
        let shift  = userTabRegistry.filter { $0.value == .shiftBracket }.map(\.key)
        let option = userTabRegistry.filter { $0.value == .optionArrow  }.map(\.key)
        UserDefaults.standard.set(shift,  forKey: kPrefUserTabShiftBracket)
        UserDefaults.standard.set(option, forKey: kPrefUserTabOptionArrow)
    }

    @objc func addAppAsShiftBracket() {
        guard let bid = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
              appRegistry[bid] == nil else { return }
        userTabRegistry[bid] = .shiftBracket
        rebuildSupportedApps()
        saveUserTabRegistry()
    }

    @objc func addAppAsOptionArrow() {
        guard let bid = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
              appRegistry[bid] == nil else { return }
        userTabRegistry[bid] = .optionArrow
        rebuildSupportedApps()
        saveUserTabRegistry()
    }

    @objc func removeAppFromTabNav() {
        guard let bid = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
              userTabRegistry[bid] != nil else { return }
        userTabRegistry.removeValue(forKey: bid)
        rebuildSupportedApps()
        saveUserTabRegistry()
    }

    @objc func toggleWindowNavExclusion(_ sender: NSMenuItem) {
        guard let bid = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else { return }
        if windowNavExcludedIDs.contains(bid) {
            windowNavExcludedIDs.remove(bid)
        } else {
            windowNavExcludedIDs.insert(bid)
        }
        UserDefaults.standard.set(Array(windowNavExcludedIDs), forKey: kPrefWindowNavExcluded)
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
                alert.messageText = "Accessibility Permission Required"
                alert.informativeText = "VolNav needs Accessibility access to intercept volume keys. Grant permission, then relaunch."
                alert.addButton(withTitle: "Open Settings")
                alert.addButton(withTitle: "Later")
                if alert.runModal() == .alertFirstButtonReturn {
                    NSWorkspace.shared.open(
                        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
                    )
                }
            }
            return
        }

        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }
}

// MARK: - NSMenuDelegate

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        let app = NSWorkspace.shared.frontmostApplication
        let appName = app?.localizedName ?? "App"
        let bundleID = app?.bundleIdentifier ?? ""

        // Current app status row
        let shortcutLabel = tabShortcutLabel(for: bundleID)
        appStatusMenuItem.title = bundleID.isEmpty
            ? "  No active app"
            : "  \(appName)  ·  \(shortcutLabel)"

        // Ignore / re-enable toggle
        let isIgnored = ignoredBundleIDs.contains(bundleID)
        ignoreAppMenuItem.title = isIgnored
            ? "Re-enable for \(appName)"
            : "Ignore \(appName)"
        ignoreAppMenuItem.isEnabled = !bundleID.isEmpty

        // Tab navigation add/remove items
        let isBuiltIn    = !bundleID.isEmpty && appRegistry[bundleID] != nil
        let isUserAdded  = !bundleID.isEmpty && userTabRegistry[bundleID] != nil
        addTabShiftMenuItem.title   = "Add \(appName) as ⌘⇧] / ⌘⇧[ Tabs"
        addTabOptionMenuItem.title  = "Add \(appName) as ⌘⌥→ / ⌘⌥← Tabs"
        removeTabMenuItem.title     = "Remove \(appName) from Tab Navigation"
        addTabShiftMenuItem.isHidden  = bundleID.isEmpty || isBuiltIn || isUserAdded
        addTabOptionMenuItem.isHidden = bundleID.isEmpty || isBuiltIn || isUserAdded
        removeTabMenuItem.isHidden    = !isUserAdded

        // Window nav exclusion
        let isExcluded = windowNavExcludedIDs.contains(bundleID)
        windowNavExcludeMenuItem.title = isExcluded
            ? "Include \(appName) in App Cycling"
            : "Exclude \(appName) from App Cycling"
        windowNavExcludeMenuItem.isEnabled = !bundleID.isEmpty
    }
}

// MARK: - Entry Point

let app      = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
