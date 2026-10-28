#!/usr/bin/env bash
set -Eeuo pipefail

# One-time setup for Raspberry Pi 5 / Raspberry Pi OS 64-bit.
# Run as the normal login user (NOT with sudo). The script invokes sudo
# only for apt packages and the system udev rule.

REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BREW_PREFIX="/home/linuxbrew/.linuxbrew"
BREW="${BREW_PREFIX}/bin/brew"
UHD_VERSION="4.11.0.0"
FPGA_REPO="https://github.com/bkerler/LibreSDR_UHD_B220_Mini_FPGA.git"
FPGA_DIR="${HOME}/LibreSDR_UHD_B220_Mini_FPGA"
INSTALL_DIR="${HOME}/.local/lib/b220-capture"
BIN_DIR="${HOME}/.local/bin"
CAPTURE_DIR="${HOME}/sdr-captures"
DOWNLOADER_VENV="${HOME}/.local/share/uhd-downloader-venv"

log() { printf '\n==> %s\n' "$*"; }
die() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"; }

[[ "$(id -u)" -ne 0 ]] || die "Run as your normal user, not with sudo."
[[ -r /etc/os-release ]] || die "Cannot identify Linux distribution."
# shellcheck disable=SC1091
source /etc/os-release
[[ "${ID:-}" == "raspbian" || "${ID:-}" == "debian" ]] || \
  echo "WARNING: This setup is designed for Raspberry Pi OS/Debian; detected ${ID:-unknown}."

ARCH="$(dpkg --print-architecture)"
[[ "$ARCH" == "arm64" ]] || die "A 64-bit OS (arm64) is required. Detected dpkg architecture: $ARCH. Install Raspberry Pi OS 64-bit first."

log "Installing Raspberry Pi OS system prerequisites"
sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
  build-essential procps curl file git ca-certificates \
  pkg-config cmake libusb-1.0-0 udev

if [[ ! -x "$BREW" ]]; then
  log "Installing Homebrew for Linux under ${BREW_PREFIX}"
  # Official Homebrew installer; it must run as the non-root login user.
  NONINTERACTIVE=1 /bin/bash -c \
    "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi

[[ -x "$BREW" ]] || die "Homebrew installer completed but $BREW was not found."
eval "$("$BREW" shellenv)"

# Make Homebrew available to future interactive and SSH login shells.
for rc in "${HOME}/.bashrc" "${HOME}/.profile"; do
  if [[ -f "$rc" ]] && ! grep -Fq 'linuxbrew/.linuxbrew/bin/brew shellenv' "$rc"; then
    printf '\n# Homebrew (Linux)\neval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"\n' >> "$rc"
  fi
done

log "Installing UHD and build dependencies with Homebrew (no Conda/Radioconda)"
brew update
brew install uhd boost cmake pkgconf

log "Preparing an isolated Python environment for the UHD image downloader"
# Homebrew's generated uhd_images_downloader launcher can contain a shebang
# pointing into a temporary build directory. Invoke the script with a stable
# virtual-environment interpreter instead, and install its missing requests
# dependency there (without modifying Homebrew's externally-managed Python).
BREW_PYTHON="$(command -v python3 || true)"
[[ -n "$BREW_PYTHON" && -x "$BREW_PYTHON" ]] || die "Python 3 was not found after loading Homebrew. Check the Homebrew UHD installation."
[[ "$BREW_PYTHON" == "${BREW_PREFIX}"/* ]] || die "Expected Homebrew-managed Python, but found: $BREW_PYTHON"
mkdir -p "$(dirname "$DOWNLOADER_VENV")"
if [[ ! -x "${DOWNLOADER_VENV}/bin/python" ]]; then
  "$BREW_PYTHON" -m venv "$DOWNLOADER_VENV"
fi
"${DOWNLOADER_VENV}/bin/python" -m pip install --disable-pip-version-check requests

log "Downloading standard UHD firmware/images"
"${DOWNLOADER_VENV}/bin/python" "$(brew --prefix)/bin/uhd_images_downloader"

log "Installing UHD USB permissions rule"
RULE_URL="https://raw.githubusercontent.com/EttusResearch/uhd/v${UHD_VERSION}/host/utils/uhd-usrp.rules"
TMP_RULE="$(mktemp)"
if curl -fsSL "$RULE_URL" -o "$TMP_RULE"; then
  sudo install -m 0644 "$TMP_RULE" /etc/udev/rules.d/uhd-usrp.rules
  sudo udevadm control --reload-rules
  sudo udevadm trigger
else
  echo "WARNING: Could not download UHD udev rules. USB permissions may need manual setup."
fi
rm -f "${TMP_RULE:-}"

log "Downloading the B220 Mini FPGA image"
if [[ ! -d "${FPGA_DIR}/.git" ]]; then
  git clone --depth 1 "$FPGA_REPO" "$FPGA_DIR"
else
  git -C "$FPGA_DIR" pull --ff-only || \
    echo "WARNING: Could not update existing FPGA repository; using its current contents."
fi
FPGA_IMAGE="${FPGA_DIR}/usrp_b210_fpga.bin"
[[ -s "$FPGA_IMAGE" ]] || die "B220 Mini FPGA image missing or empty: $FPGA_IMAGE"

log "Building UHD rx_samples_to_file example against Homebrew UHD"
mkdir -p "$INSTALL_DIR" "$BIN_DIR" "$CAPTURE_DIR"
SRC="${INSTALL_DIR}/rx_samples_to_file.cpp"
BUILD="${INSTALL_DIR}/build"
curl -fsSL \
  "https://raw.githubusercontent.com/EttusResearch/uhd/v${UHD_VERSION}/host/examples/rx_samples_to_file.cpp" \
  -o "$SRC"

cat > "${INSTALL_DIR}/CMakeLists.txt" <<'CMAKE'
cmake_minimum_required(VERSION 3.16)
project(b220_rx_samples_to_file LANGUAGES CXX)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
find_package(UHD REQUIRED)
find_package(Boost REQUIRED COMPONENTS program_options filesystem)
add_executable(rx_samples_to_file rx_samples_to_file.cpp)
target_include_directories(rx_samples_to_file PRIVATE ${UHD_INCLUDE_DIRS})
target_link_libraries(rx_samples_to_file PRIVATE ${UHD_LIBRARIES} Boost::program_options Boost::filesystem)
CMAKE

BREW_PREFIX_NOW="$(brew --prefix)"
rm -rf "$BUILD"
cmake -S "$INSTALL_DIR" -B "$BUILD" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_PREFIX_PATH="${BREW_PREFIX_NOW};$(brew --prefix uhd);$(brew --prefix boost)"
cmake --build "$BUILD" --parallel 2
[[ -x "${BUILD}/rx_samples_to_file" ]] || die "Failed to build rx_samples_to_file."

[[ -f "${REPO_DIR}/collect.sh" ]] || die "collect.sh was not found in the repository directory: ${REPO_DIR}"

log "Installing capture command"
install -m 0755 "${REPO_DIR}/collect.sh" "${BIN_DIR}/b220-capture"

# Persist the FPGA path and selected serial in UHD's per-user config.
SERIAL="${B220_SERIAL:-}"
if [[ -z "$SERIAL" ]]; then
  read -r -p "SDR serial number [MAE8DOY]: " SERIAL
  SERIAL="${SERIAL:-MAE8DOY}"
fi
[[ "$SERIAL" =~ ^[A-Za-z0-9._-]+$ ]] || die "Unexpected serial number format: $SERIAL"
mkdir -p "${HOME}/.config"
UHD_CONF="${HOME}/.config/uhd.conf"
if [[ -f "$UHD_CONF" ]]; then
  cp "$UHD_CONF" "${UHD_CONF}.backup.$(date +%Y%m%d%H%M%S)"
fi
cat > "$UHD_CONF" <<EOF
[serial=${SERIAL}]
fpga=${FPGA_IMAGE}
EOF

log "Checking UHD installation"
"$(brew --prefix)/bin/uhd_config_info" --version || true
"$(brew --prefix)/bin/uhd_find_devices" || true

echo
echo "Setup completed."
echo "Homebrew UHD: $(brew --prefix uhd)"
echo "Capture command: ${BIN_DIR}/b220-capture"
echo "Capture folder: ${CAPTURE_DIR}"
echo "Configured SDR serial: ${SERIAL}"
echo "FPGA image: ${FPGA_IMAGE}"
echo
echo "If the SDR was connected during setup, test it with:"
echo "  $(brew --prefix)/bin/uhd_usrp_probe --args serial=${SERIAL}"
echo
echo "Start a capture over SSH with:"
echo "  ssh <user>@<pi-host> '${BIN_DIR}/b220-capture 5.1e9 2e5 20 10'"
echo
echo "If the SDR was not connected, plug it in and run the probe command above."
