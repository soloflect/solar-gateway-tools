#!/bin/bash
################################################################################
# show-stc.sh
#
# Display the current status of a Solaflect Solar Tracker Controller (STC).
#
# Connects to a remote Gateway via SSH, retrieves the most recent STC status
# record from the Stratosphere log, decodes the status fields, and displays
# the controller's current operating state, position, electrical measurements,
# temperature, status flags, wind data, and error information.
#
# The display is refreshed every 60 seconds.
#
# SSH key authentication is required. You must first add your SSH public key
# to the authorized_keys file for the pi user on the Gateway device.
#
# Usage:
#   show-stc.sh [-u gateway_user] gateway_host
#
#   -u gateway_user  SSH user for the Gateway (default: pi)
#   gateway_host     Gateway hostname or IP address
#
# Copyright (C) 2025
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.
#
################################################################################

main() {
    while true; do
        show_stc
        sleep 60
    done

    return 0
}

show_stc() {

line=$(ssh ${GATEWAY_USER}@${GATEWAY_HOST} "grep 'Status(machines/' '${LOG_PATH}' | tail -n 1")

if [[ "$line" != *"Status(machines/"* ]]; then
    echo "No STC status record found."
    return 1
fi

# Extract CID
cid=$(echo "$line" | sed -n 's/.*Status(machines\/\([^/]*\)\/messages,.*/\1/p')

# Extract status data
status=${line#*Status(machines/*/messages, }
status=${status%)*}

IFS=',' read -ra f <<< "$status"

# Convert 0/1 to False/True
bool()
{
    if [ "$1" = "0" ]; then
        echo "False"
    else
        echo "True"
    fi
}

# State
case "${f[11]}" in
    0) state="WAITING" ;;
    1) state="TRACKING" ;;
    2) state="WINDSTOW (ACTIVE)" ;;
    3) state="ERROR RECOVERY" ;;
    4) state="CALIBRATING" ;;
    5) state="STANDBY" ;;
    6) state="LOCKED" ;;
    7) state="WINDSTOW (PASSIVE)" ;;
    8) state="TECH MODE" ;;
    *) state="${f[11]}" ;;
esac

# Convert STC Julian date/time to normal date/time
year="20${f[0]:0:2}"
jday="${f[0]:3:3}"
time="${f[0]:7:8}"

datetime=$(date -d "$year-01-01 +$((10#$jday - 1)) days $time" \
    "+%Y-%m-%d %H:%M:%S")

# Temperature
temp="${f[35]}"
temp_f=$((temp * 9 / 5 + 32))
temp_display="${temp}C (${temp_f}F)"

# Voltage and current
volt=$(awk "BEGIN {printf \"%.1f\", ${f[19]} / 10}")
peakcur=$(awk "BEGIN {printf \"%.1f\", ${f[20]} / 10}")
avgcur=$(awk "BEGIN {printf \"%.1f\", ${f[21]} / 10}")

clear

echo
echo "STC $cid"
echo

printf "%-10s %-20s %-19s %7s %7s %7s %7s %7s %9s %7s %9s\n" \
    "CID" "STATE" "DATETIME" "AZPOS" "ELPOS" "AZNEXT" "ELNEXT" \
    "VOLT(DC)" "PEAKCUR(A)" "AVGCUR(A)" "TEMP"

printf "%-10s %-20s %-19s %7s %7s %7s %7s %7s %9s %7s %14s\n" \
    "$cid" "$state" "$datetime" \
    "${f[1]}" "${f[2]}" "${f[3]}" "${f[4]}" \
    "$volt" "$peakcur" "$avgcur" "$temp_display"

echo
printf "%-5s %-5s %-5s %-5s %-5s %-5s %-8s %-9s %-6s %-6s %-8s %-8s %-7s %-6s %-6s %-20s\n" \
    "W" "E" "U" "D" "TE" "TS" "STOWED" "STOWING" "LOCK" "ESTOP" \
    "AZHOMED" "ELHOMED" "SOLCAL" "VERT" "DEG30" "ERRORS"

printf "%-5s %-5s %-5s %-5s %-5s %-5s %-8s %-9s %-6s %-6s %-8s %-8s %-7s %-6s %-6s %-20s\n" \
    "$(bool "${f[5]}")" "$(bool "${f[6]}")" \
    "$(bool "${f[7]}")" "$(bool "${f[8]}")" \
    "$(bool "${f[9]}")" "$(bool "${f[10]}")" \
    "$(bool "${f[12]}")" "$(bool "${f[24]}")" \
    "$(bool "${f[23]}")" "$(bool "${f[34]}")" \
    "$(bool "${f[14]}")" "$(bool "${f[15]}")" \
    "$(bool "${f[16]}")" "$(bool "${f[17]}")" \
    "$(bool "${f[18]}")" "${f[13]}"

echo
printf "%-7s %-7s %-7s %-7s %-8s %-9s %-10s %-8s %-10s %-9s\n" \
    "SUNE" "SUNW" "SUNU" "SUND" "WNDNOW" "WNDPEAK" \
    "ELSTALLS" "AZSTOW" "AZOFFSET" "ELOFFSET"

printf "%-7s %-7s %-7s %-7s %-8s %-9s %-10s %-8s %-10s %-9s\n" \
    "${f[25]}" "${f[26]}" "${f[27]}" "${f[28]}" \
    "${f[29]}" "${f[22]}" "${f[30]}" "${f[31]}" \
    "${f[32]}" "${f[33]}"

echo

return 0
}

################################################################################
# Initialize
#
PATH_CMD="$(readlink -f -- "$0")"
SCRIPT_DIR="$(dirname -- "$(readlink -f -- "$0")")"
PARENT_DIR="$(dirname -- "$(dirname -- "$(readlink -f -- "$0")")")"
LOG_PATH="/home/solaflect/stratosphere/log/stratosphere.log"
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export PATH
set -e
#set -x   # debug

################################################################################
# Parse command-line
#
GATEWAY_USER="pi"

if [ "$#" -lt 1 ]; then
    echo "Usage: $0 [-u gateway_user] gateway_host" >&2
    exit 1
fi

while getopts "u:h" opt; do
    case "${opt}" in
        u)
            GATEWAY_USER="${OPTARG}"
            ;;
        h)
            echo "Usage: $0 [-u gateway_user] gateway_host"
            echo "  -u gateway_user  Gateway SSH user (default: pi)"
            echo "  gateway_host     Gateway hostname or IP address (required)"
            exit 0
            ;;
        *)
            echo "Usage: $0 [-u gateway_user] gateway_host" >&2
            exit 1
            ;;
    esac
done

shift $((OPTIND - 1))

if [ "$#" -ne 1 ]; then
    echo "Usage: $0 [-u gateway_user] gateway_host" >&2
    exit 1
fi

GATEWAY_HOST="$1"
GATEWAY_CID=""

################################################################################
# Enter main
#
main
echo ""
echo "[*] Script exited cleanly."
echo ""


