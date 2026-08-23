# doubletap

Interactive wrapper around the aircrack-ng suite. Automates the manual airmon-ng → airodump-ng → aireplay-ng workflow into a single guided command, without giving up any of aircrack's flexibility.

Part of the [AmpedGH](https://github.com/AmpedGH) wireless recon toolkit (see also: probe-hunter, wifi-scan, wifi-sniff).

## What it does

1. **Interface select** — lists wireless interfaces, kills conflicting network processes, enables monitor mode
2. **Band select** — 2.4GHz or 5GHz
3. **Broad scan** — live airodump-ng scan, stop anytime by typing `1`
4. **AP select** — numbered table of discovered access points (BSSID / channel / power / ESSID)
5. **Focused scan** — locks to the target AP's channel, scans for connected clients, stop anytime by typing `1`
6. **Client select** — pick a specific connected client or broadcast (all clients)
7. **Deauth** — confirms authorization, then runs `aireplay-ng -0 0` against the selected target

## Requirements

- Kali Linux (or any distro with the aircrack-ng suite installed)
- `aircrack-ng` suite: `airmon-ng`, `airodump-ng`, `aireplay-ng`
- Wireless adapter that supports monitor mode + packet injection (tested with Alfa AWUS036AXML)
- Root privileges

## Install

```bash
git clone https://github.com/AmpedGH/doubletap.git
cd doubletap
sudo ./install.sh
```

This symlinks `doubletap.sh` into `/usr/local/bin/doubletap`.

## Usage

```bash
sudo doubletap
```

Follow the prompts:
- Select your wireless interface by number
- Select band (2.4GHz / 5GHz)
- Let it scan, type `1` + Enter to stop and see discovered APs
- Select a target AP by number
- Let the focused scan run, type `1` + Enter to stop and see connected clients
- Select a client (or `0` for broadcast)
- Type `yes` to confirm you're authorized, and the deauth fires

## Architecture

```
doubletap.sh   - main script: monitor mode setup, scan orchestration, CSV parsing, deauth
install.sh     - symlinks doubletap.sh into /usr/local/bin
```

Scan results are written to CSV in a temp directory (`/tmp/doubletap.XXXXXX`) and parsed for the AP/client selection tables. Temp files and monitor mode are cleaned up automatically on exit (including Ctrl+C).

## Challenges

- **Monitor interface naming** varies by driver (`wlan0mon` vs. in-place rename to `wlan0`). The script attempts to auto-detect this via `iw dev`; if your adapter behaves differently, hardcode `MONIFACE` after the `airmon-ng start` call.
- **CSV column parsing** assumes the standard airodump-ng CSV layout. If a newer aircrack-ng version changes column order, adjust the `awk -F', '` field indices in `select_target_ap` / `select_target_client`.
- **Stopping a background airodump-ng cleanly** (rather than requiring Ctrl+C) required running it as a background job and blocking on a `read` loop for the `1` input, then killing the PID.

## Legal

For use only on networks you own or have explicit written authorization to test. Unauthorized deauthentication attacks are illegal in most jurisdictions.
