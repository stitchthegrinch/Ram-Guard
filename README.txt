ROBLOX RAM GUARD V7.6.1

Changes:
- Roblox instances now appear automatically when opened.
- Closed Roblox instances disappear automatically.
- Unknown accounts keep retrying username/UserId detection.
- More aggressive log matching for newly opened clients.
- Added editable Settings panel:
  - Target RAM MB
  - Trim trigger MB
  - Check interval
  - Frozen auto-kill timeout
- Settings save automatically to settings.json.
- Default values:
  Target: 600 MB
  Trim trigger: 700 MB
  Check interval: 3 seconds
  Frozen timeout: 30 seconds
- Main account still uses Above Normal priority.
- Saved alts continue to auto-guard.

Extract the ZIP and run:
Launch_Roblox_RAM_Guard.cmd

Credits:
Stitch
Discord: @jhfo

Hotfix:
- Fixed PowerShell reserved $PID variable conflict in closed-process cleanup.
