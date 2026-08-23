# doubletap

Interactive Bash wrapper for the aircrack-ng suite. Walks you through interface selection, monitor mode, band scanning, target selection, a focused scan, and deauth — all from a single script.


DOUBLETAP

Interactive wrapper around the aircrack-ng suite. Automates the manual airmon-ng → airodump-ng → aireplay-ng workflow into a single guided command, styled as a COD Zombies gumball-machine themed recon tool — without giving up any of aircrack's flexibility.

Maintained by Dr-Fractures.

## What it does

1. **Interface select** — lists wireless interfaces, optionally kills conflicting network processes (NetworkManager, wpa_supplicant), enables monitor mode
2. **Band select** — 2.4GHz or 5GHz
3. **Broad scan** — airodump-ng runs in the background; a live ticker prints each newly discovered SSID (with OUI vendor lookup) right in this same window as it's found — no switch to airodump's own full-      screen table. Press Enter anytime to stop.
4. **AP select** — lettered table of discovered access points (BSSID / channel / power / ESSID / OUI)
5. **Focused scan** — locks to the target AP's channel; the ticker switches to printing newly discovered client MACs (with OUI) as they're heard. Press Enter anytime to stop.
6. **Client select** — pick a specific connected client or all for broadcast (all clients)
7. **Deauth** — confirms authorization, then runs aireplay-ng -0 0 against the selected target

Selections use single letters (a, b, c...) for fast input, rolls over to numbers after 'z'. (whatever)

## Requirements

- Linux with `aircrack-ng` suite installed (`airmon-ng`, `airodump-ng`, `aireplay-ng`)
- Root privileges
- A wireless adapter that supports monitor mode

## Installation

```bash
git clone https://github.com/AmpedGH/doubletap.git
cd doubletap
chmod +x install.sh
sudo ./install.sh
```

This symlinks `doubletap.sh` into `/usr/local/bin/doubletap`.

## Usage

```bash
sudo doubletap
```

## Warning

⚠️ Use only on networks you own or have explicit written authorization to test. Unauthorized use against networks you don't own is illegal.

## License

MIT
