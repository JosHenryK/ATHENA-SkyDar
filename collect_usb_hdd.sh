#!/usr/bin/env bash
set -Eeuo pipefail

# Usage: b220-capture [frequency_hz] [sample_rate_sps] [gain_db] [duration_s]
FREQ="${1:-5.1e9}"
RATE="${2:-2e5}"
GAIN="${3:-20}"
DURATION="${4:-10}"
# Store captures on the attached USB HDD at the same mount point used by
# the two-SDR collection script. Override B220_USB_MOUNT if mounted elsewhere.
USB_MOUNT="${B220_USB_MOUNT:-/mnt/usb-hdd}"
mountpoint -q "$USB_MOUNT" || {
  printf 'ERROR: USB HDD is not mounted at %s. Mount it first, or set B220_USB_MOUNT.\\n' "$USB_MOUNT" >&2
  exit 1
}
OUTDIR="${B220_CAPTURE_DIR:-${USB_MOUNT}/sdr-captures}"
STAMP="$(date +%Y%m%d_%H%M%S)"
OUT="${OUTDIR}/b220_${STAMP}.iq"
INSTALL_DIR="${HOME}/.local/lib/b220-capture"
RX_BIN="${INSTALL_DIR}/build/rx_samples_to_file"
UHD_BIN="/home/linuxbrew/.linuxbrew/bin"

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[[ -x "$RX_BIN" ]] || die "Capture executable not found: $RX_BIN. Run setup.sh first."
mkdir -p "$OUTDIR"

# Validate inputs as numeric values accepted by UHD; UHD will perform final validation.
for v in "$FREQ" "$RATE" "$GAIN" "$DURATION"; do
  [[ "$v" =~ ^[0-9]+([.][0-9]+)?([eE][+-]?[0-9]+)?$ ]] || die "Invalid numeric argument: $v"
done

echo "Frequency: $FREQ Hz"
echo "Sample rate: $RATE samples/s"
echo "Gain: $GAIN dB"
echo "Duration: $DURATION seconds"
echo "USB HDD mount point: $USB_MOUNT"\necho "Output: $OUT"

"$RX_BIN" \
  --freq "$FREQ" \
  --rate "$RATE" \
  --gain "$GAIN" \
  --duration "$DURATION" \
  --file "$OUT" \
  --stats

[[ -s "$OUT" ]] || die "Capture completed but output file is missing or empty."
cat > "${OUT}.txt" <<EOF
frequency_hz=$FREQ
sample_rate_sps=$RATE
gain_db=$GAIN
duration_seconds=$DURATION
file=$OUT
format=complex_int16_iq
EOF

echo
echo "Capture saved:"
ls -lh "$OUT" "${OUT}.txt"
