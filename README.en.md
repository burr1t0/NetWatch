<p align="center"><img src="docs/icon.png" width="128" alt="NetWatch"></p>

<h1 align="center">NetWatch</h1>

<p align="center">
  <b>Where your internet breaks: Wi-Fi, provider, DNS or VPN.</b><br>
  Home network diagnostics for macOS: a background agent, a desktop widget and a notification when something goes wrong.
</p>

<p align="center">
  <a href="README.md">Русский</a> · English
</p>

<p align="center">
  <img alt="macOS 15+" src="https://img.shields.io/badge/macOS-15%2B-black?logo=apple&logoColor=white">
  <img alt="Swift" src="https://img.shields.io/badge/Swift-SwiftUI%20%2B%20WidgetKit-F05138?logo=swift&logoColor=white">
  <img alt="License" src="https://img.shields.io/badge/license-MIT-blue">
</p>

<p align="center"><img src="docs/widget-incident-large.gif" width="408" alt="Large widget: a problem appears and clears"></p>

---

## What it is

The internet "sometimes slows down", and it is unclear whose fault it is: the router, the provider or your own VPN. Every 30 seconds
NetWatch checks each part of the path separately, records the results and tells you **where exactly** it breaks. A one-second glitch
is not a problem, while repeated ones are merged into incidents with a likely cause.

All measurements (except HTTPS) are bound to the physical interface (`en0`), so a VPN cannot distort them. HTTPS goes
over the default route and shows what apps actually experience.

| Part | What it does |
|---|---|
| <img src="docs/icons/status.svg" width="22" height="22" align="absmiddle"> **Diagnosis** | Wi-Fi/router, provider, DNS and VPN are told apart; short glitches are not counted |
| <img src="docs/icons/widget.svg" width="22" height="22" align="absmiddle"> **Widget** | Medium and large: a colored status, a graph with an hour · day · week switch, a click opens the app |
| <img src="docs/icons/notifications.svg" width="22" height="22" align="absmiddle"> **Notifications** | About a problem that lasts longer than a minute, with the likely cause |
| <img src="docs/icons/causes.svg" width="22" height="22" align="absmiddle"> **Causes of spikes** | This Mac's own traffic, AWDL (AirDrop and Handoff), power saving, CPU load, other devices |
| <img src="docs/icons/networks.svg" width="22" height="22" align="absmiddle"> **Networks** | Home, campus and a phone hotspot are counted separately; networks that drop ping are recognized automatically |
| <img src="docs/icons/router.svg" width="22" height="22" align="absmiddle"> **Tenda router** | Traffic through the router, number of devices, how long the provider connection has held; read without a password, nothing is written |

Frugal: one measurement every 30 s, faster only while there is a problem, slower on battery. License: [MIT](LICENSE).

---

## How it works

1. **The agent** (`netwatchd`, launchd) measures in the background: router, two internet addresses, DNS, TCP, HTTPS.
2. **Diagnosis** decides by rules what is wrong with the network and merges glitches into incidents. The log and 15-minute summaries stay on your Mac.
3. **The widget and the app** read the log: they draw the status and the graph, and send a notification when a problem lasts.

---

## What it looks like

The animations are drawn in code from synthetic data (`scripts/make-gifs.sh`), so they contain nothing about a real network.

### <img src="docs/icons/widget.svg" width="24" height="24" align="absmiddle"> Graph period

The buttons in the widget header work right on the desktop.

<p align="center"><img src="docs/widget-periods.gif" width="408" alt="Switching the graph period: hour, day, week"></p>

### <img src="docs/icons/status.svg" width="24" height="24" align="absmiddle"> What a problem looks like

The connection turns unstable (yellow), then nothing gets through the router (red),
then everything recovers. The strip under the graph shows the state minute by minute.

<p align="center"><img src="docs/widget-incident-medium.gif" width="408" alt="Medium widget: a problem appears and clears"></p>

The large widget (shown at the top) adds Wi-Fi, router data and a list of incidents.

---

## Requirements

- macOS 15 or later.
- Xcode and [xcodegen](https://github.com/yonaskolb/XcodeGen) to build the app and the widget.
- An Apple Development certificate (a free Apple ID is enough).

## Structure

- `Sources/NetWatchCore` — the core: measurements, diagnosis, incidents, networks, storage, the adaptive scheduler, the report.
- `Sources/NetWatchUI` — the widget views, shared by the widget and the app window.
- `Sources/netwatchd` — the command-line agent.
- `App/` and `Widget/` — the host app (settings window, notifications) and the widget extension.
- `Tests/` — tests for the diagnosis logic, networks, notifications, the router and storage.
- `scripts/` — installing the agent and the app, redrawing the animations.

## Usage

```bash
swift build -c release
.build/release/netwatchd run          # background collection (30 s, every 3 s during problems, slower on battery)
.build/release/netwatchd once         # one measurement
.build/release/netwatchd report --hours 24 [--network NAME]   # report, one per network
.build/release/netwatchd networks     # networks this Mac has been on
.build/release/netwatchd name current "Campus A"   # name the current network
.build/release/netwatchd router       # what the router reports right now (Tenda)
```

Log: `~/Library/Application Support/NetWatch/samples-YYYY-MM-DD.jsonl` (kept for 30 days).

## <img src="docs/icons/widget.svg" width="30" height="30" align="absmiddle"> Widget

A medium and a large widget for the macOS widget panel: a colored status, four key numbers, a latency graph
with a state strip, and the large one also shows Wi-Fi (channel, DFS, signal), router data and recent incidents.
The day and week graphs are built from 15-minute summaries (`rollups.json`) that the agent maintains.

```bash
scripts/install.sh        # the logging agent (launchd), collects the data
scripts/install-app.sh    # the app + widget → ~/Applications/NetWatch.app (needs xcodegen)
```

Signing needs an Apple Development certificate (a free Apple ID is enough): the team is taken from it automatically,
or set it by hand: `NETWATCH_TEAM=ABCDE12345 scripts/install-app.sh`. Replace the bundle identifiers (`com.egor.*`) with your own in `project.yml` and `scripts/install.sh`.

To add it: right-click the desktop → "Edit Widgets" → NetWatch.

- `project.yml` describes the Xcode project (`NetWatch.xcodeproj` is generated and not kept in git).
- `swift run netwatch-preview build/previews` draws the widget to PNG without WidgetKit.
- The app icon is drawn in code (`Sources/netwatch-icon`): `swift run netwatch-icon App/Assets.xcassets/AppIcon.appiconset`.
- The widget runs sandboxed and reads the agent's log through a narrow read-only exception
  (`com.apple.security.temporary-exception.files.home-relative-path.read-only`). That is not accepted for the App Store, but is fine for a personal install.
- The system refreshes the extension on its own budget, so the host app watches the log and asks for a refresh
  when the state changes and once a minute. The app runs in the background: it has no Dock icon, and its window opens when you click the widget.

## <img src="docs/icons/status.svg" width="30" height="30" align="absmiddle"> What counts as a problem

| Verdict | Condition |
|---|---|
| No network | no interface or router |
| Wi-Fi/router | nothing gets through: neither the router nor the internet |
| Provider | the router answers, but both external addresses are unreachable directly |
| DNS | the DNS server does not answer |
| VPN | the direct path works, but HTTPS through the VPN does not |
| Degraded | more than 20% of echoes lost, the router's ICMP silent while the internet works, router >30 ms, internet >150 ms, DNS >300 ms, HTTPS >3 s |

The verdict is recomputed from the raw measurements when the log is read, so changes to the rules also apply to old data.

The report also flags Wi-Fi channel changes and incidents that coincide with DFS channels (52–64, 100–144).

## Privacy

Data stays on your Mac. To check connectivity the agent contacts your router and your DNS servers, as well as
1.1.1.1, 8.8.8.8 and a page on apple.com, nothing else. It only reads the router, and no password is needed.
