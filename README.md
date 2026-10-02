# Roblox RAM Guard

A lightweight Windows utility for managing multiple Roblox instances and keeping RAM usage under control.

Designed for users who run several Roblox clients at once and want an easier way to monitor, trim, minimize, and manage them.

---

## Features

- Per-instance Roblox RAM usage
- Total Roblox RAM usage
- System RAM meter
- Roblox username and UserId detection
- Save accounts as **Alts**
- Automatically recognize saved alts
- Automatically guard saved alts
- Trim selected Roblox instances
- **Trim All Alts**
- Kill selected instances
- Frozen-client detection
- **Kill All Frozen**
- **Minimize All Alts**
- Multi-select controls
- Dark UI
- Status colors:
  - 🟢 Normal
  - 🟡 High RAM
  - 🔴 Frozen
- Saves alt configuration locally

---

## Installation

1. Go to the **Releases** section.
2. Download the latest ZIP.
3. Extract the ZIP.
4. Run:

```text
Launch_Roblox_RAM_Guard.cmd
```

> Do not run the launcher directly from inside the ZIP.

---

## Usage

Open your Roblox clients, then launch Roblox RAM Guard.

Select any Roblox instance to manage it.

### Main Controls

| Button | Description |
|---|---|
| **Trim Selected** | Trims selected Roblox instances |
| **Trim All Alts** | Trims every saved alt |
| **Kill Selected** | Closes selected Roblox instances |
| **Kill All Frozen** | Closes clients detected as frozen |
| **Minimize All Alts** | Minimizes all saved alt Roblox windows |
| **Mark as Alt** | Saves the selected account as an alt |
| **Remove Alt** | Removes the account from the saved alt list |
| **Refresh** | Refreshes running Roblox instances |

---

## Alt System

Accounts can be marked as **Alts** inside the program.

Saved alts are stored locally and automatically recognized when they appear again.

Once detected, saved alts can automatically be selected and monitored by RAM Guard.

---

## Username Detection

Roblox does not directly expose the username of each client through the Windows process.

RAM Guard identifies clients by matching running Roblox processes with their Roblox Player session logs.

A newly opened client may temporarily show:

```text
Unknown
```

The program will continue attempting to resolve the account automatically.

---

## Windows SmartScreen / Antivirus

Roblox RAM Guard currently uses PowerShell and a CMD launcher.

Because downloaded scripts can trigger Windows security warnings, Windows SmartScreen or antivirus software may warn before launching the program.

The source code is included in this repository so you can inspect what the program does.

---

## Requirements

- Windows 10 / 11
- PowerShell
- Roblox Player

---

## Disclaimer

Roblox RAM Guard is an independent project and is not affiliated with, endorsed by, or associated with Roblox Corporation.

Use at your own risk.

---

## Credits

**Stitch**  
Discord: **@jhfo**
