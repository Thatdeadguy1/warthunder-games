# WinOptimizer

A safe, reversible tune-up tool for Windows 10/11 laptops, written in plain
PowerShell (no installs, no third-party code). It sticks to changes that are
documented and actually do something, and avoids the "optimiser" tricks that
make Windows slower or less secure.

## How to run

1. Download this folder (or the repo as a ZIP and extract it).
2. Double-click **`Run-WinOptimizer.bat`**.
3. Click **Yes** on the UAC prompt. Admin rights are needed to clean
   `C:\Windows\Temp`, change power plans and run SFC/DISM.

Or from a terminal:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\WinOptimizer.ps1
```

`-ExecutionPolicy Bypass` only applies to this one run; it does not change
your system's policy.

## Menu

| # | Option | What it actually does |
|---|--------|------------------------|
| 1 | System health report | CPU, GPU + driver version, RAM use, uptime, free disk space, disk health, battery wear, top memory users, startup count, with suggestions |
| 2 | Clean junk files | Shows sizes first, then deletes: your temp folder and `C:\Windows\Temp` (only files older than 24 h, so running installers aren't broken), the Windows Update download cache, old crash reports, the Delivery Optimization cache. Optionally empties the Recycle Bin |
| 3 | Power plan | Balanced / High performance / Ultimate performance. If your laptop hides the plan, it creates it once. If Windows refuses (Modern Standby laptops), it opens the Power mode setting instead |
| 4 | Gaming tweaks | Game Mode on, Xbox Game Bar background recording off, hardware-accelerated GPU scheduling, and **force a game onto the dedicated GPU** (auto-finds War Thunder's `aces.exe` in Steam libraries and the Gaijin launcher's default folder) |
| 5 | Lighter visual effects | Turns off transparency, opens the "Adjust for best performance" dialog |
| 6 | Startup apps | Lists startup entries and opens the Settings page to turn them off |
| 7 | Maintenance & repair | `Optimize-Volume` (TRIM for SSDs, defrag for HDDs, picked automatically), `sfc /scannow`, DISM RestoreHealth / StartComponentCleanup, DNS flush, battery report, Windows Update |
| 8 | Quick tune-up | Restore point + junk clean + Game Mode + recording off + drive optimise + DNS flush. Does not touch the Recycle Bin or power plan |
| 9 | Restore point | Creates a System Restore point |
| U | Undo all tweaks | Puts every registry value it changed back exactly how it was |

## Safety

- **Every registry change is backed up** to
  `%LOCALAPPDATA%\WinOptimizer\registry-backup.json` before it is made, and
  menu option **U** restores the originals (or deletes values that didn't
  exist before).
- **Each session is logged** to `%LOCALAPPDATA%\WinOptimizer\log-*.txt`.
- The cleaner never follows junctions/symlinks, refuses empty paths and drive
  roots, and skips files that are in use.
- Services stopped to clear the Windows Update cache (`wuauserv`, `bits`) are
  restarted only if they were running before.

## Things it deliberately does NOT do

Common "optimiser" tweaks that are myths or harmful:

- **Clearing the Prefetch folder** - Windows uses it to start apps faster;
  deleting it makes the next launches slower.
- **"RAM cleaners" / memory boosters** - Windows uses spare RAM as a file
  cache on purpose. Forcing it empty just means reloading from disk.
- **Registry cleaners** - Microsoft doesn't support them; the gain is
  negligible and a bad deletion can break apps.
- **Disabling Windows Defender / Security** - small or no FPS gain, large
  security risk.
- **Disabling the page file** - games that run out of memory will crash
  instead of slowing down.
- **Disabling services (SysMain, Search, etc.)** - little measurable gain on
  an SSD and can break features.
- **Defragmenting an SSD** - the drive option uses Windows' own
  `Optimize-Volume`, which sends TRIM to SSDs instead.

## Honest expectations

The biggest real-world wins on a gaming laptop are usually:

1. **Plugged in** + **High performance / Best performance** power mode.
2. The game running on the **dedicated GPU** (option 4 -> 4).
3. An **up-to-date GPU driver** from NVIDIA / AMD / Intel.
4. Good airflow - laptops throttle when hot; don't game on a bed or blanket.
5. Fewer background apps (option 6).

Clearing junk frees disk space; it rarely changes FPS.

## Notes

- Works in the built-in Windows PowerShell 5.1 and in PowerShell 7. It
  relaunches with whichever one you started it from. Creating restore
  points only works in 5.1, because `Checkpoint-Computer` only exists there.
- If you see *"Program 'powershell.exe' failed to run: Access is denied"*,
  something on the PC (security software or a school/work policy) is
  blocking new PowerShell windows. Open **Terminal (Admin)** from the
  Win + X menu and run the script from there.
- Per-user tweaks (Game Mode, GPU preference, transparency) apply to the
  account that approved the UAC prompt. On a normal personal laptop that's
  you; if you elevate with a *different* admin account, they apply to that
  account instead.
- Windows only allows one restore point per 24 hours by default, so a second
  one the same day is skipped (the tool tells you).
- Hardware-accelerated GPU scheduling and some visual changes need a restart.
