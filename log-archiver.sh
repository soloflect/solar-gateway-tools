#!/bin/bash
################################################################################
# log-archiver.sh
#
# Archive log files from a Solaflect Gateway Raspberry Pi.
#
# The Gateway logs are copied to a local Raspberry Pi for long-term retention
# and subsequent analysis.  The Gateway is a Raspberry Pi 4B running the
# Stratosphere software.  The Stratosphere Gateway logs contain STC status
# records, as well as commands sent between Solaflect and the STC.
#
# The STC is the controller board inside the tracker enclosure.  It contains a
# PIC32 microcontroller and controls the two-axis solar tracker, including
# tracking the Sun's position.
#
# The following Gateway logs are archived:
#
#   /home/solaflect/stratosphere/log/stratosphere.log
#   /var/log/syslog
#   /var/log/messages
#   /var/log/debug
#   /var/log/user.log
#   /var/log/daemon.log
#   /var/log/kern.log
#   /var/log/auth.log
#
# Rotated Gateway logs are copied in reverse rotation-number order so that
# the oldest log receives the lowest local archive number.  For example:
#
#   syslog.7.gz  -> syslog-000000001.log.gz
#   syslog.6.gz  -> syslog-000000002.log.gz
#   ...
#   syslog.1     -> syslog-000000007.log
#
# SHA-256 hashes are maintained for each archived log.  A hash file contains
# the name of the corresponding local archive file.  Hashes provide a fast
# way to detect files that have already been archived and prevent duplicate
# log archives.
#
# The original Gateway file timestamps are preserved when the logs are copied.
#
# The Gateway's local_cid is read from stratosphere.conf and is used to keep
# logs from different Gateway devices in separate directories.
#
# The script is intended to run periodically, typically as a cron job.  It
# should be run using an SSH key that permits the local system to access the
# Gateway without interactive authentication.
#
# Example cron entry (every 10 hours and 5 minutes):
#
#   5 */10 * * * /home/pi/solar-gateway-tools/log-archiver.sh 192.168.1.100 >/home/pi/solar-gateway-logs/log-archiver.cron.log 2>&1
#
# You must first add your SSH key to the authorized_keys file for the pi user
# on the Gateway device.
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
   get_cid
   archive_log "/home/solaflect/stratosphere/log/stratosphere.log"
   archive_log "/var/log/syslog"
   archive_log "/var/log/messages"
   archive_log "/var/log/debug"
   archive_log "/var/log/user.log"
   archive_log "/var/log/daemon.log"
   archive_log "/var/log/kern.log"
   archive_log "/var/log/auth.log"

   return 0
}

get_cid() {
   get_conf

   GATEWAY_CID=$(
       sed -n 's/^[[:space:]]*local_cid[[:space:]]*=[[:space:]]*//p' \
           "${CONF_DIR}/stratosphere.conf"
   )

   if [ -z "${GATEWAY_CID}" ]; then
       echo "No local CID found on Gateway"
       return 1
   fi

   return 0
}

get_conf() {
( #BEGIN sub-shell
   local temp_dir=""
   local history_dir="${CONF_DIR}/history"
   local timestamp=""

   cleanup() {
      rm -rf "${temp_dir}"
   }

   trap 'cleanup; exit 130' INT
   trap 'cleanup; exit 143' TERM
   trap 'cleanup' EXIT

   mkdir -p "${CONF_DIR}"

   temp_dir=$(mktemp -d "${CONF_DIR}/temp.XXXXXX")

   scp -p \
      "${GATEWAY_USER}@${GATEWAY_HOST}:/home/solaflect/stratosphere/conf/stratosphere.conf" \
      "${temp_dir}/stratosphere.conf" || return 1

   scp -p \
      "${GATEWAY_USER}@${GATEWAY_HOST}:/home/solaflect/stratosphere/conf/stc.conf" \
      "${temp_dir}/stc.conf" || return 1

   timestamp=$(date '+%Y%m%d%H%M%S')

   for conf in stratosphere.conf stc.conf; do
      local current="${CONF_DIR}/${conf}"
      local downloaded="${temp_dir}/${conf}"
      local base="${conf%.conf}"

      # No current version exists yet.
      if [[ ! -f "${current}" ]]; then
         mv "${downloaded}" "${current}"
         continue
      fi

      # Configuration has not changed.
      if cmp -s "${current}" "${downloaded}"; then
         continue
      fi

      # Preserve the previous version.
      mkdir -p "${history_dir}"
      cp -p "${current}" \
         "${history_dir}/${base}-${timestamp}.conf"

      # Install the new version.
      mv "${downloaded}" "${current}"
   done

   rm -rf "${temp_dir}"
   trap - EXIT INT TERM

) #END sub-shell
   return 0
}

archive_log() {
( #BEGIN sub-shell
   [ -n "$1" ] || return 1

   local log_path="$1"
   local log_filename=""
   local log_name=""
   local log_extension=""
   local log_dir=""
   local hash_dir=""
   local temp_dir=""
   local temp_dir_2=""
   local file=""
   local filename=""
   local hash=""
   local hash_file=""
   local hash_file_temp=""
   local last=""
   local next=0
   local archive_name=""
   local archive_path=""
   local compression=""
   local i=0
   local max_retry=100

   log_filename=${log_path##*/}
   log_name=${log_filename%.*}

   if [ "$log_filename" = "$log_name" ]; then
       log_extension=""
   else
       log_extension=".${log_filename##*.}"
   fi

   log_dir="${LOG_DIR}/${GATEWAY_CID}/${log_name}"
   hash_dir="${log_dir}/hashes"

   mkdir -p "${log_dir}"
   mkdir -p "${hash_dir}"

   cleanup() {
      rm -rf "${temp_dir}" "${temp_dir_2}"
   }

   trap 'cleanup; exit 130' INT
   trap 'cleanup; exit 143' TERM
   trap 'cleanup' EXIT

   echo "Copying Gateway log: ${log_path}"

   # Check that the active log exists.
   if ! ssh "${GATEWAY_USER}@${GATEWAY_HOST}" \
       "test -f '${log_path}'"; then
       echo "Log does not exist: ${log_path}"
       return 0
   fi

   # Copy rotated logs twice and compare the copies.  This prevents a log
   # rotation occurring during the copy from producing an inconsistent set.
   while :; do
      temp_dir=$(mktemp -d "${LOG_DIR}/temp.XXXXXX")
      temp_dir_2=$(mktemp -d "${LOG_DIR}/temp2.XXXXXX")

      if scp -p \
         "${GATEWAY_USER}@${GATEWAY_HOST}:${log_path}.[0-9]*" \
         "${temp_dir}/" 2>/dev/null &&
         scp -p \
         "${GATEWAY_USER}@${GATEWAY_HOST}:${log_path}.[0-9]*" \
         "${temp_dir_2}/" 2>/dev/null
      then
         if diff -rq "${temp_dir}" "${temp_dir_2}" >/dev/null; then
            rm -rf "${temp_dir_2}"
            break
         fi
      fi

      rm -rf "${temp_dir}"
      rm -rf "${temp_dir_2}"

      if [ "${i}" -ge "${max_retry}" ]; then
         echo "Timed out waiting to copy rotated log from Gateway"
         return 1
      fi

      i=$((i + 1))
      sleep 5
   done

   # Copy the active log separately.
   scp -p \
      "${GATEWAY_USER}@${GATEWAY_HOST}:${log_path}" \
      "${temp_dir}/"

   # Process rotated logs from highest rotation number to lowest.
   while IFS= read -r filename; do
      file="${temp_dir}/${filename}"

      # Determine whether the rotated file is compressed.
      case "${filename}" in
         "${log_filename}".[0-9]*.gz)
            compression=".gz"
            ;;
         "${log_filename}".[0-9]*)
            compression=""
            ;;
         *)
            continue
            ;;
      esac

      # Calculate SHA-256 of the complete file.
      hash=$(sha256sum "${file}" | awk '{print tolower($1)}')
      hash_file="${hash_dir}/${hash}.sha256"

      # Fast duplicate check.
      if [ -f "${hash_file}" ]; then
         echo "Already archived: ${filename}"
         rm -f "${file}"
         continue
      fi

      # Find next archive number for this log type.
      last=$(
         find "${log_dir}" -maxdepth 1 -type f \
            -name "${log_name}-[0-9]*.log*" \
            -printf '%f\n' |
         sed -n \
            "s/^${log_name}-\([0-9]\{9\}\)\.log\(\.gz\)\?$/\1/p" |
         sort -n |
         tail -1
      )

      if [ -z "${last}" ]; then
         next=1
      else
         next=$((10#${last} + 1))
      fi

      archive_name=$(printf \
         "${log_name}-%09d.log%s" \
         "${next}" "${compression}")

      archive_path="${log_dir}/${archive_name}"

      echo "Archiving ${filename} -> ${archive_name}"

      # Store the relationship between hash and archive filename.
      hash_file_temp=$(mktemp "${hash_file}.XXXXXX")
      printf '%s\n' "${archive_name}" >"${hash_file_temp}"

      # Move the log into the permanent archive.
      mv "${file}" "${archive_path}"
      mv "${hash_file_temp}" "${hash_file}"

   done < <(
       find "${temp_dir}" -maxdepth 1 -type f \
           \( -name "${log_filename}.[0-9]*" \
              -o -name "${log_filename}.[0-9]*.gz" \) \
           -printf '%f\n' |
       sed -n 's/.*\.\([0-9][0-9]*\)\(\.gz\)\?$/\1 &/p' |
       sort -nr |
       cut -d' ' -f2-
   )

   # Replace the local active log with the current Gateway active log.
   # scp -p preserves the Gateway file timestamp.
   mv -f "${temp_dir}/${log_filename}" "${log_dir}/"

   rm -rf "${temp_dir}"
   trap - EXIT INT TERM

) #END sub-shell
return 0
}

################################################################################
# Initialize
#
PATH_CMD="$(readlink -f -- "$0")"
SCRIPT_DIR="$(dirname -- "$(readlink -f -- "$0")")"
PARENT_DIR="$(dirname -- "$(dirname -- "$(readlink -f -- "$0")")")"
LOG_DIR="${PARENT_DIR}/solar-gateway-logs"
CONF_DIR="${LOG_DIR}/conf"
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export PATH
set -e
#set -x #debug

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

