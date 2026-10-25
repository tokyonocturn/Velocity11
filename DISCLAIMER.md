# Disclaimer

Velocity11 is free, open-source software that changes **system-level settings** on your computer: registry values, Windows services, power plans, scheduled tasks, and installed applications.

Please read this before you use it.

## No warranty

The software is provided **"as is", without warranty of any kind**, express or implied, including but not limited to the warranties of merchantability, fitness for a particular purpose and noninfringement. See [LICENSE](LICENSE) for the full MIT terms.

Nobody involved with this project is liable for any damage, data loss, downtime, loss of performance, lost work, bricked configuration or any other cost arising from its use - direct or consequential.

## What it actually does

- It writes **registry values**, changes **service startup types**, switches **power plans**, edits **power-plan sub-settings**, disables **scheduled tasks**, removes **preinstalled applications** for your account and from provisioning, and can run `OneDriveSetup.exe /uninstall`.
- It is designed for **Windows 10 and Windows 11**. Other systems are unsupported and untested.
- Changes take effect immediately, at the next sign-in, or **after a reboot** - the tool tells you which.

## Your safety net, and its limits

- Before the first change, Velocity11 writes a snapshot folder containing the previous value of every setting it touches, `reg.exe` exports, and a change log. **Undo Tweaks** restores from it.
- A System Restore point can also be created from the button in the app.
- These are recovery aids, **not a backup**. They cannot reinstall an uninstalled application, and they cannot repair damage caused by something unrelated (failed hardware, a bad BIOS flash, a corrupted Windows update).
- **You are responsible for reviewing what you tick.** Every checkbox has a tooltip naming the exact key, value and data type it writes. If you do not understand a line, leave it unticked.

## Risky options are off for a reason

Anything marked **`[opt-in]`** - disabling services, denying camera/microphone access, core parking, the Ultimate Performance plan, toast notifications, the OneDrive uninstall - ships unticked because it changes real behaviour that you may depend on. Turning those on is your decision and your risk.

## Overclocking and hardware guidance

Any information in this repository about overclocking, undervolting, memory profiles, power plans, monitor settings or NVIDIA/AMD/Intel options is **general information only**. It is not professional engineering, repair or warranty advice, and it is not tailored to your specific hardware.

- Overclocking, undervolting and raising power or thermal limits can **reduce stability, shorten component life, void your warranty, or damage hardware**. Silicon varies; a value that is stable on one machine can crash or corrupt data on another.
- Always verify voltages, temperatures and stability yourself with independent tools, and stay within your cooler's and power supply's real limits.
- Test storage, memory and backups **before** you rely on them.

## Third parties

This project is **not affiliated with, endorsed by, sponsored by or connected to** Microsoft, NVIDIA, AMD, Intel, MSI or any other mentioned company. Windows, NVIDIA, AMD and related names are trademarks of their respective owners.

## Telemetry - ironic, but worth stating

Velocity11 itself collects, transmits and phones home **nothing**. It has no network code, no analytics and no update check. It writes files only into its own folder (snapshots and logs) and into the Windows settings you explicitly select. Everything it changes is visible in the activity log next to it.

## Your responsibility

You are responsible for:

- checking that using this software is permitted on a machine you do not own (work, school, managed or corporate devices are often policy-locked - several of these settings are Group Policy backed and may be re-enforced by your administrator),
- complying with your organisation's rules and any applicable law,
- keeping your own backups of anything you cannot afford to lose.

If you did not write it and cannot restore it, do not assume you can undo it.
