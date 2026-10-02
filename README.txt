ROBLOX RAM GUARD v7.9 - Many-Client Performance Update

INSTALL
1. Close the old Guard window.
2. Extract this ZIP into your existing Guard folder and replace the launcher.
3. Keep your alts.json, main.json and settings.json files.
4. Run Launch_Roblox_RAM_Guard.cmd. The window should show v7.9.

PERFORMANCE CHANGES
- Log scanning and process monitoring run in one persistent background worker.
- The Guard window appears before monitoring starts.
- Only one monitor scan may run at a time; slow scans do not stack up.
- A 60-second watchdog requests cancellation without waiting on the interface.
  Another scan starts only after the previous worker invocation has finished.
- The existing client list stays visible during a slow scan.
- Identity scans run at most once every 10 seconds unless clients change or
  Refresh is clicked. The normal RAM polling interval remains configurable.
- Typical log sampling is reduced from up to 8 MB to 256 KB per changed log.
  Unresolved identities still get the larger fallback read.
- Each native thread timestamp is parsed once, using its latest log entry.
- The system RAM meter uses the Windows memory API instead of a WMI query.
- Process start-time fallback uses one bounded CIM query per scan.
- Rows update in place, preserving selection and checkboxes.

GUARD BEHAVIOR
- Automatic RAM trims have a 30-second cooldown per client.
- Frozen or unmeasured clients are not automatically trimmed.
- Frozen-client closure requires at least three fresh observations and the
  configured frozen duration. Newly started clients get a 60-second grace period.
- Missing or delayed scans reset frozen tracking instead of counting as a freeze.
- Automatic actions verify process ID and creation time before acting.
- Main accounts are protected by the automatic guard and Kill All Frozen.

ACCOUNT DETECTION
The working v7.8.2 thread-based account matching and background username lookup
are retained. Double-click an account row for detection details.
Double-click the bottom status text for monitor state and the latest monitor error.

SCOPE
This update reduces work and blocking inside the Guard. It cannot guarantee that
Roblox clients stay connected when the PC runs out of resources or when a Roblox
server or network connection times out.

VALIDATION
The supplied real Roblox log still yields UserId 4972142344 with the smaller
sample. Latest per-thread timestamps match the previous algorithm. Timestamp
parsing on that log drops from 2,592 entries to 19 distinct threads.
A synthetic 50-client large-log read-budget check reduces sampled data from
400 MiB to 12.5 MiB per identity scan for resolved logs. This is a byte-budget
comparison, not a measured Windows speedup.
Source/lexical checks and guard-policy reference models passed. Windows
PowerShell, the WinForms UI, and live many-client load were unavailable here;
the new background-worker integration requires testing on your PC.

Defaults:
Trim trigger: 700 MB
Polling interval: 3 seconds
Frozen duration: 30 seconds
Automatic trim cooldown: 30 seconds

Credits: Stitch
Discord: @jhfo
