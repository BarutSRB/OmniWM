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

- **Multi-monitor support** - Not fully tested (developer lacks multi-monitor setup)
- **Gestures/Trackpad** - Magic Mouse and trackpad gestures are untested (no hardware available for testing)

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


## Configuration

Access settings by clicking the **O** menu bar icon and selecting **Settings** or **App Rules**.

There are huge amount of features and customizations and I'm really bad at doing guides but the GUI settings/customization should be fairly intuitive, some features have never before been available for macOS tiling WMs.
If anyone is good at making video guides DM me on discord or through GitHub discussions I'd appreciate it.

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


