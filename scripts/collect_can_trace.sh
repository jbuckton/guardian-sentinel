#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/collect_can_trace.sh [output-directory] [can-interface]

Safely records one listen-only Orion Jr 2 CAN session and creates:
  - a candump log
  - a YAML metadata sidecar
  - SocketCAN statistics from before and after the capture

Defaults:
  output-directory: ./traces/field
  can-interface:    can0
EOF
}

if [[ ${1:-} == "-h" || ${1:-} == "--help" ]]; then
  usage
  exit 0
fi

output_dir=${1:-./traces/field}
can_interface=${2:-can0}

for command in ip candump timeout date; do
  if ! command -v "$command" >/dev/null 2>&1; then
    printf 'Required command not found: %s\n' "$command" >&2
    exit 1
  fi
done

if [[ $EUID -ne 0 ]] && ! command -v sudo >/dev/null 2>&1; then
  printf 'This script needs root privileges or the sudo command to configure SocketCAN.\n' >&2
  exit 1
fi

run_privileged() {
  if [[ $EUID -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

prompt() {
  local variable_name=$1
  local message=$2
  local default_value=${3:-}
  local value

  if [[ -n $default_value ]]; then
    read -r -p "$message [$default_value]: " value
    value=${value:-$default_value}
  else
    while [[ -z ${value:-} ]]; do
      read -r -p "$message: " value
    done
  fi

  printf -v "$variable_name" '%s' "$value"
}

yaml_quote() {
  local value=${1//\'/\'\'}
  printf "'%s'" "$value"
}

prompt pack_id "Pack identifier (or 'unconfirmed')" "unconfirmed"

# Pack model and cell count must be designer-confirmed / from the config export
# (ADR-010). Never invent them. When they are not yet confirmed, answer
# 'unconfirmed' — the capture is still valid raw evidence; the facts are filled
# in later from the Orion Jr 2 configuration export (data-collection.md Part B).
while true; do
  prompt pack_model "Pack model (48-10, 48-20, or 'unconfirmed')"
  [[ $pack_model == "48-10" || $pack_model == "48-20" || $pack_model == "unconfirmed" ]] && break
  printf "Pack model must be 48-10, 48-20, or unconfirmed.\n" >&2
done

while true; do
  prompt cell_count "Designer-confirmed cell count (or 'unconfirmed')"
  [[ $cell_count =~ ^[1-9][0-9]*$ || $cell_count == "unconfirmed" ]] && break
  printf "Cell count must be a positive whole number, or unconfirmed.\n" >&2
done

prompt orion_serial "Orion Jr 2 serial number"
prompt can_node_id "Orion Jr 2 CAN node ID"
prompt obd2_ecu_id "Configured OBD2 ECU ID (if known)" "unknown"
prompt thermistors "Thermistor count/placement (if known)" "unknown"

while true; do
  prompt operating_state "Operating state (startup, idle, charging, discharging, alarm)"
  case $operating_state in
    startup|idle|charging|discharging|alarm) break ;;
    *) printf 'Choose startup, idle, charging, discharging, or alarm.\n' >&2 ;;
  esac
done

while true; do
  prompt bitrate "CAN bitrate" "500000"
  [[ $bitrate =~ ^[1-9][0-9]*$ ]] && break
  printf 'Bitrate must be a positive whole number.\n' >&2
done

while true; do
  prompt duration_seconds "Capture duration in seconds" "180"
  [[ $duration_seconds =~ ^[1-9][0-9]*$ ]] && break
  printf 'Duration must be a positive whole number.\n' >&2
done

prompt capture_hardware "CAN capture hardware" "Raspberry Pi CM4 + Waveshare CM4 PoE 4G carrier + SocketCAN adapter"
prompt operator_name "Operator name"

while true; do
  prompt utility_connected "Was the Orion Utility connected during this capture? (yes/no)" "no"
  case $utility_connected in
    yes|no) break ;;
    *) printf 'Answer yes or no.\n' >&2 ;;
  esac
done

prompt notes "Notes" "none"

safe_pack_id=$(printf '%s' "$pack_id" | tr -cs '[:alnum:]_.-' '_')
captured_at_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)
filename_timestamp=$(date -u +%Y%m%dT%H%M%SZ)
base_name="candump-${filename_timestamp}-${safe_pack_id}-${operating_state}"

mkdir -p "$output_dir"
log_path="$output_dir/${base_name}.log"
metadata_path="${log_path}.meta.yaml"
stats_before_path="$output_dir/${base_name}.can-stats-before.txt"
stats_after_path="$output_dir/${base_name}.can-stats-after.txt"

printf '\nConfiguring %s at %s bit/s in listen-only mode...\n' "$can_interface" "$bitrate"
run_privileged ip link set "$can_interface" down 2>/dev/null || true
run_privileged ip link set "$can_interface" type can bitrate "$bitrate" listen-only on
if ! run_privileged ip link set "$can_interface" type can berr-reporting on; then
  printf 'Warning: %s does not support CAN error-frame reporting; continuing in listen-only mode.\n' "$can_interface" >&2
fi
run_privileged ip link set "$can_interface" up

interface_details=$(ip -details link show "$can_interface")
if ! grep -Eiq 'listen-only|LISTEN-ONLY' <<<"$interface_details"; then
  printf 'Refusing to capture: %s did not report listen-only mode.\n' "$can_interface" >&2
  run_privileged ip link set "$can_interface" down || true
  exit 1
fi

ip -details -statistics link show "$can_interface" >"$stats_before_path"

printf 'Recording %s for %s seconds. No CAN frames will be transmitted.\n' "$can_interface" "$duration_seconds"
set +e
timeout --signal=INT "${duration_seconds}s" candump -L "${can_interface},0:0,#FFFFFFFF" >"$log_path"
capture_status=$?
set -e

if [[ $capture_status -ne 0 && $capture_status -ne 124 && $capture_status -ne 130 ]]; then
  printf 'candump failed with exit code %s.\n' "$capture_status" >&2
  exit "$capture_status"
fi

ip -details -statistics link show "$can_interface" >"$stats_after_path"

ntp_synchronised=unknown
if command -v timedatectl >/dev/null 2>&1; then
  ntp_synchronised=$(timedatectl show --property=NTPSynchronized --value 2>/dev/null || printf 'unknown')
fi

utility_connected_yaml=false
[[ $utility_connected == yes ]] && utility_connected_yaml=true

{
  printf 'schema_version: 1\n'
  printf 'capture: %s\n' "$(yaml_quote "$(basename "$log_path")")"
  printf 'captured_at_utc: %s\n' "$(yaml_quote "$captured_at_utc")"
  printf 'pack_id: %s\n' "$(yaml_quote "$pack_id")"
  printf 'pack_model: %s\n' "$(yaml_quote "$pack_model")"
  printf 'designer_confirmed_cell_count: %s\n' "$cell_count"
  printf 'orion_jr2_serial: %s\n' "$(yaml_quote "$orion_serial")"
  printf 'can_node_id: %s\n' "$(yaml_quote "$can_node_id")"
  printf 'obd2_ecu_id: %s\n' "$(yaml_quote "$obd2_ecu_id")"
  printf 'thermistors: %s\n' "$(yaml_quote "$thermistors")"
  printf 'state: %s\n' "$(yaml_quote "$operating_state")"
  printf 'bitrate: %s\n' "$bitrate"
  printf 'interface: %s\n' "$(yaml_quote "$can_interface")"
  printf 'hardware: %s\n' "$(yaml_quote "$capture_hardware")"
  printf 'listen_only_confirmed: true\n'
  printf 'utility_connected: %s\n' "$utility_connected_yaml"
  printf 'capture_duration_seconds: %s\n' "$duration_seconds"
  printf 'ntp_synchronised: %s\n' "$(yaml_quote "$ntp_synchronised")"
  printf 'operator: %s\n' "$(yaml_quote "$operator_name")"
  printf 'can_stats_before: %s\n' "$(yaml_quote "$(basename "$stats_before_path")")"
  printf 'can_stats_after: %s\n' "$(yaml_quote "$(basename "$stats_after_path")")"
  printf 'notes: %s\n' "$(yaml_quote "$notes")"
} >"$metadata_path"

printf '\nCapture complete:\n'
printf '  CAN log:      %s\n' "$log_path"
printf '  Metadata:     %s\n' "$metadata_path"
printf '  Stats before: %s\n' "$stats_before_path"
printf '  Stats after:  %s\n' "$stats_after_path"

