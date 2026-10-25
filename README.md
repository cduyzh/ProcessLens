# ProcessLens

A native macOS process monitor and manager — an Activity Monitor–style tool built with SwiftUI and AppKit.

[![macOS](https://img.shields.io/badge/macOS-14.0%2B-000000?style=flat-square&logo=apple&logoColor=white)](https://github.com/cduyzh/ProcessLens/releases)
[![Swift](https://img.shields.io/badge/Swift-5.9%2B-F05138?style=flat-square&logo=swift&logoColor=white)](https://developer.apple.com/swift/)
[![License: MIT](https://img.shields.io/badge/License-MIT-green?style=flat-square)](LICENSE)
[![Author](https://img.shields.io/badge/Author-cduyzh-blue?style=flat-square)](https://github.com/cduyzh)

**English** · [简体中文](README.zh-CN.md)

ProcessLens shows what your Mac is actually doing: live CPU, memory, disk and network figures, a searchable process list, and compact detail panels. Every number comes from real sampling of the local system — nothing is estimated or simulated. It is a fully native app with zero third-party dependencies.

## Features

- **Resource overview** — CPU, memory, startup disk capacity, and physical network interface throughput, each with a real chart built from the last 40 samples.
- **Process list** — Sort by CPU, memory, name or PID; filter between app and background processes; search by name, PID, user, and executable path.
- **App processes** — Group and inspect processes that live inside a `.app` bundle, including helper processes, with counts showing how many processes belong to each app.
- **Watched processes** — Pin processes you care about by executable path; the watch list persists across app restarts so relaunched programs are found again.
- **Process detail** — User, parent process, thread count, uptime, state, and executable, with one-click copy and Reveal in Finder.
- **Listening ports** — On-demand view of TCP LISTEN and UDP bound endpoints, with search, sorting, copy, and jump-to-process.
- **Process actions** — Quit (SIGTERM) and force quit (SIGKILL), both behind a confirmation step; UID and microsecond-precision start time are re-verified immediately before acting, and system, self, parent, and other users' processes are protected.
- **CSV export** — Export the currently filtered process snapshot to CSV with a UTF-8 BOM and protection against spreadsheet formula injection.
- **Menu bar** — CPU, memory, and process count at a glance, plus a hover-expandable dark stats panel that reuses the main window's sampling loop.
- **Browser diagnostics** — Tells everyday browsers apart from automated Chromium and Electron instances by provable launch source, process tree, container directories, sanitized arguments, and RSS estimates; quits an instance gracefully with read-back verification, then optionally force-quits surviving renderers identified from the original snapshot.
- **Launch items manager** — Surfaces user and admin LaunchAgents and LaunchDaemons plus visible login and background items, with their launch conditions and actual enable state; qualifying user items can be disabled, backed up, and restored, while system-managed items link straight to the native macOS Settings.
- **Disk image cleanup** — Lists mounted DMG/ISO images with volume, mount point, and source file; multi-select eject, and only after a successful eject is the installer file moved to the Trash; installers still in use are kept.
- **Top monitor panel** — A floating panel with a monospace CPU readout in the status bar that expands into a live resource view.
- **Settings** — 1/2/5/10-second sampling interval, system/light/dark appearance, menu bar toggle, shortcuts reference, and the real running version and app path.
- **Version and history** — In-app version and release history, with an automatic consistency check between the root `Info.plist` and `Resources/ReleaseHistory.json`.

## Download and Install

Grab the latest DMG from the [Releases page](https://github.com/cduyzh/ProcessLens/releases):

1. Download the `.dmg` file for the latest version.
2. Open it and drag the app into the **Applications** folder.
3. Launch the app. On first run, macOS may ask you to confirm opening an app downloaded from the internet.

## Build from Source

Requires Xcode or Command Line Tools (Swift 5.9+) on macOS 14 or newer.

```bash
git clone https://github.com/cduyzh/ProcessLens.git
cd ProcessLens
./build_app.sh
```

The script builds the release binary and bundles the `.app`; it does not install anything automatically. See the in-repo scripts for local install and release packaging.

## Version History

- Current version: **0.3.0** (build 3, 2026-10-24)

See [CHANGELOG.md](CHANGELOG.md) for the full history.

## Privacy

All data — processes, ports, network counters, mounted images, and launch items — is read locally through standard system APIs. Nothing is uploaded, and no analytics or telemetry exist. CSV exports are written only when you explicitly ask for one. Nothing ever leaves your Mac.

## License

Released under the [MIT License](LICENSE).

## Author

**cduyzh**

- GitHub: <https://github.com/cduyzh>
- Website: <https://www.cduyzh.top>
- Goal: <https://www.cduyzh.top/goal>
