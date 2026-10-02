ROBLOX RAM GUARD v7.8.2 - Account Detection Fix

INSTALL
1. Close the old RAM Guard window.
2. Extract all files into your existing RAM Guard folder, replacing the old
   script and README. Keep your alts.json, main.json and settings.json files.
3. Run Launch_Roblox_RAM_Guard.cmd. The window should say v7.8.2.
4. Leave Roblox open, join a game, and allow several seconds for detection.
   Detection supports starting Guard before or after Roblox.

The script keeps the name Roblox_RAM_Guard_v7_8.ps1 so your existing launcher
continues to work. Its contents and window version are v7.8.2.

WHAT WAS WRONG
- Finding a UserId without a username created a permanently cached Unknown.
- No UserId-to-username lookup existed.
- The UI only noticed a new cache entry, not an existing entry gaining a name.
- Logs larger than 8 MB were read from the end, losing startup identity fields.
- Log matching used last-write time, which changes while Roblox runs, and could
  fall back to a different account's old log.

FIXES
- Background batch lookup of public usernames from detected UserIds.
- Incomplete identities are retried; failed network lookups retry after 60 seconds.
- Username changes refresh the displayed account row.
- Reads both startup and recent sections of large logs, sharing live log access.
- Matches native thread IDs in logs to live Windows process threads first.
  Requires two distinct matching IDs recorded after process creation.
- Removes the strict 3-second logger-clock window from the primary match.
- Uses CIM creation time if the direct process start-time query is denied.
- If thread enumeration is unavailable, only accepts a single unambiguous
  timing candidate. PID reuse is checked against process creation time.
- Prioritizes local-account telemetry and handles escaped/encoded fields.
- Does not treat arbitrary game-printed UserIds as the local account.

IF AN ACCOUNT STILL SHOWS UNKNOWN
Double-click its row to see detection details.
- Waiting for username lookup: check internet access and wait up to 60 seconds.
- Waiting for local account fields: join a game and give Roblox time to log them.
- No matching live threads: check the details box for scanned-log and thread counts.
- Thread enumeration unavailable: reopening clients separately can help timing fallback.
Send a screenshot of that details box if detection still fails. A client whose
logs omit local account identifiers cannot be identified by this log-based method.
The script does not assume that the website's logged-in account owns all clients.

NETWORK / VALIDATION
Uses Roblox's public POST https://users.roblox.com/v1/users endpoint with detected
numeric UserIds. No account cookies, passwords or launch tickets are read or sent.
API reference: https://create.roblox.com/docs/cloud/reference/domains/users

Validated extracted regexes against the actual supplied Roblox 0.741 log:
local UserId 4972142344 and 19 distinct native thread IDs were parsed.
Checked an ownership reference model for separate clients, tied ownership,
recycled thread IDs and delayed logger startup. Checked full-file lexical
delimiters. The earlier synthetic parser and large-log fixture checks passed.
Windows PowerShell and live Roblox were unavailable in the repair environment;
the Windows UI, API lookup and real-client matching still need an on-PC run.

Defaults (unchanged):
Target RAM: 600 MB
Trim at: 700 MB
Check every: 3 seconds
Frozen kill: 30 seconds

Credits: Stitch
Discord: @jhfo
