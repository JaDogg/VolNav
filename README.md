# VolNav

VolNav is a macOS menu-bar utility that repurposes the hardware volume and mute keys as keyboard navigation shortcuts — tab switching, window cycling, and app switching — without touching the mouse.

It runs as a background accessibility process (no Dock icon) and requires Accessibility permission to intercept media keys.

## What it does

| Key combo | Action |
|---|---|
| Vol Up / Vol Down | Next / Previous tab (in supported apps) |
| Mute | New tab |
| Opt + Mute | Close tab (Cmd+W) |
| Cmd + Vol Up/Down | Cycle windows or apps (configurable) |
| Shift + Vol Up/Down | Real volume **or** Page Up / Page Down (configurable) |
| Shift + Mute | System mute **or** left mouse click at cursor (when scroll mode is on) |

All other apps and key combinations pass through untouched.

## Supported apps

Tab switching works out of the box for browsers (Safari, Chrome, Firefox, Arc, Brave, Edge, Zen, Vivaldi, Opera), terminals (Terminal, iTerm2, Ghostty, Warp, Kitty, Hyper), editors (Xcode, VSCode, Cursor, Windsurf, Sublime Text, Nova, Obsidian), and all major JetBrains IDEs.

You can add any other app from the menu bar: right-click the icon with the target app in the foreground and choose **Add App as ⌘⇧]/⌘⇧[ Tabs** or **Add App as ⌘⌥→/⌘⌥← Tabs**.

## Options (menu bar)

- **Enable Shortcuts** — global on/off toggle
- **Launch at Login** — registers with macOS login items
- **Cmd+Vol Mode** — choose between cycling across apps (MRU order), cycling all windows across all apps (flat), or cycling windows of the current app only
- **Current Monitor Only** — restrict app/window cycling to the screen the mouse is on
- **Shift+Vol Mode** — choose between real volume or Page Up/Down; includes **Reverse Scroll Direction** to flip which key scrolls which way
- **Ignore App** — disable all VolNav shortcuts for the frontmost app
- **Exclude App from App Cycling** — keep an app out of Cmd+Vol cycling without fully ignoring it

## Build

Requires macOS 13+ and Xcode command-line tools.

```bash
./build.sh          # produces VolumeNavigator.app in the repo root
```

Or for a quick compile check:

```bash
swiftc main.swift -framework Cocoa -framework Carbon -framework ApplicationServices -o /tmp/VolNavTest
```

## Permissions

On first launch macOS will prompt for Accessibility access. Grant it in **System Settings → Privacy & Security → Accessibility**, then relaunch the app. Without this permission the CGEvent tap cannot be created and no keys will be intercepted.
