#!/bin/bash
################################################################################
# translate-log.sh
#
# Translate STC status log records into a human-readable tabular format.
#
# Log input is read from STDIN by default and translated records are written
# to STDOUT. When a Gateway host is specified, the log is obtained through
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
#       Follow the remote STC log using tail -F. Requires gateway_host.
#
#   -H lines
#       Print the column header after every specified number of translated
#       log records. The header is always printed once at startup.
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
# records. Non-status log records are ignored.
#
# SSH key authentication is required. You must first add your SSH public key
# to the authorized_keys file for the pi user on the Gateway device.
#
# Copyright (C) 2026
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program. If not, see <https://www.gnu.org/licenses/>.
#
################################################################################

main() {
    local line=""

    cleanup() {
        [[ -n "${TEMP_DIR}" ]] && rm -rf "${TEMP_DIR}"
    }

    trap 'cleanup; exit 130' INT
    trap 'cleanup; exit 143' TERM
    trap 'cleanup' EXIT

    TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/temp.XXXXXX") || {
        echo "ERROR: unable to create temporary directory" >&2
        return 1
    }

    # Column formats
    fmt1="%-19s %-6s %-18s %-6s %-6s %-5s %-5s %-6s %-6s %-8s %-10s %-9s %-9s "
    fmt2="%-1s %-1s %-1s %-1s %-2s %-2s %-6s %-7s %-4s %-5s %-7s %-7s %-6s %-4s %-5s %-6s "
    fmt3="%-4s %-4s %-4s %-4s %-6s %-7s %-8s %-6s %-8s %-8s"

    print_header

    ################################################################################
    # Open log input
    #
    if [[ -n "${GATEWAY_HOST}" ]]; then

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

        [[ "${line}" =~ Status\(machines/[^/]+/messages,\ [0-9]{2}-[0-9]{3}\  ]] ||
            continue

        if [[ "${HEADER_INTERVAL}" -gt 0 &&
              "${OUTPUT_COUNT}" -ge "${HEADER_INTERVAL}" ]]; then
            print_header
            OUTPUT_COUNT=0
        fi

        if print_line "${line}"; then
            ((++OUTPUT_COUNT))
        fi

    done

    exec 3<&-

    rm -rf "${TEMP_DIR}"
    TEMP_DIR=""
    trap - EXIT INT TERM

    return 0
}

################################################################################
# Get cached location/configuration information for a CID
#
get_location() {
    local cid="$1"
    local shell_return_parameters=""

    if [[ -v "STC_CONFIG_CACHE[$cid]" ]]; then
        shell_return_parameters="${STC_CONFIG_CACHE[$cid]}"
    else
        if ! shell_return_parameters=$(get_conf_parameters "${cid}"); then
            return 1
        fi

        STC_CONFIG_CACHE["${cid}"]="${shell_return_parameters}"
    fi

    read -r LOCATION_LAT LOCATION_LON LOCATION_UTC_OFFSET <<< \
        "${shell_return_parameters}"

    if [[ -z "${LOCATION_LAT}" ||
          -z "${LOCATION_LON}" ||
          -z "${LOCATION_UTC_OFFSET}" ]]; then
        return 1
    fi

    return 0
}

################################################################################
# Get configuration parameters
#
get_conf_parameters() {
    local cid="$1"

    if [[ -n "${GATEWAY_HOST}" ]]; then
        get_conf_parameters_from_gateway "${cid}"
    else
        get_conf_parameters_from_local_archive "${cid}"
    fi
}

################################################################################
# Get configuration from local archive
#
get_conf_parameters_from_local_archive() {
    local local_cid="$1"
    local stlat=""
    local stlon=""
    local stutcoff=""
    local found=""

    if [[ -z "${local_cid}" ]]; then
        echo "ERROR: no CID supplied to get_conf_parameters" >&2
        return 1
    fi

    read -r stlat stlon stutcoff found < <(
        awk -v cid="${local_cid}" '
            $0 ~ "^[[:space:]]*\\[" cid "\\][[:space:]]*$" {
                found=1
                next
            }

            found && /^[[:space:]]*\[/ {
                exit
            }

            found && /^[[:space:]]*stlat[[:space:]]*=/ {
                value=$0
                sub(/^[^=]*=/, "", value)
                gsub(/[[:space:]]/, "", value)
                stlat=value
            }

            found && /^[[:space:]]*stlon[[:space:]]*=/ {
                value=$0
                sub(/^[^=]*=/, "", value)
                gsub(/[[:space:]]/, "", value)
                stlon=value
            }

            found && /^[[:space:]]*stutcoff[[:space:]]*=/ {
                value=$0
                sub(/^[^=]*=/, "", value)
                gsub(/[[:space:]]/, "", value)
                stutcoff=value
            }

            END {
                if (found)
                    printf "%s %s %s %d\n",
                           stlat, stlon, stutcoff, found
            }
        ' "${CONF_DIR}/stc.conf"
    )

    if [[ -z "${found}" ||
          -z "${stlat}" ||
          -z "${stlon}" ||
          -z "${stutcoff}" ]]; then
        echo "ERROR: CID ${local_cid} not found or incomplete in ${CONF_DIR}/stc.conf" >&2
        return 1
    fi

    printf '%s %s %s\n' "${stlat}" "${stlon}" "${stutcoff}"

    return 0
}

################################################################################
# Get configuration from Gateway
#
get_conf_parameters_from_gateway() {
    local local_cid="$1"
    local stratosphere_conf="/home/solaflect/stratosphere/conf/stratosphere.conf"
    local stc_conf=""
    local temp_stratosphere_conf=""
    local temp_stc_conf=""
    local stlat=""
    local stlon=""
    local stutcoff=""

    if [[ -z "${local_cid}" ]]; then
        echo "ERROR: no CID supplied to get_conf_parameters" >&2
        return 1
    fi

    temp_stratosphere_conf="${TEMP_DIR}/stratosphere.conf"
    temp_stc_conf="${TEMP_DIR}/stc.conf"

    if [[ ! -f "${temp_stratosphere_conf}" ]]; then
        scp -p \
            "${GATEWAY_USER}@${GATEWAY_HOST}:${stratosphere_conf}" \
            "${temp_stratosphere_conf}" || {
            echo "ERROR: unable to retrieve ${stratosphere_conf}" >&2
            return 1
        }
    fi

    stc_conf=$(awk -F'=' '
        /^[[:space:]]*stc_conf[[:space:]]*=/ {
            value=$2
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
            print value
            exit
        }
    ' "${temp_stratosphere_conf}")

    if [[ -z "${stc_conf}" ]]; then
        echo "ERROR: stc_conf not found in ${stratosphere_conf}" >&2
        return 1
    fi

    # stc_conf is relative to the Stratosphere directory.
    stc_conf="/home/solaflect/stratosphere/${stc_conf}"

    if [[ ! -f "${temp_stc_conf}" ]]; then
        scp -p \
            "${GATEWAY_USER}@${GATEWAY_HOST}:${stc_conf}" \
            "${temp_stc_conf}" || {
            echo "ERROR: unable to retrieve ${stc_conf}" >&2
            return 1
        }
    fi

    read -r stlat stlon stutcoff < <(
        awk -v cid="${local_cid}" '
            $0 ~ "^[[:space:]]*\\[" cid "\\][[:space:]]*$" {
                found=1
                next
            }

            found && /^[[:space:]]*\[/ {
                exit
            }

            found && /^[[:space:]]*stlat[[:space:]]*=/ {
                value=$0
                sub(/^[^=]*=/, "", value)
                gsub(/[[:space:]]/, "", value)
                stlat=value
            }

            found && /^[[:space:]]*stlon[[:space:]]*=/ {
                value=$0
                sub(/^[^=]*=/, "", value)
                gsub(/[[:space:]]/, "", value)
                stlon=value
            }

            found && /^[[:space:]]*stutcoff[[:space:]]*=/ {
                value=$0
                sub(/^[^=]*=/, "", value)
                gsub(/[[:space:]]/, "", value)
                stutcoff=value
            }

            END {
                if (found)
                    printf "%s %s %s\n", stlat, stlon, stutcoff
            }
        ' "${temp_stc_conf}"
    )

    if [[ -z "${stlat}" ||
          -z "${stlon}" ||
          -z "${stutcoff}" ]]; then
        echo "ERROR: CID ${local_cid} not found or incomplete in ${stc_conf}" >&2
        return 1
    fi

    printf '%s %s %s\n' "${stlat}" "${stlon}" "${stutcoff}"

    return 0
}

################################################################################
# Print column header
#
print_header() {
    # "Solaflect Local Time" (SLT) is the local time maintained by the
    # Stratosphere Gateway and STC, without regard to Daylight Saving Time.

    printf "${fmt1}" \
        "LOCALTIME(SLT)" "CID" "STATE" "SUN_AZ" "SUN_EL" "AZPOS" "ELPOS" \
        "AZNEXT" "ELNEXT" "VOLT(DC)" "PEAKCUR(A)" "AVGCUR(A)" "TEMP"

    printf "${fmt2}" \
        "W" "E" "U" "D" "TE" "TS" "STOWED" "STOWING" "LOCK" "ESTOP" \
        "AZHOMED" "ELHOMED" "SOLCAL" "VERT" "DEG30" "ERRORS"

    printf "${fmt3}" \
        "SUNE" "SUNW" "SUNU" "SUND" "WNDNOW" "WNDPEAK" \
        "ELSTALLS" "AZSTOW" "AZOFFSET" "ELOFFSET"

    printf '\n'

    return 0
}

################################################################################
# Print translated STC status record
#
print_line() {
    local line="$1"
    local cid=""
    local status=""
    local state=""
    local year=""
    local jday=""
    local time=""
    local datetime=""
    local temp=""
    local temp_f=""
    local temp_display=""
    local volt=""
    local peakcur=""
    local avgcur=""
    local datetime_utc=""
    local sun_position=""
    local az=""
    local el=""

    bool() {
        if [[ "$1" == "0" ]]; then
            printf '%s' "-"
        else
            printf '%s' "X"
        fi
    }

    if [[ "${line}" != *"Status(machines/"* ]]; then
        return 1
    fi

    # Extract CID.
    cid="${line#*Status(machines/}"
    cid="${cid%%/*}"

    if [[ -z "${cid}" ]]; then
        echo "ERROR: unable to extract CID from STC status record" >&2
        return 1
    fi

    # Extract status data.
    status="${line#*Status(machines/*/messages, }"
    status="${status%)*}"

    IFS=',' read -ra f <<< "${status}"

    # Ensure the fields required below exist.
    if [[ "${#f[@]}" -lt 36 ]]; then
        echo "ERROR: incomplete STC status record for CID ${cid}" >&2
        return 1
    fi

    # State.
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

    # Convert STC Julian date/time to normal date/time.
    year="20${f[0]:0:2}"
    jday="${f[0]:3:3}"
    time="${f[0]:7:8}"

    datetime=$(date \
        -d "${year}-01-01 +$((10#${jday} - 1)) days ${time}" \
        "+%Y-%m-%d %H:%M:%S") || {
        echo "ERROR: invalid STC date/time in CID ${cid}: ${f[0]}" >&2
        return 1
    }

    # Temperature.
    temp="${f[35]}"
    temp_f=$((temp * 9 / 5 + 32))
    temp_display=$(printf "%2dC(%3dF)" "${temp}" "${temp_f}")

    # Voltage and current.
    volt=$(awk "BEGIN {printf \"%.1f\", ${f[19]} / 10}")
    peakcur=$(awk "BEGIN {printf \"%.1f\", ${f[20]} / 10}")
    avgcur=$(awk "BEGIN {printf \"%.1f\", ${f[21]} / 10}")

    ################################################################################
    # Get site location and convert fixed SLT to UTC.
    #
    if ! get_location "${cid}"; then
        echo "ERROR: unable to obtain location/configuration for CID ${cid}" >&2
        return 1
    fi

    datetime_utc=$(date -u \
        -d "${datetime} ${LOCATION_UTC_OFFSET}:00" \
        '+%Y-%m-%d %H:%M:%S') || {
        echo "ERROR: unable to convert SLT to UTC for CID ${cid}" >&2
        return 1
    }

    ################################################################################
    # Calculate actual Sun position.
    #
    sun_position=$(calculate_sun_position \
        "${LOCATION_LAT}" \
        "${LOCATION_LON}" \
        "${datetime_utc}") || {
        echo "ERROR: unable to calculate Sun position for CID ${cid}" >&2
        return 1
    }

    read -r az el <<< "${sun_position}"

    ################################################################################
    # Output.
    #
    printf "${fmt1}" \
        "${datetime}" "${cid}" "${state}" "${az}" "${el}" \
        "${f[1]}" "${f[2]}" "${f[3]}" "${f[4]}" \
        "${volt}" "${peakcur}" "${avgcur}" "${temp_display}"

    printf "${fmt2}" \
        "$(bool "${f[5]}")" "$(bool "${f[6]}")" \
        "$(bool "${f[7]}")" "$(bool "${f[8]}")" \
        "$(bool "${f[9]}")" "$(bool "${f[10]}")" \
        "$(bool "${f[12]}")" "$(bool "${f[24]}")" \
        "$(bool "${f[23]}")" "$(bool "${f[34]}")" \
        "$(bool "${f[14]}")" "$(bool "${f[15]}")" \
        "$(bool "${f[16]}")" "$(bool "${f[17]}")" \
        "$(bool "${f[18]}")" "${f[13]}"

    printf "${fmt3}" \
        "${f[25]}" "${f[26]}" "${f[27]}" "${f[28]}" \
        "${f[29]}" "${f[22]}" "${f[30]}" "${f[31]}" \
        "${f[32]}" "${f[33]}"

    printf '\n'

    return 0
}

################################################################################
# Calculate Sun azimuth and elevation.
#
# Input:
#
#   latitude
#   longitude
#   UTC timestamp: YYYY-MM-DD HH:MM:SS
#
# Output:
#
#   azimuth elevation
#
# Azimuth is measured clockwise from North.
# Elevation is degrees above the horizon and may be negative.
#
calculate_sun_position() {
    local lat="$1"
    local lon="$2"
    local utc="$3"

    awk -v lat="${lat}" -v lon="${lon}" -v utc="${utc}" '
    function rad(x)    { return x * pi / 180 }
    function deg(x)    { return x * 180 / pi }
    function tan(x)    { return sin(x) / cos(x) }

    function asin(x) {
        if (x > 1)  x=1
        if (x < -1) x=-1
        return atan2(x, sqrt(1-x*x))
    }

    function acos(x) {
        if (x > 1)  x=1
        if (x < -1) x=-1
        return atan2(sqrt(1-x*x), x)
    }

    function mod(x,y) {
        return x-y*int(x/y)
    }

    function norm360(x) {
        x=mod(x,360)
        return x < 0 ? x+360 : x
    }

    BEGIN {
        pi=3.14159265358979323846

        # Parse UTC timestamp.
        split(utc,d,/[- :]/)

        year=d[1]
        month=d[2]
        day=d[3]
        hour=d[4]
        minute=d[5]
        second=d[6]

        # Julian Day.
        if (month <= 2) {
            yy=year-1
            mm=month+12
        } else {
            yy=year
            mm=month
        }

        A=int(yy/100)
        B=2-A+int(A/4)

        JD=int(365.25*(yy+4716)) \
           +int(30.6001*(mm+1)) \
           +day+B-1524.5

        JD += (hour+minute/60+second/3600)/24

        # Julian centuries from J2000.0.
        T=(JD-2451545.0)/36525

        # Solar coordinates.
        L0=norm360(280.46646+T*(36000.76983+T*0.0003032))
        M=357.52911+T*(35999.05029-0.0001537*T)
        e=0.016708634-T*(0.000042037+0.0000001267*T)

        C=sin(rad(M))*(1.914602-T*(0.004817+0.000014*T)) \
         +sin(rad(2*M))*(0.019993-0.000101*T) \
         +sin(rad(3*M))*0.000289

        true_long=L0+C

        omega=125.04-1934.136*T

        lambda=true_long \
               -0.00569 \
               -0.00478*sin(rad(omega))

        eps0=23+(26+(21.448 \
            -T*(46.815+T*(0.00059-T*0.001813)))/60)/60

        eps=eps0+0.00256*cos(rad(omega))

        # Solar declination.
        decl=deg(asin(sin(rad(eps))*sin(rad(lambda))))

        # Equation of time, minutes.
        y=tan(rad(eps/2))
        y=y*y

        L0r=rad(L0)
        Mr=rad(M)

        Etime=4*deg( \
              y*sin(2*L0r) \
            - 2*e*sin(Mr) \
            + 4*e*y*sin(Mr)*cos(2*L0r) \
            - 0.5*y*y*sin(4*L0r) \
            - 1.25*e*e*sin(2*Mr) \
            )

        # True solar time.
        utc_minutes=hour*60+minute+second/60

        tst=utc_minutes+Etime+4*lon

        while (tst < 0)    tst+=1440
        while (tst >= 1440) tst-=1440

        # Solar hour angle.
        hour_angle=tst/4-180

        if (hour_angle < -180)
            hour_angle+=360

        latr=rad(lat)
        declr=rad(decl)
        har=rad(hour_angle)

        # Solar zenith.
        cosz=sin(latr)*sin(declr) \
            +cos(latr)*cos(declr)*cos(har)

        if (cosz > 1)  cosz=1
        if (cosz < -1) cosz=-1

        zenith=deg(acos(cosz))
        elevation=90-zenith

        # Azimuth, clockwise from North.
        azimuth=norm360( \
            deg(atan2( \
                sin(har), \
                cos(har)*sin(latr)-tan(declr)*cos(latr) \
            ))+180 \
        )

        printf "%.2f %.2f\n", azimuth,elevation
    }'

    return 0
}

################################################################################
# Initialize
#
SCRIPT_DIR="$(dirname -- "$(readlink -f -- "$0")")"
PARENT_DIR="$(dirname -- "$(dirname -- "$(readlink -f -- "$0")")")"
LOG_DIR="${PARENT_DIR}/solar-gateway-logs"
CONF_DIR="${LOG_DIR}/conf"

LOCATION_LAT=""
LOCATION_LON=""
LOCATION_UTC_OFFSET=""

declare -A STC_CONFIG_CACHE

TEMP_DIR=""

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
            echo "  -u gateway_user   Gateway user (default: pi)"
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

if [[ "$#" -gt 1 ]]; then
    echo "Error: too many arguments" >&2
    echo "Usage: $0 [-f] [-H lines] [-u gateway_user] [gateway_host]" >&2
    exit 1
fi

if [[ "$#" -eq 1 ]]; then
    GATEWAY_HOST="$1"
fi

if ${FOLLOW} && [[ -z "${GATEWAY_HOST}" ]]; then
    echo "Error: -f requires a gateway_host" >&2
    exit 1
fi

if ! [[ "${HEADER_INTERVAL}" =~ ^[0-9]+$ ]]; then
    echo "Error: -H requires a positive integer" >&2
    exit 1
fi

if [[ "${HEADER_INTERVAL}" -lt 1 ]]; then
    HEADER_INTERVAL=0
fi

################################################################################
# Enter main
#
main
echo ""
echo "[*] Script exited cleanly."
echo ""

