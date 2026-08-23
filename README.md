# doubletap

Interactive Bash wrapper for the aircrack-ng suite. Walks you through interface selection, monitor mode, band scanning, target selection, a focused scan, and deauth — all from a single script.


## What it does

1. Select a wireless interface and enable monitor mode (choose if you want to kill interfering processes)
2. Choose a band to scan (2.4GHz or 5GHz)
3. Run a broad scan and pick a target AP (Enter to stop)
4. Run a focused scan locked to that AP's channel (Enter to stop)
5. Select a target client (or broadcast)
6. Confirm authorization and send a deauth (ctrl +c to stop and stop monitor mode)

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
