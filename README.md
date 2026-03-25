# OmniWM

A powerful tiling window manager for macOS.

## Demo Video

[![Watch the demo](https://img.youtube.com/vi/WcHjGkuD2Fc/maxresdefault.jpg)](https://youtu.be/WcHjGkuD2Fc)

## Contributors

<p align="center">
  Thank you to everyone who contributed to OmniWM. Your ideas and code made a real difference.
</p>

<table align="center">
  <tr>
    <td align="center">
      <a href="https://github.com/balazshevesi" title="Balazs Hevesi">
        <img src="https://github.com/balazshevesi.png?size=96" width="96" alt="Balazs Hevesi">
      </a>
      <br>
      <a href="https://github.com/balazshevesi"><strong>Balazs Hevesi</strong></a>
    </td>
    <td align="center">
      <a href="https://github.com/janhesters" title="Jan Hesters">
        <img src="https://github.com/janhesters.png?size=96" width="96" alt="Jan Hesters">
      </a>
      <br>
      <a href="https://github.com/janhesters"><strong>Jan Hesters</strong></a>
    </td>
    <td align="center">
      <a href="https://github.com/jcardama" title="Jose Cardama">
        <img src="https://github.com/jcardama.png?size=96" width="96" alt="Jose Cardama">
      </a>
      <br>
      <a href="https://github.com/jcardama"><strong>Jose Cardama</strong></a>
    </td>
    <td align="center">
      <a href="https://github.com/lgerlinski" title="Lukas Gerlinski">
        <img src="https://github.com/lgerlinski.png?size=96" width="96" alt="Lukas Gerlinski">
      </a>
      <br>
      <a href="https://github.com/lgerlinski"><strong>Lukas Gerlinski</strong></a>
    </td>
    <td align="center">
      <a href="https://github.com/zucram" title="Marcus Harlid Davin">
        <img src="https://github.com/zucram.png?size=96" width="96" alt="Marcus Harlid Davin">
      </a>
      <br>
      <a href="https://github.com/zucram"><strong>Marcus Harlid Davin</strong></a>
    </td>
    <td align="center">
      <a href="https://github.com/chenhaozhenss" title="Williamufo">
        <img src="https://github.com/chenhaozhenss.png?size=96" width="96" alt="Williamufo">
      </a>
      <br>
      <a href="https://github.com/chenhaozhenss"><strong>Williamufo</strong></a>
    </td>
    <td align="center">
      <a href="https://github.com/Yang-Yiming" title="Yang-Yiming">
        <img src="https://github.com/Yang-Yiming.png?size=96" width="96" alt="Yang-Yiming">
      </a>
      <br>
      <a href="https://github.com/Yang-Yiming"><strong>Yang-Yiming</strong></a>
    </td>
  </tr>
</table>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-15.0%2B-green?logo=apple&logoColor=white" alt="macOS">
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
- unified command palette for windows and app menus
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

- macOS 15+ (Sequoia)
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
3. In System Settings > Desktop & Dock > Mission Control, turn off `Displays have separate Spaces`
4. Log out of macOS and log back in for that change to take effect
5. Launch OmniWM and grant Accessibility permissions when prompted

## Quick Start

1. Launch OmniWM from your Applications folder
2. In System Settings > Desktop & Dock > Mission Control, turn off `Displays have separate Spaces`
3. Log out of macOS and log back in for that change to take effect
4. Grant Accessibility permissions in System Settings > Privacy & Security > Accessibility
5. Windows will automatically tile in columns
6. Use `Option + Arrow keys` to navigate between windows
7. Click the menu bar icon to access Settings


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
| Move Column Left / Right | `Option + Ctrl + Shift + ← / →` |

#### Workspaces

| Action | Shortcut |
|--------|----------|
| Switch to Workspace 1-9 | `Option + 1-9` |
| Move Window to Workspace 1-9 | `Option + Shift + 1-9` |
| Toggle Back & Forth | `Option + Ctrl + Tab` |

#### Multi-Monitor

| Action | Shortcut |
|--------|----------|
| Focus Next Monitor | `Ctrl + Cmd + Tab` |

#### Layout Controls (Niri)

| Action | Shortcut |
|--------|----------|
| Cycle Column Width | `Option + .` / `Option + ,` |
| Toggle Full Width | `Option + Shift + F` |
| Balance Sizes | `Option + Shift + B` |
| Toggle Tabbed Column | `Option + T` |

In Niri, `Move Left / Right` expels the focused window out of multi-window columns or consumes a single-window column into the adjacent column. `Move Up / Down` keeps the current in-column reorder behavior.

#### Special Features

| Action | Shortcut |
|--------|----------|
| Toggle Fullscreen | `Option + Return` |
| Toggle Command Palette | `Ctrl + Option + Space` |
| Menu Anywhere | `Ctrl + Option + M` |
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
| Toggle Hidden Bar | Right-click menu bar icon |
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

#### Command Palette

Quickly search windows or app menus from one shared palette:
- Press `Ctrl + Option + Space` to toggle
- Switch between `Windows` and `Menu`
- Type to fuzzy-search by window title, app name, or menu item
- Menu results always show keyboard shortcuts when available
- Use arrow keys to select, Enter to act

#### Menu Anywhere

Access any application's menu from your keyboard:
- `Ctrl + Option + M` - Shows native menu at cursor

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
- Right-click the OmniWM menu bar icon to toggle
- Optional hotkey exists but is unassigned by default

#### Recovery

If OmniWM's owned menu-bar items come up in a bad order, clear their saved positions and expand the hidden bar:

```bash
defaults write com.barut.OmniWM settings.hiddenBar.isCollapsed -bool false
defaults delete com.barut.OmniWM "NSStatusItem Preferred Position omniwm_main"
defaults delete com.barut.OmniWM "NSStatusItem Preferred Position omniwm_hiddenbar_separator"
killall OmniWM
```

### Tips

- **Workspaces** - Create named workspaces in Settings to organize by project or context
- **App Rules** - Exclude problematic apps from tiling or assign them to specific workspaces
- **Mouse** - `Option + drag` moves tiled windows; `Option + Shift + drag` inserts between windows (Niri)
- **Mouse Resize** - Hover window edges and drag to resize (Niri)
- **Scroll Gestures (Mouse)** - Hold `Option + Shift + Mouse Scroll Wheel` (default, configurable) and scroll through columns horizontally
- **Trackpad Gestures** - Use horizontal gestures with 2/3/4 fingers (configurable); direction can be inverted (not tested lacking hardware)

## Configuration

Access settings by clicking the **O** menu bar icon and selecting **Settings** or **App Rules**.
Mouse and gesture settings are available in Settings.

OmniWM stores its editable config at `~/.config/omniwm/settings.json`.

- **Editable Config** writes the full canonical settings file, including hotkeys and monitor overrides, so it can be edited directly.
- **Compact Backup** writes only values that differ from defaults. Import still merges that backup back into the full canonical settings model.
- **Reveal Settings File** and **Open Settings File** create `settings.json` on first use if it does not exist yet.

## App Rules

Configure per-application behavior in Settings > App Rules:

- **Always Float** - Force specific apps to always float (e.g., calculators, preferences windows)
- **Assign to Workspace** - Automatically move app windows to a specific workspace
- **Minimum Size** - Prevent the layout engine from sizing windows below a threshold

## Building from Source

Requirements:
- SwiftPM with Swift 6.2+
- macOS 15.0+

## Support

If you find OmniWM useful, consider supporting development:

- [GitHub Sponsors](https://github.com/sponsors/BarutSRB)
- [PayPal](https://paypal.me/beacon2024)

## Contributing

Issues and pull requests are welcome on [GitHub](https://github.com/BarutSRB/OmniWM).
