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

4. In VidReclaim, enable Windows PC. Enter the Windows hostname and user, then
   click Test.

The tray shows transfers and encodes. Interrupted jobs can resume from the Mac.
Cancel, then Clear Finished, to remove one. It disappears immediately; disk
cleanup finishes after active transfers stop.

Quit VidReclaim cancels jobs, stops remote access, and exits. Close Monitor Only
leaves jobs and remote access running.

Start-menu entry: VidReclaim

CPU x265 is the default. RTX 4090 is the faster option.

Transfers use SSH and resume in chunks after an interruption. Sources stage in
%USERPROFILE%\VidReclaim Working\jobs and are removed after the Mac verifies the result.
Regular video files can run remotely. DVD titles and Combine jobs run on the Mac.
