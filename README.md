# Ram-Guard
Here’s a clean README you can drop straight into GitHub:

# Roblox RAM Guard

A lightweight Windows utility for managing multiple Roblox instances and keeping RAM usage under control.

Built for users who run several Roblox clients at once and want an easier way to monitor, trim, minimize, and manage them.

## Features

- Shows RAM usage for each Roblox instance
- Shows total Roblox RAM usage
- Shows overall system RAM usage
- Detects Roblox usernames and UserIds
- Lets you mark accounts as saved **Alts**
- Automatically recognizes saved alts
- Automatically guards saved alts
- Trim selected Roblox clients
- Trim all saved alts
- Kill selected Roblox clients
- Detect frozen Roblox clients
- Kill all frozen clients
- Minimize all saved alt windows
- Status colors:
  - Green = Normal
  - Yellow = High RAM
  - Red = Frozen
- Multi-select support
- Dark UI
- Saves alt data locally

## How To Use

1. Download the latest release.
2. Extract the ZIP file.
3. Run `Launch_Roblox_RAM_Guard.cmd`.
4. Open your Roblox clients.
5. Press **Refresh** if needed.
6. Select the accounts you want to manage.
7. Mark your alternate accounts using **Mark as Alt**.
8. Saved alts will be remembered the next time the program is opened.

## Main Controls

**Trim Selected**  
Reduces memory usage for selected Roblox clients.

**Trim All Alts**  
Trims every Roblox account saved as an alt.

**Kill Selected**  
Closes selected Roblox instances.

**Kill All Frozen**  
Closes Roblox clients detected as frozen.

**Minimize All Alts**  
Minimizes all Roblox windows belonging to saved alt accounts.

**Mark as Alt**  
Saves the selected Roblox account as an alt.

**Remove Alt**  
Removes the selected account from the saved alt list.

## Username Detection

Roblox does not directly expose the account username through the Windows process.

Roblox RAM Guard attempts to identify each client by matching the running Roblox process with its Player session logs.

Because of this, a client may temporarily display as `Unknown` shortly after launching.

The program automatically retries unresolved clients.

## Windows Warning

Roblox RAM Guard currently uses PowerShell and a CMD launcher.

Because of this, Windows SmartScreen or antivirus software may sometimes display a warning.

The source code is available in this repository so users can inspect exactly what the program does.

Always extract the ZIP before running the launcher.

## Requirements

- Windows 10 or Windows 11
- PowerShell
- Roblox Player

## Disclaimer

This project is not affiliated with, endorsed by, or associated with Roblox Corporation.

Use this software at your own risk.

## Credits

Created by **Stitch**

Discord: **@jhfo**

I can also make you a more polished GitHub version with badges, screenshots section, releases section, and a cleaner project header if you want.
