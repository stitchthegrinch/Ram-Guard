# RAM Guard 8.0

A Windows desktop utility for monitoring Roblox clients and trimming saved alt accounts. Credits: Stitch / @jhfo.

## Start here

1. Close the previous RAM Guard, extract the entire ZIP, then run `Launch_Roblox_RAM_Guard.cmd`.
2. The **Alt Guard starts OFF**. Let your Roblox accounts load.
3. Select your main, then **Account role > Mark as Main**. Mark the other accounts as Alts.
4. Click **Trim All Alts** when they are ready. This works with the guard OFF.
5. Turn **Alt Guard ON** if you want automatic trimming and the configured frozen-client handling.

Turning ON enables currently recognized, saved alts. Any client that joins or restarts afterward begins paused; select it and click **Enable** when ready. **Pause** affects selected alts; **Pause all** affects every alt. OFF stops all automatic trims and automatic closures. Manual actions remain available.

Only accounts marked Alt are managed. Main is excluded from trim, minimize, close, and automatic handling. RAM Guard does not change process priorities. Trimming releases working-set memory; memory can grow again as Roblox uses it.

## Organized controls

- **Clients:** memory overview, account search, account list, selected-client controls, and a separate all-alt action row.
- **Open Selected:** restores and brings the selected client window forward. Double-clicking a row does the same. Windows can occasionally refuse foreground focus; the status bar explains when this happens.
- **Settings & Saves:** trim threshold, scan interval, trim cooldown, frozen-client handling, and backup/migration controls.
- Ctrl/Shift selects multiple rows. Open Selected requires exactly one row.

## Keep saves across updates

Account roles and settings are stored at:

`%LOCALAPPDATA%\RobloxRAMGuard\profile.json`

Future versions using this location load the same profile, even when extracted to another folder. ON/OFF and per-window readiness deliberately reset at startup so accounts can load first.

### Moving from v7.x

If the old `main.json`, `alts.json`, and `settings.json` are beside the new scripts on the first launch, they are imported automatically. Otherwise open **Settings & Saves > Import old folder** and select the folder containing those files. This imports RAM Guard settings and roles, not Roblox Account Manager login data or game progress.

### Moving PCs or making backups

Use **Export backup**, then **Import backup** on the other PC. Import previews the account count and requires confirmation. Import leaves automation OFF. Profiles contain account IDs/names and guard settings, not passwords or cookies.

Saves are validated before replacement. An existing profile is retained as `profile.json.bak`; startup can recover from that backup if the primary is damaged. Existing profiles take precedence over files bundled with an update.

## Changes in 8.0

- Added Open Selected and double-click window activation with process/window ownership checks.
- Added global OFF/ON, per-alt Pause/Enable, and all-alt controls. New client instances start paused.
- Manual Trim All Alts works while OFF; Main stays protected.
- Reorganized the UI into Clients and Settings & Saves with grouped actions.
- Added stable save storage, legacy migration, export/import, validation, and backup recovery.
- Fixed repeated worker initialization that could reset scan caches. Scanning remains asynchronous with no overlapping scans.
- Slow scan gaps reset frozen-client evidence instead of counting as continuous frozen time.

## Validation and requirements

Windows with Windows PowerShell 5.1 and Windows Forms is required. Keep both `.ps1` files and the launcher together. Run only one RAM Guard version at a time.

`tests/Validate.ps1` covers account protection, pause/readiness policy, manual/automatic trim behavior, cooldowns, PID reuse, log parsing, save migration/recovery, and repeated asynchronous scans with 50 simulated clients. All 38 checks passed under PowerShell 7.4.6 on Linux. Actual Windows UI rendering, native process calls, window focus, and performance with real Roblox clients still require on-PC validation.

The launcher uses Windows PowerShell. Its `.cmd` wrapper may briefly show a command window.
