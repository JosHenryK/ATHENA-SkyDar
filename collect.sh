#!/usr/bin/env bash
set -Eeuo pipefail

# Usage: b220-capture [frequency_hz] [sample_rate_sps] [gain_db] [duration_s]
FREQ="${1:-5.1e9}"
RATE="${2:-2e5}"
GAIN="${3:-20}"
DURATION="${4:-10}"
OUTDIR="${B220_CAPTURE_DIR:-${HOME}/sdr-captures}"
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
echo "Output: $OUT"

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
