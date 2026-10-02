ROBLOX RAM GUARD V7.7

Identity Detection Fix
- Each Roblox PID is now assigned to one specific Player log.
- That PID keeps retrying the SAME log as Roblox writes more session data.
- UserId detection is preferred over direct username parsing.
- Once a UserId is found, RAM Guard resolves the username through Roblox's public user API.
- Works whether RAM Guard is opened before or after Roblox.
- Roblox open/close detection remains automatic.
- Editable target/trigger/check/frozen settings remain included.

Defaults:
Target: 600 MB
Trim at: 700 MB
Check every: 3 seconds
Frozen kill: 30 seconds

Credits:
Stitch
Discord: @jhfo
