#!/usr/bin/env bash
set -Eeuo pipefail

# Capture both RX channels from each of two LibreSDR B220 Minis (four IQ files
# total). UHD names the two outputs from each --file base as _ch0 and _ch1.
#
# Usage:
#   ./collect_two_libresdrs_dual_channel_usb_hdd.sh [frequency_hz] [sample_rate_sps] [gain_db] [duration_s]
FREQ="${1:-5.1e9}"
RATE="${2:-2e5}"
GAIN="${3:-20}"
DURATION="${4:-10}"

# Mount the HDD at /mnt/usb-hdd, or set B220_USB_MOUNT to its actual mount point.
USB_MOUNT="${B220_USB_MOUNT:-/mnt/usb-hdd}"
mountpoint -q "$USB_MOUNT" || {
  printf 'ERROR: USB HDD is not mounted at %s. Mount it first, or set B220_USB_MOUNT.\n' "$USB_MOUNT" >&2
  exit 1
}
OUTDIR="${B220_CAPTURE_DIR:-${USB_MOUNT}/sdr-captures}"
STAMP="$(date +%Y%m%d_%H%M%S)"
COLLECT_DIR="${OUTDIR}/${STAMP}"
INSTALL_DIR="${HOME}/.local/lib/b220-capture"
RX_BIN="${INSTALL_DIR}/build/rx_samples_to_file"

# Homebrew's UHD bottle does not ship the standard image package. Prefer the
# per-user image directory populated during setup so this works over SSH too.
if [[ -z "${UHD_IMAGES_DIR:-}" && -d "${HOME}/.local/share/uhd/images" ]]; then
  export UHD_IMAGES_DIR="${HOME}/.local/share/uhd/images"
fi

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

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

for value in "$FREQ" "$RATE" "$GAIN" "$DURATION"; do
  [[ "$value" =~ ^[0-9]+([.][0-9]+)?([eE][+-]?[0-9]+)?$ ]] || die "Invalid numeric argument: $value"
done

UHD_FIND="$(find_tool uhd_find_devices)" || die "uhd_find_devices not found. Ensure UHD is installed and on PATH."
echo "=== Attached UHD SDR diagnostic ==="
DEVICE_LIST="$("$UHD_FIND")" || die "uhd_find_devices failed. Check USB connections and UHD installation."
printf '%s\n' "$DEVICE_LIST"
echo
read -r -p "Name for SDR 1 (as listed above): " SDR1_NAME
read -r -p "Name for SDR 2 (as listed above): " SDR2_NAME

[[ -n "$SDR1_NAME" ]] || die "SDR 1 name cannot be empty."
[[ -n "$SDR2_NAME" ]] || die "SDR 2 name cannot be empty."
[[ "$SDR1_NAME" != "$SDR2_NAME" ]] || die "Choose two different SDR names."
grep -Fq "name: $SDR1_NAME" <<< "$DEVICE_LIST" || die "SDR 1 name '$SDR1_NAME' was not listed by uhd_find_devices."
grep -Fq "name: $SDR2_NAME" <<< "$DEVICE_LIST" || die "SDR 2 name '$SDR2_NAME' was not listed by uhd_find_devices."

mkdir -p "$COLLECT_DIR"

OUT1_BASE="${COLLECT_DIR}/libresdr_${SDR1_NAME}.iq"
OUT2_BASE="${COLLECT_DIR}/libresdr_${SDR2_NAME}.iq"
OUT1_CH0="${COLLECT_DIR}/libresdr_${SDR1_NAME}_ch0.iq"
OUT1_CH1="${COLLECT_DIR}/libresdr_${SDR1_NAME}_ch1.iq"
OUT2_CH0="${COLLECT_DIR}/libresdr_${SDR2_NAME}_ch0.iq"
OUT2_CH1="${COLLECT_DIR}/libresdr_${SDR2_NAME}_ch1.iq"
LOG1="${COLLECT_DIR}/libresdr_${SDR1_NAME}.log"
LOG2="${COLLECT_DIR}/libresdr_${SDR2_NAME}.log"

echo
echo "=== Quad-capture configuration ==="
echo "Frequency: $FREQ Hz"
echo "Sample rate: $RATE samples/s per channel"
echo "Gain: $GAIN dB"
echo "Duration: $DURATION seconds"
echo "USB HDD mount point: $USB_MOUNT"
echo "Collection directory: $COLLECT_DIR"
echo "SDR 1 name: $SDR1_NAME (channels 0, 1)"
echo "SDR 2 name: $SDR2_NAME (channels 0, 1)"
echo
echo "Starting both two-channel captures in parallel..."

"$RX_BIN" \
  --args="type=b200,name=$SDR1_NAME" \
  --freq "$FREQ" \
  --rate "$RATE" \
  --gain "$GAIN" \
  --duration "$DURATION" \
  --channels "0,1" \
  --file "$OUT1_BASE" \
  --stats >"$LOG1" 2>&1 &
PID1=$!

"$RX_BIN" \
  --args="type=b200,name=$SDR2_NAME" \
  --freq "$FREQ" \
  --rate "$RATE" \
  --gain "$GAIN" \
  --duration "$DURATION" \
  --channels "0,1" \
  --file "$OUT2_BASE" \
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
for output in "$OUT1_CH0" "$OUT1_CH1" "$OUT2_CH0" "$OUT2_CH1"; do
  [[ -s "$output" ]] || die "Capture file is missing or empty: $output"
done

write_metadata() {
  local sdr_index="$1" sdr_name="$2" channel="$3" outfile="$4"
  cat > "${outfile}.txt" <<EOF
frequency_hz=$FREQ
sample_rate_sps=$RATE
gain_db=$GAIN
duration_seconds=$DURATION
sdr_index=$sdr_index
sdr_name=$sdr_name
channel=$channel
file=$outfile
format=complex_int16_iq
EOF
}

write_metadata 1 "$SDR1_NAME" 0 "$OUT1_CH0"
write_metadata 1 "$SDR1_NAME" 1 "$OUT1_CH1"
write_metadata 2 "$SDR2_NAME" 0 "$OUT2_CH0"
write_metadata 2 "$SDR2_NAME" 1 "$OUT2_CH1"

cat > "${COLLECT_DIR}/collection.txt" <<EOF
collection_timestamp=$STAMP
frequency_hz=$FREQ
sample_rate_sps=$RATE
gain_db=$GAIN
duration_seconds=$DURATION
sdr1_name=$SDR1_NAME
sdr1_channels=0,1
sdr2_name=$SDR2_NAME
sdr2_channels=0,1
capture_mode=two_sdrs_parallel_two_channels_each
format=complex_int16_iq
EOF

echo
echo "Quad capture saved in: $COLLECT_DIR"
ls -lh "$OUT1_CH0" "${OUT1_CH0}.txt" "$OUT1_CH1" "${OUT1_CH1}.txt" \
  "$OUT2_CH0" "${OUT2_CH0}.txt" "$OUT2_CH1" "${OUT2_CH1}.txt" \
  "${COLLECT_DIR}/collection.txt"
echo "Diagnostic logs: $LOG1 and $LOG2"
