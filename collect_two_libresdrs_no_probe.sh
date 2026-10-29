#!/usr/bin/env bash
set -Eeuo pipefail

# Usage:
#   ./collect.sh [frequency_hz] [sample_rate_sps] [gain_db] [duration_s]
# Defaults match the original single-SDR capture script.
FREQ="${1:-5.1e9}"
RATE="${2:-2e5}"
GAIN="${3:-20}"
DURATION="${4:-10}"

OUTDIR="${B220_CAPTURE_DIR:-${HOME}/sdr-captures}"
STAMP="$(date +%Y%m%d_%H%M%S)"
COLLECT_DIR="${OUTDIR}/${STAMP}"
INSTALL_DIR="${HOME}/.local/lib/b220-capture"
RX_BIN="${INSTALL_DIR}/build/rx_samples_to_file"

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
read -r -p "Serial number for SDR 1 (as listed above): " SERIAL1
read -r -p "Serial number for SDR 2 (as listed above): " SERIAL2

[[ -n "$SERIAL1" ]] || die "SDR 1 serial number cannot be empty."
[[ -n "$SERIAL2" ]] || die "SDR 2 serial number cannot be empty."
[[ "$SERIAL1" != "$SERIAL2" ]] || die "Choose two different serial numbers."

# Confirm both selected serials appear in the successful discovery listing.
# This avoids the failing serial-specific uhd_usrp_probe calls.
grep -Fq "serial: $SERIAL1" <<< "$DEVICE_LIST" || die "SDR 1 serial '$SERIAL1' was not listed by uhd_find_devices."
grep -Fq "serial: $SERIAL2" <<< "$DEVICE_LIST" || die "SDR 2 serial '$SERIAL2' was not listed by uhd_find_devices."

mkdir -p "$COLLECT_DIR"

echo
echo "=== Capture configuration ==="
echo "Frequency: $FREQ Hz"
echo "Sample rate: $RATE samples/s"
echo "Gain: $GAIN dB"
echo "Duration: $DURATION seconds"
echo "Collection directory: $COLLECT_DIR"
echo "SDR 1 serial: $SERIAL1"
echo "SDR 2 serial: $SERIAL2"
echo
echo "Starting both captures in parallel..."

OUT1="${COLLECT_DIR}/libresdr_${SERIAL1}.iq"
OUT2="${COLLECT_DIR}/libresdr_${SERIAL2}.iq"
LOG1="${COLLECT_DIR}/libresdr_${SERIAL1}.log"
LOG2="${COLLECT_DIR}/libresdr_${SERIAL2}.log"

"$RX_BIN" \
  --args="serial=$SERIAL1" \
  --freq "$FREQ" \
  --rate "$RATE" \
  --gain "$GAIN" \
  --duration "$DURATION" \
  --file "$OUT1" \
  --stats >"$LOG1" 2>&1 &
PID1=$!

"$RX_BIN" \
  --args="serial=$SERIAL2" \
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
echo "=== SDR 1 output (serial=$SERIAL1; exit=$STATUS1) ==="
cat "$LOG1"
echo
echo "=== SDR 2 output (serial=$SERIAL2; exit=$STATUS2) ==="
cat "$LOG2"

[[ "$STATUS1" -eq 0 ]] || die "Capture failed for SDR 1 ($SERIAL1); see $LOG1."
[[ "$STATUS2" -eq 0 ]] || die "Capture failed for SDR 2 ($SERIAL2); see $LOG2."
[[ -s "$OUT1" ]] || die "SDR 1 capture file is missing or empty: $OUT1"
[[ -s "$OUT2" ]] || die "SDR 2 capture file is missing or empty: $OUT2"

for pair in "1:$SERIAL1:$OUT1" "2:$SERIAL2:$OUT2"; do
  IFS=: read -r index serial outfile <<< "$pair"
  cat > "${outfile}.txt" <<EOF
frequency_hz=$FREQ
sample_rate_sps=$RATE
gain_db=$GAIN
duration_seconds=$DURATION
serial_number=$serial
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
sdr1_serial=$SERIAL1
sdr2_serial=$SERIAL2
capture_mode=parallel
format=complex_int16_iq
EOF

echo
echo "Capture saved in: $COLLECT_DIR"
ls -lh "$OUT1" "${OUT1}.txt" "$OUT2" "${OUT2}.txt" "${COLLECT_DIR}/collection.txt"
echo "Diagnostic logs: $LOG1 and $LOG2"
