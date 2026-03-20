# VolNav — CLAUDE.md

## Project Overview

VolNav is a single-file macOS menu-bar utility that intercepts hardware volume/mute keys and repurposes them as tab-switching, window-cycling, and app-switching shortcuts. It runs as an accessibility process (no Dock icon) and requires Accessibility permission.

## File Structure

```
VolNav/
├── main.swift          # Entire application — one file, ~1270 lines
├── build.sh            # Builds VolumeNavigator.app bundle (see Build section)
├── AppIcon.icns        # Pre-built app icon (copied by build.sh)
├── icon.svg            # Source icon (used by build.sh if ImageMagick present)
└── VolumeNavigator.app # Built app bundle (not committed)
```

## Architecture

Everything lives in `main.swift`. There is no Xcode project, no SPM manifest, and no storyboard. The file is structured with `// MARK:` sections:

| Section | Lines (approx) | Purpose |
|---|---|---|
| App Registry | 1–100 | `appRegistry` dict mapping bundle IDs → `TabShortcut` enum |
| Global State | 101–165 | All global `var`/`let` flags and constants |
| Cycle HUD | 163–322 | `CycleHUD` class — floating NSPanel for visual feedback |
| App Switching (MRU) | 323–380 | `seedMRU`, `appHasWindowOnScreen`, `nextAppPID` |
| Window Cycling | 380–590 | `cycleWindows`, `cycleWindowsFlat`, helpers |
| Tab Cycling | 590–655 | `tabKeystrokeForApp`, `newTabKeystrokeForApp`, `postKeyStroke` |
| Event Tap Callback | 655–775 | `eventTapCallback` — core key interception logic |
| AppDelegate | 775–1220 | Menu bar setup, preference loading, action handlers |
| NSMenuDelegate | 1220–1270 | `menuWillOpen` — dynamic menu item titles/states |
| Entry Point | 1270 | `NSApplication.shared.run()` |

## Key Types & Variables

### Global flags (all persisted to UserDefaults)

| Variable | Key | Default | Meaning |
|---|---|---|---|
| `cycleAllApplications` | `CycleAllApplicationsEnabled` | `true` | Cmd+Vol cycles apps via MRU |
| `cycleFlatAllWindows` | `CycleFlatAllWindows` | `false` | Cmd+Vol cycles all windows across all apps |
| `cycleCurrentMonitorOnly` | `CycleCurrentMonitorOnly` | `false` | Filter by mouse screen |
| `shiftVolScrollMode` | `ShiftVolScrollMode` | `false` | Shift+Vol sends Page Up/Down instead of real volume |
| `shortcutsEnabled` | — | `true` | Global on/off toggle |

Three-way Cmd+Vol mode encoding:

| `cycleAllApplications` | `cycleFlatAllWindows` | Behaviour |
|---|---|---|
| `true` | `false` | MRU app cycling (default) |
| `false` | `true` | Flat cross-app window cycling |
| `false` | `false` | Current-app window cycling |

### Key collections

- `appMRU: [pid_t]` — most-recently-used app list, updated by `NSWorkspace.didActivateApplicationNotification`
- `appRegistry: [String: TabShortcut]` — built-in bundle ID → tab shortcut map
- `userTabRegistry: [String: TabShortcut]` — user-added entries, persisted
- `windowNavExcludedIDs: Set<String>` — apps excluded from Cmd+Vol cycling
- `ignoredBundleIDs: Set<String>` — apps where all VolNav shortcuts are disabled

## Key Functions

### Event routing

- **`eventTapCallback`** — CGEvent tap handler; reads NX key codes and modifier flags, dispatches to tab/window/mute logic
- **`postKeyStroke(_:)`** — synthesises a CGEvent keystroke marked with `kSyntheticEventMarker` so the tap ignores it

### Tab switching

- **`tabKeystrokeForApp(bundleID:isVolumeUp:)`** — returns the correct `TabKeyStroke` for the frontmost app (Cmd+Shift+]/[ or Cmd+Opt+→/←)
- **`newTabKeystrokeForApp(bundleID:)`** — returns Cmd+T (or Cmd+N for VSCode-like apps)

### Window / app cycling

- **`cycleWindows(forward:)`** — dispatcher; calls `cycleWindowsFlat` or handles MRU app / current-app paths inline
- **`cycleWindowsFlat(forward:)`** — flat cross-app window cycling; builds a `[FlatWin]` list across all MRU apps and steps through it
- **`nextAppPID(forward:)`** — returns the next/prev pid from `appMRU`, respecting exclusions and monitor filter
- **`axStringAttr(_:_:)`** — thin wrapper around `AXUIElementCopyAttributeValue` for string attributes
- **`isCycleableWin(_:)`** — returns `true` if a window should appear in cycling lists (not a sheet/drawer/minimized)

### HUD

- **`CycleHUD.shared.showApps(pids:selectedPID:excludedIDs:)`** — horizontal icon grid (app cycling)
- **`CycleHUD.shared.showWindows(titles:selectedIndex:)`** — vertical text list (window cycling); used for both single-app and flat-window modes

### AppDelegate actions

| Selector | Trigger | Effect |
|---|---|---|
| `setCycleMode(_:)` | "Cmd+Vol Mode" submenu | Sets `cycleAllApplications` / `cycleFlatAllWindows` |
| `setShiftVolMode(_:)` | "Shift+Vol Mode" submenu | Sets `shiftVolScrollMode` |
| `toggleCurrentMonitor(_:)` | "Current Monitor Only" | Toggles `cycleCurrentMonitorOnly` |
| `toggleShortcuts(_:)` | "Enable Shortcuts" | Toggles `shortcutsEnabled` |
| `toggleIgnoreApp(_:)` | "Ignore App" | Adds/removes frontmost app from `ignoredBundleIDs` |
| `toggleWindowNavExclusion(_:)` | "Exclude App from App Cycling" | Adds/removes from `windowNavExcludedIDs` |
| `addAppAsShiftBracket` / `addAppAsOptionArrow` | menu items | Adds frontmost app to `userTabRegistry` |

## Build

```bash
./build.sh          # produces VolumeNavigator.app in the repo root
```

Or for a quick compile check:

```bash
swiftc main.swift -o /tmp/VolNavTest
```

`build.sh` compiles with `-framework Cocoa -framework Carbon -framework ApplicationServices`, creates the app bundle, writes `Info.plist`, copies the icon, and ad-hoc codesigns.

## Adding a New App for Tab Switching

Add one line to `appRegistry` in `main.swift`:

```swift
"com.example.MyApp": .shiftBracket,   // or .optionArrow
```

No other changes needed — `supportedApps` is derived automatically.

## Permissions

The app requests Accessibility access at launch via `AXIsProcessTrustedWithOptions`. Without it the CGEvent tap cannot be created and the app shows an alert. Grant access in System Settings → Privacy & Security → Accessibility.
