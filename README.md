# OmniWM

A powerful tiling window manager for macOS.

![macOS](https://img.shields.io/badge/macOS-26.0%2B-blue)

[![Watch the video](https://img.youtube.com/vi/gYfne_aqXnQ/maxresdefault.jpg)](https://www.youtube.com/watch?v=gYfne_aqXnQ&list=PLOvpT5mq6q2vz5uw2o5V4vR2Aln0Ef569)

## Features

- **Column-based tiling** - Niri-inspired layout engine that automatically arranges windows in columns
- **Multiple workspaces** - Create and manage virtual workspaces with per-monitor assignment
- **40+ keyboard shortcuts** - Navigate, move, and resize windows efficiently (all customizable)
- **App rules** - Configure per-application behavior (floating, workspace assignment, minimum size)
- **Window borders** - Visual indicator for the focused window
- **Fuzzy finder** - Press `Option + Space` to search through all windows and navigate directly to them
- **Window tabs** - Group multiple windows into tabbed containers for better organization
- **Workspace bar** - Menu bar widget with sorted app icons; click any icon to navigate to that window
- **Focus follows mouse** - Optionally focus windows when hovering over them

## Known Limitations

- **Multi-monitor support** - Not fully tested (developer lacks multi-monitor setup)
- **Gestures/Trackpad** - Magic Mouse and trackpad gestures are untested (no hardware available for testing)

## Requirements

- macOS 26.0 (Sequoia) or later
- Accessibility permissions (prompted on first launch)

## Installation

The app is developer signed and notarized by Apple.

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


## Configuration

Access settings by clicking the **O** menu bar icon and selecting **Settings**.

### General
- **Inner gaps** - Spacing between windows
- **Outer margins** - Margins around the screen edges

### Layout (Niri)
- **Windows per column** - Maximum windows stacked in each column
- **Visible columns** - Number of columns visible at once
- **Center focused column** - Behavior for centering the active column
- **Single window aspect ratio** - Constraint for single windows (16:9, 4:3, etc.)

### Workspaces
- Create and name workspaces
- Assign workspaces to specific monitors
- Choose layout algorithm per workspace

### Borders
- Enable/disable window borders
- Customize border color and width

### Bar
- Show/hide workspace bar
- Configure position and appearance
- Per-monitor settings

### Hotkeys
- Customize all keyboard shortcuts
- Visual key recording interface

## App Rules

Configure per-application behavior in Settings > App Rules:

- **Always Float** - Force specific apps to always float (e.g., calculators, preferences windows)
- **Assign to Workspace** - Automatically move app windows to a specific workspace
- **Minimum Size** - Prevent the layout engine from sizing windows below a threshold

## Building from Source

Requirements:
- Xcode with Swift 6.2+
- macOS 26.0+

## Support

If you find OmniWM useful, consider supporting development:

- [GitHub Sponsors](https://github.com/sponsors/BarutSRB)
- [PayPal](https://paypal.me/beacon2024)

## Contributing

Issues and pull requests are welcome on [GitHub](https://github.com/BarutSRB/OmniWM).


