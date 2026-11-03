#!/usr/bin/env bash
set -Eeuo pipefail

# Usage:
#   collect_singlesdr_singlechannel.sh <frequency_hz> <sample_rate_sps> <gain_db> <duration_s>
usage() {
  printf 'Usage: %s <frequency_hz> <sample_rate_sps> <gain_db> <duration_s>\n' "${0##*/}" >&2
  exit 2
}

[[ "$#" -eq 4 ]] || usage
FREQ="$1"
RATE="$2"
GAIN="$3"
DURATION="$4"
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

# Homebrew's UHD bottle does not ship the standard image package. Prefer the
# per-user image directory populated during setup so this works over SSH too.
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
mkdir -p "$OUTDIR"

# Validate inputs as numeric values accepted by UHD; UHD will perform final validation.
for v in "$FREQ" "$RATE" "$GAIN" "$DURATION"; do
  [[ "$v" =~ ^[0-9]+([.][0-9]+)?([eE][+-]?[0-9]+)?$ ]] || die "Invalid numeric argument: $v"
done

UHD_FIND="$(find_tool uhd_find_devices)" || die "uhd_find_devices not found. Ensure UHD is installed and on PATH."
echo "=== Attached UHD SDR diagnostic ==="
# Use ordinary discovery and select by the EEPROM name displayed there.
DEVICE_LIST="$("$UHD_FIND")" || die "uhd_find_devices failed. Check USB connections and UHD installation."
printf '%s\n' "$DEVICE_LIST"
echo
read -r -p "Name for SDR (as listed above): " SDR_NAME
[[ -n "$SDR_NAME" ]] || die "SDR name cannot be empty."
grep -Fq "name: $SDR_NAME" <<< "$DEVICE_LIST" || die "SDR name '$SDR_NAME' was not listed by uhd_find_devices."

echo "Frequency: $FREQ Hz"
echo "Sample rate: $RATE samples/s"
echo "Gain: $GAIN dB"
echo "Duration: $DURATION seconds"
echo "USB HDD mount point: $USB_MOUNT"
echo "SDR name: $SDR_NAME"
echo "Output: $OUT"

"$RX_BIN" \
  --args="type=b200,name=$SDR_NAME" \
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
sdr_name=$SDR_NAME
file=$OUT
format=complex_int16_iq
EOF

echo
echo "Capture saved:"
ls -lh "$OUT" "${OUT}.txt"
