# OmniWM

A powerful tiling window manager for macOS.

<p align="center">
  <img src="https://img.shields.io/badge/macOS-26.0%2B-green?logo=apple&logoColor=white" alt="macOS">
  <img src="https://img.shields.io/badge/Apple%20Silicon-supported-green?logo=apple&logoColor=white" alt="Apple Silicon">
  <img src="https://img.shields.io/badge/X86/X64-supported-green?logo=intel&logoColor=white" alt="Intel">
  <img src="https://img.shields.io/badge/Claude%20Code-Assisted-green?logo=claude&logoColor=white" alt="Claude Code">
</p>

<p align="center">
  <img src="https://raw.githubusercontent.com/BarutSRB/OmniWM/main/assets/semidemo.gif" alt="OmniWM demo">
  <img src="https://raw.githubusercontent.com/BarutSRB/OmniWM/main/assets/semidemo1.gif" alt="OmniWM demo">
</p>

<p align="center">
  <img src="https://raw.githubusercontent.com/BarutSRB/OmniWM/main/assets/demo1.gif" alt="OmniWM demo" width="100%">
</p>
<p align="center">
  <img src="https://raw.githubusercontent.com/BarutSRB/OmniWM/main/assets/demo2.gif" alt="OmniWM demo" width="100%">
</p>
<p align="center">
  <img src="https://raw.githubusercontent.com/BarutSRB/OmniWM/main/assets/demo3.gif" alt="OmniWM demo" width="100%">
</p>
<p align="center">
  <img src="https://raw.githubusercontent.com/BarutSRB/OmniWM/main/assets/demo4.gif" alt="OmniWM demo" width="100%">
</p>
<p align="center">
  <img src="https://raw.githubusercontent.com/BarutSRB/OmniWM/main/assets/demo5.gif" alt="OmniWM demo" width="100%">
</p>

Small demo, not fully showing everything, gif recorded at 30fps due to size, features shown:
- real quake-style temrinal using ghostty framework
- window finder/jumper
- searchable and usable command pallet for any app
- App menu anywhere
- Niri tabs
- Niri and Dwindle layout (some animations shown)
- Hide/unhide status bar icons
- Interactive workspace bar
A lot more features not show in the gif.

## Known Limitations

- **Multi-monitor support** - Functional but not fully bug free.
- **Gestures/Trackpad** - Magic Mouse and trackpad gestures are untested (no hardware available for testing)

## Performance & Trust

OmniWM is built for high responsiveness and smooth, crisp animations.

- **Private APIs** - OmniWM leverages Apple private APIs where ever technically possible in order to reduce latency and improve window management responsiveness.
- **Refresh-rate-aware animations** - OmniWM targets true display refresh pacing (for example 60/120/144Hz) for animations.
- **No SIP disable required** - OmniWM does not require System Integrity Protection (SIP) to be disabled and never will.
- **Always notarized official releases** - Official OmniWM release builds are developer-signed and notarized by Apple and will stay that way.
- **Forever free, no limitations** - OmniWM is and will remain free to use forever, with no subscriptions, feature paywalls, trial limits, or usage caps.

## Requirements

- macOS 26+ (Tahoe)
- Accessibility permissions (prompted on launch)

## Installation

The app is developer signed and notarized by Apple.

### Homebrew

```bash
brew tap BarutSRB/tap
brew install omniwm
```

### GitHub Releases

1. Download the latest `OmniWM.zip` from [Releases](https://github.com/BarutSRB/OmniWM/releases)
2. Extract and move `OmniWM.app` to `/Applications`
3. Launch OmniWM and grant Accessibility permissions when prompted

## Quick Start

1. Launch OmniWM from your Applications folder
2. Grant Accessibility permissions in System Settings > Privacy & Security > Accessibility
3. Windows will automatically tile in columns
4. Use `Option + Arrow keys` to navigate between windows
5. Click the menu bar icon to access Settings


## User Guide

### Layout Modes

OmniWM offers two layout engines that you can switch between per-workspace:

**Niri (Scrolling Columns)** - Windows arranged in vertical columns that scroll horizontally. Each column can have multiple stacked windows or be "tabbed" (multiple windows, one visible at a time). Best for wide monitors with many windows.

**Dwindle (BSP)** - Binary space partition layout that recursively divides screen space. Each new window splits the space in half. Best for traditional tiling with predictable layouts.

Switch layouts per-workspace with `Option + Shift + L`.

### Keyboard Shortcuts

All shortcuts are customizable in Settings > Hotkeys.

#### Window Focus (Navigation)

| Action | Shortcut |
|--------|----------|
| Focus Left / Right / Up / Down | `Option + Arrow Keys` |
| Focus Previous Window | `Option + Tab` |
| Focus First in Column | `Option + Home` |
| Focus Last in Column | `Option + End` |

#### Moving Windows

| Action | Shortcut |
|--------|----------|
| Move Left / Right / Up / Down | `Option + Shift + Arrow Keys` |
| Swap Left / Right | `Option + Ctrl + H` / `L` |
| Move Column Left / Right | `Option + Ctrl + Shift + ← / →` |

#### Workspaces

| Action | Shortcut |
|--------|----------|
| Switch to Workspace 1-9 | `Option + 1-9` |
| Move Window to Workspace 1-9 | `Option + Shift + 1-9` |
| Toggle Back & Forth | `Option + Ctrl + Tab` |
| Summon Workspace to Current Monitor | `Ctrl + Shift + 1-9` |

#### Multi-Monitor

| Action | Shortcut |
|--------|----------|
| Focus Monitor in Direction | `Ctrl + Cmd + Arrow Keys` |
| Focus Next Monitor | `Ctrl + Cmd + Tab` |
| Move Window to Monitor | `Option + Ctrl + Arrow Keys` |

#### Layout Controls (Niri)

| Action | Shortcut |
|--------|----------|
| Cycle Column Width | `Option + .` / `Option + ,` |
| Toggle Full Width | `Option + Shift + F` |
| Balance Sizes | `Option + Shift + B` |
| Toggle Tabbed Column | `Option + T` |
| Consume Window into Column | `Option + Ctrl + [` / `]` |
| Expel Window from Column | `Option + Ctrl + Shift + [` / `]` |

#### Special Features

| Action | Shortcut |
|--------|----------|
| Toggle Fullscreen | `Option + Return` |
| Window Finder | `Ctrl + Option + Space` |
| Menu Anywhere | `Ctrl + Option + M` |
| Menu Palette (searchable) | `Ctrl + Option + Shift + M` |
| Quake Terminal | `` Option + ` `` |
| Overview | `Option + Shift + O` |

#### Quake Terminal (Inside Terminal)

| Action | Shortcut |
|--------|----------|
| New Tab | `Cmd + T` |
| Close Tab | `Cmd + W` |
| Next Tab | `Cmd + Shift + ]` |
| Previous Tab | `Cmd + Shift + [` |
| Next Tab (Alt) | `Ctrl + Tab` |
| Previous Tab (Alt) | `Ctrl + Shift + Tab` |
| Select Tab 1-9 | `Cmd + 1-9` |
| Split Pane (Horizontal) | `Cmd + D` |
| Split Pane (Vertical) | `Cmd + Shift + D` |
| Close Pane | `Cmd + Shift + W` |
| Equalize Splits | `Cmd + Shift + =` |
| Navigate Pane | `Cmd + Option + Arrow Keys` |

#### Hidden Bar

| Action | Shortcut |
|--------|----------|
| Toggle Hidden Bar (when enabled) | Right-click menu bar icon |
| Toggle Hidden Bar (Hotkey, unassigned by default) | Unassigned |

### Features

#### Quake Terminal

A drop-down terminal (powered by Ghostty) that slides in from the screen edge:
- Toggle with `` Option + ` ``
- Supports multiple tabs and splits within tabs
- Tab and pane shortcuts are listed in **Quake Terminal (Inside Terminal)**
- Mouse resize by dragging edges; `Option + drag` to move (remembers size/position per monitor)
- Configure position (top/bottom/left/right/center), size, and opacity in Settings
- Auto-hides on focus loss (optional)

#### Window Finder

Quickly search and jump to any window:
- Press `Ctrl + Option + Space`
- Type to fuzzy-search by window title or app name
- Use arrow keys to select, Enter to focus

#### Menu Anywhere

Access any application's menu from your keyboard:
- `Ctrl + Option + M` - Shows native menu at cursor
- `Ctrl + Option + Shift + M` - Searchable menu palette

#### Overview Mode

See all windows at once with thumbnails:
- Press `Option + Shift + O`
- Click a window to focus it
- Search to filter windows

#### Workspace Bar

A visual indicator showing your workspaces:
- Displays open apps per workspace
- Click to switch workspaces
- Configure position, height, and appearance in Settings

#### Hidden Bar

Hide or reveal status bar icons using a separator item:
- Enable in Settings
- Right-click the OmniWM menu bar icon to toggle
- Optional hotkey exists but is unassigned by default

### Tips

- **Workspaces** - Create named workspaces in Settings to organize by project or context
- **App Rules** - Exclude problematic apps from tiling or assign them to specific workspaces
- **Mouse** - `Option + drag` moves tiled windows; `Option + Shift + drag` inserts between windows (Niri)
- **Mouse Resize** - Hover window edges and drag to resize (Niri)
- **Scroll Gestures (Mouse)** - Hold `Option + Shift + Mouse Scroll Wheel` (default, configurable) and scroll through columns horizontally
- **Trackpad Gestures** - Use horizontal gestures with 2/3/4 fingers (configurable); direction can be inverted (not tested lacking hardware)

## Configuration

Access settings by clicking the **O** menu bar icon and selecting **Settings** or **App Rules**.
Mouse/gesture settings and Hidden Bar options are available in Settings.

## App Rules

Configure per-application behavior in Settings > App Rules:

- **Always Float** - Force specific apps to always float (e.g., calculators, preferences windows)
- **Assign to Workspace** - Automatically move app windows to a specific workspace
- **Minimum Size** - Prevent the layout engine from sizing windows below a threshold

## Building from Source

Requirements:
- SwiftPM with Swift 6.2+
- macOS 26.0+

## Support

If you find OmniWM useful, consider supporting development:

- [GitHub Sponsors](https://github.com/sponsors/BarutSRB)
- [PayPal](https://paypal.me/beacon2024)

## Contributing

Issues and pull requests are welcome on [GitHub](https://github.com/BarutSRB/OmniWM).
