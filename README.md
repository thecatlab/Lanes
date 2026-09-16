# Lanes

A native macOS menu bar app for intentional focus. Choose **Primary**, **Maintenance**, or **Sandbox**, optionally select an Area, and start tracking your time.

Lanes is a local-first pilot for **macOS Tahoe 26 or later**. It uses Swift, SwiftUI, and AppKit, with no third-party packages, account, or analytics.

## Features

- **Focus lanes:** start, pause, resume, and end sessions, with daily totals and saved history.
- **Areas:** choose a lane from the New Area dropdown independently of your current Focus lane. Set each lane's capacity and move Areas between lanes while retaining their recorded time. A lane containing one Area selects it automatically.
- **Menu bar status:** an icon while idle, and the current Area or lane during Focus. Long labels scroll within a fixed width; Reduce Motion uses truncation and a tooltip. Closing the popover resets it to the top of the main Focus screen for the next opening.
- **Focused projects:** optionally display up to five Areas ranked by time spent in the last 30 days.
- **Curiosity Inbox:** save ideas to revisit after Focus.
- **Sandbox budget:** an optional daily total across Sandbox sessions, with an optional notification at the limit.
- **Local website blocking:** block domains and their subdomains during Focus through a local HTTP/HTTPS proxy.
- **Session recovery:** pause on screen lock or sleep, and recover interrupted sessions at the last saved checkpoint.

## Build and run

Requirements:

- macOS Tahoe 26 or later.
- Xcode 26 Command Line Tools or a compatible Swift 6 toolchain with the macOS 26 SDK.

From the repository root:

```sh
zsh scripts/build.sh
open build/Lanes.app
```

The script builds both executables, assembles `build/Lanes.app`, and applies a local ad-hoc signature. **No paid Apple Developer membership or Developer ID certificate is required for this local build.** It is not notarized for public distribution. Apple silicon is the tested platform; the script builds for the host architecture.

For daily use, move `Lanes.app` to your Applications folder before enabling **Launch at login**. Build output and Swift caches are generated locally and excluded from Git.

## Website blocking setup

1. Open Lanes → **Settings** → **Set up website blocking…**.
2. Approve the macOS administrator authentication prompt to configure the network once.
3. Add domains under **Edit blocked websites…**, then leave **Block websites** enabled.
4. Choose a lane and press **Start Focus**.

If upgrading from the initial automatic-proxy build, choose **Repair website blocking…** instead and approve the one-time migration to explicit HTTP/HTTPS proxy settings.

Subsequent Focus sessions update local rules without another administrator prompt. **End focus** removes the restrictions; pausing keeps them in place. Turn off **Block websites** to use time tracking without the proxy setup.

### How it works

A background helper listens only on `127.0.0.1:19347`. Setup assigns it as the HTTP and HTTPS proxy for existing Wi-Fi/Ethernet network services, with localhost exceptions. It migrates Lanes' older automatic proxy configuration (PAC), refuses to overwrite another enabled proxy, and leaves VPN services unchanged.

The helper checks destination hostnames and opens its own outgoing connections directly, preventing the system proxy from routing traffic back into the helper. HTTPS remains encrypted through CONNECT tunnels: Lanes does not install certificates, decrypt page contents, or record browsing history. A blocked HTTPS website usually displays the browser's connection error.

### Limits and recovery

- Coverage depends on applications respecting macOS proxy settings. Browser-specific proxies, VPN routes, direct connections, and some protocols can bypass the blocker.
- Blocking applies to entire domains and their subdomains, not individual URL paths. Cached or offline pages can remain visible.
- Existing connections routed through Lanes are closed when their domain becomes blocked. Restart the browser after initial setup if it retains earlier direct connections.
- The helper runs independently of the menu app and restarts through launchd. The app checks its local health endpoint and retains the requested rules through temporary interruptions, restoring active status when the helper and network recover. If the menu app stops renewing its rules, restrictions expire within 35 seconds.
- The explicit proxy has no direct-connection fallback. If the helper is unavailable, proxied browsing may pause until launchd restarts it. If recovery fails, use **Repair website blocking…** or **Remove blocking setup…** in Settings. Turning off the blocking toggle clears domain rules but keeps the proxy installed.
- Newly added network interfaces may need setup again. Browser coverage, VPN coexistence, reboot, and sleep/wake behavior still need broader device validation.

This is a personal focus aid, not a tamper-resistant firewall. The Sandbox budget is also a reminder rather than a forced stop.

### Remove blocking setup

Choose **Settings → Remove blocking setup…** and approve macOS if requested. Lanes restores the proxy fields it changed and removes its background LaunchAgent. Do this before deleting the app.

## Local data

| Location | Contents |
| --- | --- |
| `~/Library/Application Support/Lanes/state.json` | Preferences, Areas, sessions, and inbox items |
| `~/Library/Application Support/Lanes/Proxy/` | Helper executable, temporary blocking rules, health status, and original proxy settings backup |
| `~/Library/LaunchAgents/com.nusaindah.Lanes.Proxy.plist` | Background helper registration |

These files are outside the repository. Focus time comes from sessions you start; Lanes does not automatically track which applications you use. History displays the latest 100 segments while totals include all saved segments.

## Project structure

```text
.
├── Package.swift
├── README.md
├── .gitignore
├── Resources/
│   └── Info.plist
├── Sources/
│   ├── Lanes/          # Menu bar app, views, state storage, proxy setup
│   ├── LanesCore/      # Focus, Area, budget, and domain models
│   ├── LanesProxy/     # Background helper entry point
│   └── LanesProxyKit/  # HTTP/HTTPS proxy, request parsing, blocking policy
└── scripts/
    └── build.sh
```

This repository contains the app source and build essentials. Generated binaries, design drafts, screenshots, sample-data utilities, and development test runners are not included.
