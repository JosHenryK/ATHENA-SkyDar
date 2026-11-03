#!/usr/bin/env bash
set -Eeuo pipefail

# Usage:
#   collect_dualsdr_singlechannel.sh <frequency_hz> <sample_rate_sps> <gain_db> <duration_s>
usage() {
  printf 'Usage: %s <frequency_hz> <sample_rate_sps> <gain_db> <duration_s>\n' "${0##*/}" >&2
  exit 2
}

[[ "$#" -eq 4 ]] || usage
FREQ="$1"
RATE="$2"
GAIN="$3"
DURATION="$4"

# Save captures to the attached USB HDD, not the local home directory.
# Mount the HDD at /mnt/usb-hdd, or set B220_USB_MOUNT to its actual mount point.
USB_MOUNT="${B220_USB_MOUNT:-/mnt/usb-hdd}"
mountpoint -q "$USB_MOUNT" || {
  printf 'ERROR: USB HDD is not mounted at %s. Mount it first, or set B220_USB_MOUNT.\\n' "$USB_MOUNT" >&2
  exit 1
}
OUTDIR="${B220_CAPTURE_DIR:-${USB_MOUNT}/sdr-captures}"
STAMP="$(date +%Y%m%d_%H%M%S)"
COLLECT_DIR="${OUTDIR}/${STAMP}"
INSTALL_DIR="${HOME}/.local/lib/b220-capture"
RX_BIN="${INSTALL_DIR}/build/rx_samples_to_file"
# Homebrew's UHD bottle does not ship the standard image package. Prefer the
# per-user image directory populated during setup so the script also works in
# non-interactive SSH sessions that do not source ~/.bashrc.
if [[ -z "${UHD_IMAGES_DIR:-}" && -d "${HOME}/.local/share/uhd/images" ]]; then
  export UHD_IMAGES_DIR="${HOME}/.local/share/uhd/images"
fi

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# Find UHD diagnostic tools on common Linuxbrew/Homebrew installations.
find_tool() {
  local tool="$1"
  if command -v "$tool" >/dev/null 2>&1; then
    command -v "$tool"
  elif [[ -x "/home/linuxbrew/.linuxbrew/bin/$tool" ]]; then
    printf '%s\n' "/home/linuxbrew/.linuxbrew/bin/$tool"
  elif [[ -x "/opt/homebrew/bin/$tool" ]]; then
    printf '%s\n' "/opt/homebrew/bin/$tool"
  elif [[ -x "/usr/local/bin/$tool" ]]; then
    printf '%s\n' "/usr/local/bin/$tool"
  else
    return 1
  fi
}

[[ -x "$RX_BIN" ]] || die "Capture executable not found: $RX_BIN. Run setup.sh first."

# Validate inputs as numeric values accepted by UHD; UHD performs final validation.
for v in "$FREQ" "$RATE" "$GAIN" "$DURATION"; do
  [[ "$v" =~ ^[0-9]+([.][0-9]+)?([eE][+-]?[0-9]+)?$ ]] || die "Invalid numeric argument: $v"
done

UHD_FIND="$(find_tool uhd_find_devices)" || die "uhd_find_devices not found. Ensure UHD is installed and on PATH."
echo "=== Attached UHD SDR diagnostic ==="
# Capture the normal, no-arguments discovery output. This is the discovery
# method confirmed to work on this host; do not run uhd_usrp_probe with
# serial-specific arguments, which currently fails on this setup.
DEVICE_LIST="$("$UHD_FIND")" || die "uhd_find_devices failed. Check USB connections and UHD installation."
printf '%s\n' "$DEVICE_LIST"
echo
read -r -p "Name for SDR 1 (as listed above): " SDR1_NAME
read -r -p "Name for SDR 2 (as listed above): " SDR2_NAME
[[ -n "$SDR1_NAME" ]] || die "SDR 1 name cannot be empty."
[[ -n "$SDR2_NAME" ]] || die "SDR 2 name cannot be empty."
[[ "$SDR1_NAME" != "$SDR2_NAME" ]] || die "Choose two different SDR names."

# Confirm both selected names appear in the successful discovery listing.
grep -Fq "name: $SDR1_NAME" <<< "$DEVICE_LIST" || die "SDR 1 name '$SDR1_NAME' was not listed by uhd_find_devices."
grep -Fq "name: $SDR2_NAME" <<< "$DEVICE_LIST" || die "SDR 2 name '$SDR2_NAME' was not listed by uhd_find_devices."

mkdir -p "$COLLECT_DIR"

echo
echo "=== Capture configuration ==="
echo "Frequency: $FREQ Hz"
echo "Sample rate: $RATE samples/s"
echo "Gain: $GAIN dB"
echo "Duration: $DURATION seconds"
echo "USB HDD mount point: $USB_MOUNT"
echo "Collection directory: $COLLECT_DIR"
echo "SDR 1 name: $SDR1_NAME"
echo "SDR 2 name: $SDR2_NAME"
echo
echo "Starting both captures in parallel..."

OUT1="${COLLECT_DIR}/libresdr_${SDR1_NAME}.iq"
OUT2="${COLLECT_DIR}/libresdr_${SDR2_NAME}.iq"
LOG1="${COLLECT_DIR}/libresdr_${SDR1_NAME}.log"
LOG2="${COLLECT_DIR}/libresdr_${SDR2_NAME}.log"

"$RX_BIN" \
  --args="type=b200,name=$SDR1_NAME" \
  --freq "$FREQ" \
  --rate "$RATE" \
  --gain "$GAIN" \
  --duration "$DURATION" \
  --file "$OUT1" \
  --stats >"$LOG1" 2>&1 &
PID1=$!

"$RX_BIN" \
  --args="type=b200,name=$SDR2_NAME" \
  --freq "$FREQ" \
  --rate "$RATE" \
  --gain "$GAIN" \
  --duration "$DURATION" \
  --file "$OUT2" \
  --stats >"$LOG2" 2>&1 &
PID2=$!

STATUS1=0
STATUS2=0
wait "$PID1" || STATUS1=$?
wait "$PID2" || STATUS2=$?

echo
echo "=== SDR 1 output (name=$SDR1_NAME; exit=$STATUS1) ==="
cat "$LOG1"
echo
echo "=== SDR 2 output (name=$SDR2_NAME; exit=$STATUS2) ==="
cat "$LOG2"

[[ "$STATUS1" -eq 0 ]] || die "Capture failed for SDR 1 ($SDR1_NAME); see $LOG1."
[[ "$STATUS2" -eq 0 ]] || die "Capture failed for SDR 2 ($SDR2_NAME); see $LOG2."
[[ -s "$OUT1" ]] || die "SDR 1 capture file is missing or empty: $OUT1"
[[ -s "$OUT2" ]] || die "SDR 2 capture file is missing or empty: $OUT2"

for pair in "1:$SDR1_NAME:$OUT1" "2:$SDR2_NAME:$OUT2"; do
  IFS=: read -r index name outfile <<< "$pair"
  cat > "${outfile}.txt" <<EOF
frequency_hz=$FREQ
sample_rate_sps=$RATE
gain_db=$GAIN
duration_seconds=$DURATION
sdr_name=$name
file=$outfile
format=complex_int16_iq
EOF
done

cat > "${COLLECT_DIR}/collection.txt" <<EOF
collection_timestamp=$STAMP
frequency_hz=$FREQ
sample_rate_sps=$RATE
gain_db=$GAIN
duration_seconds=$DURATION
sdr1_name=$SDR1_NAME
sdr2_name=$SDR2_NAME
capture_mode=parallel
format=complex_int16_iq
EOF

echo
echo "Capture saved in: $COLLECT_DIR"
ls -lh "$OUT1" "${OUT1}.txt" "$OUT2" "${OUT2}.txt" "${COLLECT_DIR}/collection.txt"
echo "Diagnostic logs: $LOG1 and $LOG2"
