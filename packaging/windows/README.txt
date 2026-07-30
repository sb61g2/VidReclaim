VidReclaim Windows encoder setup

1. On the Mac, create a key if needed:
   ssh-keygen -t ed25519

2. Copy the single line printed by:
   cat ~/.ssh/id_ed25519.pub

3. On Windows, double-click:
   Install VidReclaim Worker.cmd

   Approve the Administrator prompt, paste the Mac public key, and choose
   whether VidReclaim should start with Windows.

Manual alternative from PowerShell as Administrator:
   Set-ExecutionPolicy -Scope Process Bypass
   .\Install-VidReclaimWorker.ps1 -PublicKey 'PASTE THE KEY HERE'

4. In VidReclaim, enable Windows PC under Quality and speed. Enter the Windows
   hostname (shown by the setup), Windows user, and click Test.

The tray icon shows current transfers and encodes. Its menu can pause or cancel
jobs, change the Start with Windows preference, or shut down VidReclaim fully.
Full shutdown cancels its jobs, stops remote access, and exits. Close Monitor
Only leaves remote access and active jobs running.

Start-menu entry: VidReclaim

CPU x265 is the default. RTX 4090 is the faster option.

Transfers use SSH and resume in chunks after an interruption. Sources stage in
%USERPROFILE%\.vidreclaim\jobs and are removed after the Mac verifies the result.
Regular video files can run remotely. DVD titles and Combine jobs run on the Mac.
