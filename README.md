<p align="center">
  <img src="docs/images/icon.png" width="96" alt="MacBeat icon">
</p>

<h1 align="center">MacBeat</h1>
<p align="center"><strong>Close the lid. Keep things moving.</strong><br>A lightweight, native macOS menu bar app that keeps your Mac awake.</p>
<p align="center">
  <a href="https://github.com/xvshiting/macbeat/releases"><img src="https://img.shields.io/github/v/release/xvshiting/macbeat?include_prereleases&label=release" alt="GitHub Release"></a>
  <img src="https://img.shields.io/badge/macOS-13%2B-111111?logo=apple" alt="macOS 13+ build target">
  <img src="https://img.shields.io/badge/download-Apple%20silicon-2877ef" alt="Apple silicon download">
  <img src="https://img.shields.io/badge/Swift-native-f05138?logo=swift&logoColor=white" alt="Native Swift">
</p>
<p align="center"><strong>English</strong> · <a href="README.zh-CN.md">简体中文</a></p>
<p align="center">
  <a href="https://xvshiting.github.io/macbeat/"><strong>Website</strong></a> ·
  <a href="https://github.com/xvshiting/macbeat/releases/tag/v0.2.0"><strong>Download DMG</strong></a> ·
  <a href="#getting-started">Getting started</a> ·
  <a href="#compatibility-and-real-world-testing">Compatibility</a> ·
  <a href="#build-from-source">Build from source</a>
</p>

Keep downloads, computations, and local services running while you step away. Start a session, choose when it ends, and enable closed-lid operation when you need it. MacBeat lives in the menu bar; closing its panel does not stop your session.

**Your Mac stays awake. Its display can still turn off.** MacBeat does not currently offer an always-on display mode. The native app's current interface is in Simplified Chinese; this README and the website are available in English and Chinese.

## Features

| Feature | What it does |
| --- | --- |
| Keep awake with the lid open | Prevents automatic idle sleep |
| Optional closed-lid operation | Requests continued operation when you close your MacBook |
| Duration | A 24-hour dial, exact hour/minute entry, and one-minute adjustment |
| Exact end time | Choose a local date and time, including the next day |
| Manual stop | Continue until you stop the session or a protection condition is reached |
| Adjust an active session | Changes take effect only after you apply the updated end time |
| Battery and thermal protection | Optional AC-only operation, low-battery threshold, and stopping under elevated thermal pressure |
| Daily schedule | Multiple same-day windows on a 24-hour dial, with drag editing and overlap merging |
| Recovery controls | Detect MacBeat sessions and recovery records; explicitly request shared-state release |
| Launch at login | Starts in standby, or checks the current window if you enabled a daily schedule |

The menu bar icon uses a white heartbeat on a colored background: **blue** for standby, **green** for an active session, and **amber** when attention is needed. It stays visible on light and dark menu bars.

<p align="center"><img src="docs/images/menu-bar-icons.png" width="600" alt="Blue standby, green active, and amber attention icons on light and dark backgrounds; labels in Chinese"></p>

## Download and install

This branch contains the upcoming 0.3.0 interface and scheduling changes described above. The published download below is still 0.2.0; build from source to try the new features.

1. Download `MacBeat-0.2.0-arm64.dmg` from [Releases](https://github.com/xvshiting/macbeat/releases/tag/v0.2.0).
2. Open the DMG and **drag MacBeat.app into Applications**.
3. Open MacBeat from Applications. Find its heartbeat icon in the menu bar; it has no Dock icon.

The published binary is for **Apple silicon (arm64)**. The minimum build target is macOS 13; closed-lid behavior has not been tested on every supported OS version. See the test scope below.

### First-launch security prompt

This release is **ad-hoc signed, without a Developer ID distribution signature or Apple notarization**. macOS may block the first launch after downloading it. A prompt-free installation is not guaranteed.

Confirm that the file came from this repository's Release and verify its checksum. If you choose to allow the app, follow Apple's [instructions for opening a Mac app from an unknown developer](https://support.apple.com/guide/mac-help/mh40616/mac) to handle the prompt for this app in System Settings. You can also review the source and build it yourself. There is no need to disable system-wide security checks.

Download the `.sha256` file from the same release, then run this in your download directory:

```sh
shasum -a 256 -c MacBeat-0.2.0-arm64.dmg.sha256
```

To update, stop your session and quit the old version before replacing the app. Start a new session after reopening it.

## Getting started

1. Click MacBeat in the menu bar.
2. Open settings (设置). Choose whether to allow battery operation and whether to keep running with the lid closed (合盖时保持运行). **AC-only operation is enabled by default**; turn this restriction off to use battery power.
3. Choose a duration (按时长), an exact end time (到时间), or manual stop (手动停止). Click the blue start button (开启保持运行).
4. The icon turns green and the panel reports an active session. You can close the panel.
5. When the timer ends or you stop the session, MacBeat releases its requests and returns control to the system's sleep policy. It does not force your Mac to sleep immediately.

### Daily automatic start and stop

Open the **Daily plan** (每日计划) tab. Drag a blank arc to add a window; drag its endpoints to resize it or its middle to move it. Click a window to enter precise start and end times. Overlapping windows show a merge preview before changing the plan. Each window can be disabled or deleted independently. Click **Save daily plan** (保存每日计划) to apply the draft.

Times stay within **00:00–24:00**. For overnight work, use two windows, such as 22:00–24:00 and 00:00–02:00. Existing single-window settings are migrated automatically, including overnight settings. The plan is disabled by default.

- MacBeat must be running. Enable **Launch at login** if you want the schedule available after signing in. This feature does not wake a sleeping Mac or power on a shut-down Mac.
- Saving a schedule, launching the app, or waking during an unhandled window starts a session until that window's original end. A fully missed window is skipped.
- Each window is attempted once. Manual stop, startup failure, low battery, or thermal protection does not cause repeated starts in the same window, including after relaunch. You can still start a manual session yourself.
- An existing manual session takes priority: the scheduled window is skipped and does not change or stop it. Automatic stop applies to the session started by the schedule.
- Stop an active session before editing the schedule. Draft changes take effect only when saved. Disabling the schedule cancels future automatic starts.
- Times follow the Mac's local calendar. Missing daylight-saving times use the next valid time; repeated times use the first occurrence. An already-started session retains its original absolute end time.

### Two operating modes

| Closed-lid setting | Idle with lid open | Lid closed | After waking and reopening |
| --- | --- | --- | --- |
| Enabled | Keeps the system awake | Requests continued operation | Continues the session; reports an interruption if the system actually slept |
| Disabled | Prevents idle sleep | May sleep according to system policy | Resumes idle-sleep prevention if time and operating conditions still allow it |

A black display does not mean the computer is asleep. Check task progress, continuous observations, or system sleep logs to confirm continued operation.

## Compatibility and real-world testing

**One physical closed-lid test has been completed:** on October 5, 2026, an Apple silicon MacBook Pro running macOS 27.0 (26A428), on battery power, kept running with the lid closed for approximately **8 minutes 8 seconds**. An independent observer continued recording every second, detected **0 seconds of sleep**, and system logs showed no sleep event during that interval.

This verifies that particular machine and configuration. **Other Macs, OS versions, external-display configurations, and power transitions have not all been verified.** No prebuilt Intel binary is currently published.

Closed-lid control uses a private IOKit interface; system updates may change its behavior. Avoid running other closed-lid utilities at the same time. Run a short physical test on first use, after macOS updates, or after changing connected devices. Keep your Mac on a well-ventilated desk while it runs.

### Run your own closed-lid test

Start a closed-lid session in MacBeat, then run the independent observer from a source checkout (Python 3 required):

```sh
python3 scripts/observe-lid.py --seconds 300 --output /tmp/macbeat-lid-test.jsonl
```

Close the lid for two minutes, then reopen it. The observer does not acquire any keep-awake assertions or change power settings. Its log includes:

- `lidClosed`: whether the lid was closed.
- `gap`: interval since the previous record; normally about one second.
- `sleepSeconds`: estimated cumulative sleep, calculated from the difference between macOS continuous and uptime clocks.

Look for a confirmed closed lid, uninterrupted observations, and no increase in sleep time. A successful API call or an active-session label alone does not prove continued operation. Choose an output path that does not already exist to avoid overwriting earlier observations.

## Implementation and recovery

The interface uses **SwiftUI and AppKit**. A separate `MacBeatAgent` owns IOKit idle-sleep assertions and invokes the closed-lid interface when enabled. There are no third-party Swift package dependencies, telemetry, accounts, or required network services.

MacBeat **does not run `pmset disablesleep` or write persistent power settings**, and it does not automatically install a privileged daemon. Test scripts only use `pmset -g` to read state.

Sessions end on their deadline, manual stop, a lost client connection, low battery, elevated thermal pressure, or a violation of the selected power policy. A separate recovery process and a local journal help restore state if the control process exits unexpectedly. Recovery failures appear in the interface and are retried.

The **Keep-awake status** view distinguishes a MacBeat control session or recovery record from the system's aggregate closed-lid policy. Opening this view only inspects state. **End leftover session** asks an identified MacBeat agent to stop and then processes its recovery record. **Release shared keep-awake** requires an explicit confirmation because the state may be shared with other utilities. It does not alter the global sleep-disabled preference or guarantee that all other sleep blockers disappear.

The private closed-lid interface changes shared system state rather than a strictly process-owned resource. Recovery cannot be guaranteed when multiple utilities control that state, or when both recovery-related processes are forcibly killed. Reopen MacBeat if it reports a recovery issue. See [IMPLEMENTATION.txt](IMPLEMENTATION.txt) for details (in Chinese).

## Build from source

Requires macOS, Swift 5.9 or later, and Xcode Command Line Tools. The published release was built with Swift 6.4.

```sh
git clone https://github.com/xvshiting/macbeat.git
cd macbeat
bash scripts/build.sh
open dist/MacBeat.app
```

Create a drag-to-install DMG:

```sh
bash scripts/package-dmg.sh
```

The DMG and SHA-256 file are written to `dist/`. Packaging uses a separate staging directory so it does not overwrite a running development app. Builds use the host architecture by default; the script does not perform Apple notarization.

### Tests

```sh
conda run -n kora swift test
```

There are 51 policy, scheduling, controller, and recovery-store tests, including legacy migration, multiple daily windows, midnight handoff, overlap merging, arc movement, daylight-saving transitions, stop suppression, lock ownership, and token-matched cooperative stop requests.

The following integration checks briefly acquire real power assertions. Stop any MacBeat session and keep the lid open before running them:

```sh
python3 scripts/verify-agent.py
# Also checks requesting and restoring closed-lid control; not a physical lid test:
python3 scripts/verify-agent.py --clamshell
```

Maintainers using the local Conda `kora` environment can prefix test commands with `conda run -n kora`. GitHub Actions compiles, runs unit tests, and packages a DMG without changing closed-lid state on hosted runners.

### Project layout

```text
Sources/MacBeat/          Menu bar, interface, and session controller
Sources/MacBeatAgent/     Power assertions and recovery
Sources/MacBeatCore/      Scheduling, stop policies, and IPC data
Tests/                   Policy and controller-state tests
Resources/               App metadata
scripts/                 Build, packaging, and observation tools
website/                 English and Chinese product website
prototype/               Early UI explorations, not the shipped app
```

### Product website

The [product website](https://xvshiting.github.io/macbeat/) is a static site in `website/`, with English at `/` and Chinese at `/zh.html`. The [Pages workflow](.github/workflows/pages.yml) deploys changes to that directory from `main` to GitHub Pages. To preview locally:

```sh
python3 -m http.server 5181 --directory website
# Open http://localhost:5181
```

## Report an issue

Please [open an issue](https://github.com/xvshiting/macbeat/issues) with your macOS version, chip, power source, external-display setup, closed-lid setting, and whether the display turned off or the actual task stopped. Remove personal information before sharing logs.
