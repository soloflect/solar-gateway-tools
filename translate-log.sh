#!/bin/bash
################################################################################
# translate-log.sh
#
# Translate STC status log records into a human-readable tabular format.
#
# Log input is read from STDIN by default and translated records are written
# to STDOUT.  When a Gateway host is specified, the log is obtained through
# an SSH session to the Gateway.
#
# Operational modes:
#
#   STDIN
#       Read log records from STDIN.
#
#   GATEWAY
#       Read the STC log from a Gateway using SSH.
#
#   FOLLOW
#       Follow the STC log on a Gateway using "tail -F" over SSH.
#
# Options:
#
#   -f
#       Follow the remote STC log using tail -F.  Requires gateway_host.
#
#   -H lines
#       Print the column header after every specified number of translated
#       log records.  The header is always printed once at startup.
#
#   -u gateway_user
#       SSH user for the Gateway (default: pi).
#
#   -h
#       Display command-line usage information.
#
# Usage:
#
#   translate-log.sh
#       Translate log records from STDIN.
#
#   translate-log.sh gateway_host
#       Translate the STC log from a Gateway.
#
#   translate-log.sh -f gateway_host
#       Follow and translate the STC log from a Gateway.
#
#   translate-log.sh -f -H 25 gateway_host
#       Follow the Gateway log and print the header every 25 records.
#
# The translator filters the input stream and processes only STC Status()
# records.  Non-status log records are ignored.
#
# SSH key authentication is required. You must first add your SSH public key
# to the authorized_keys file for the pi user on the Gateway device.
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
   local line=""

   # Column formats
   fmt1="%-19s %-6s %-18s %-5s %-5s %-6s %-6s %-8s %-10s %-9s %-9s "
   fmt2="%-1s %-1s %-1s %-1s %-2s %-2s %-6s %-7s %-4s %-5s %-7s %-7s %-6s %-4s %-5s %-6s "
   fmt3="%-4s %-4s %-4s %-4s %-6s %-7s %-8s %-6s %-8s %-8s"

   print_header

   ################################################################################
   # Open log input
   #
   if [ -n "${GATEWAY_HOST}" ]; then

       if ${FOLLOW}; then
           exec 3< <(
               ssh "${GATEWAY_USER}@${GATEWAY_HOST}" \
                   'tail -F /home/solaflect/stratosphere/log/stratosphere.log'
           )
       else
           exec 3< <(
               ssh "${GATEWAY_USER}@${GATEWAY_HOST}" \
                   'cat /home/solaflect/stratosphere/log/stratosphere.log'
           )
       fi

   else

       exec 3<&0

   fi

   ################################################################################
   # Translate log
   #
   while IFS= read -r line <&3; do
 
       [[ "${line}" =~ Status\(machines/[^/]+/messages,\ [0-9]{2}-[0-9]{3}\  ]] || continue

       if [ "${HEADER_INTERVAL}" -gt 0 ] &&
          [ "${OUTPUT_COUNT}" -ge "${HEADER_INTERVAL}" ]; then
           print_header
        OUTPUT_COUNT=0
       fi

       print_line "${line}"
       ((++OUTPUT_COUNT))

   done

   exec 3<&-

   return 0
}

print_header() {
   # "Solaflect Local Time" (SLT) is the local time maintained by the Stratosphere Gateway and STC,
   # without regard to Daylight Saving Time.
   printf "$fmt1" \
       "LOCALTIME(SLT)" "CID" "STATE" "AZPOS" "ELPOS" "AZNEXT" "ELNEXT" \
       "VOLT(DC)" "PEAKCUR(A)" "AVGCUR(A)" "TEMP"
   printf "$fmt2" \
       "W" "E" "U" "D" "TE" "TS" "STOWED" "STOWING" "LOCK" "ESTOP" \
       "AZHOMED" "ELHOMED" "SOLCAL" "VERT" "DEG30" "ERRORS"
   printf "$fmt3" \
       "SUNE" "SUNW" "SUNU" "SUND" "WNDNOW" "WNDPEAK" \
       "ELSTALLS" "AZSTOW" "AZOFFSET" "ELOFFSET"
   printf "\n"

   return 0
}

print_line() {
   local line="$1"

   bool() {
       if [ "$1" = "0" ]; then
           echo "-"
       else
           echo "X"
       fi
   }

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
   temp_display=$(printf "%2dC(%3dF)" "$temp" "$temp_f")

   # Voltage and current
   volt=$(awk "BEGIN {printf \"%.1f\", ${f[19]} / 10}")
   peakcur=$(awk "BEGIN {printf \"%.1f\", ${f[20]} / 10}")
   avgcur=$(awk "BEGIN {printf \"%.1f\", ${f[21]} / 10}")

   printf "$fmt1" \
       "$datetime" "$cid" "$state" \
       "${f[1]}" "${f[2]}" "${f[3]}" "${f[4]}" \
       "$volt" "$peakcur" "$avgcur" "$temp_display"

   printf "$fmt2" \
       "$(bool "${f[5]}")" "$(bool "${f[6]}")" \
       "$(bool "${f[7]}")" "$(bool "${f[8]}")" \
       "$(bool "${f[9]}")" "$(bool "${f[10]}")" \
       "$(bool "${f[12]}")" "$(bool "${f[24]}")" \
       "$(bool "${f[23]}")" "$(bool "${f[34]}")" \
       "$(bool "${f[14]}")" "$(bool "${f[15]}")" \
       "$(bool "${f[16]}")" "$(bool "${f[17]}")" \
       "$(bool "${f[18]}")" "${f[13]}"

   printf "$fmt3" \
       "${f[25]}" "${f[26]}" "${f[27]}" "${f[28]}" \
       "${f[29]}" "${f[22]}" "${f[30]}" "${f[31]}" \
       "${f[32]}" "${f[33]}"

   printf "\n"

   return 0
}

################################################################################
# Initialize
#
PATH_CMD="$(readlink -f -- "$0")"
SCRIPT_DIR="$(dirname -- "$(readlink -f -- "$0")")"
PARENT_DIR="$(dirname -- "$(dirname -- "$(readlink -f -- "$0")")")"
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export PATH
set -e
#set -x   # debug

################################################################################
# Parse command-line
#
GATEWAY_USER="pi"
GATEWAY_HOST=""
FOLLOW=false
HEADER_INTERVAL=0
OUTPUT_COUNT=0

while getopts "fhu:H:" opt; do
    case "${opt}" in
        f)
            FOLLOW=true
            ;;
        h)
            echo "Usage: $0 [-f] [-H lines] [-u gateway_user] [gateway_host]"
            echo
            echo "Translate log input to human readable format, from STDIN or a Gateway SSH session."
            echo
            echo "Options:"
            echo "  -f                Follow the remote log with tail -F"
            echo "  -H lines          Print header every N output lines"
            echo "  -u gateway_user   Gateway SSH user (default: pi)"
            echo "  -h                Display this help"
            exit 0
            ;;
        u)
            GATEWAY_USER="${OPTARG}"
            ;;
        H)
            HEADER_INTERVAL="${OPTARG}"
            ;;
        *)
            echo "Usage: $0 [-f] [-H lines] [-u gateway_user] [gateway_host]" >&2
            exit 1
            ;;
    esac
done

shift $((OPTIND - 1))

if [ "$#" -gt 1 ]; then
    echo "Error: too many arguments" >&2
    echo "Usage: $0 [-f] [-u gateway_user] [gateway_host]" >&2
    exit 1
fi

if [ "$#" -eq 1 ]; then
    GATEWAY_HOST="$1"
fi

if ${FOLLOW} && [ -z "${GATEWAY_HOST}" ]; then
    echo "Error: -f requires a gateway_host" >&2
    exit 1
fi

if ! [[ "${HEADER_INTERVAL}" =~ ^[0-9]+$ ]]; then
    echo "Error: -H requires a positive integer" >&2
    exit 1
fi
if [ "${HEADER_INTERVAL}" -lt 1 ]; then
    HEADER_INTERVAL=0
fi

################################################################################
# Enter main
#
main
echo ""
echo "[*] Script exited cleanly."
echo ""

