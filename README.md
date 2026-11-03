# LibreSDR B220 Mini Raspberry Pi 5 Capture Setup

This repository bootstraps a Raspberry Pi 5 running **Raspberry Pi OS 64-bit** to capture IQ data from a LibreSDR B220 Mini using **Homebrew UHD only**. It does not install or use Conda/Radioconda.

## What setup installs/configures

- System build prerequisites and USB access rules through `apt`
- Homebrew for Linux (as the normal login user)
- UHD and C++ build dependencies through Homebrew
- Standard UHD firmware/images
- The B220 Mini FPGA binary from [bkerler/LibreSDR_UHD_B220_Mini_FPGA](https://github.com/bkerler/LibreSDR_UHD_B220_Mini_FPGA)
- `rx_samples_to_file`, compiled against the Homebrew UHD installation
- `~/.config/uhd.conf`, selecting the B220 Mini FPGA by device serial
- `~/.local/bin/collect_singlesdr_singlechannel`
- `~/.local/bin/collect_dualsdr_singlechannel`
- `~/.local/bin/collect_dualsdr_dualchannel`

The UHD example is built from the same UHD release as the Homebrew formula (currently pinned to 4.11.0.0 in this starter repository). A Homebrew update may require updating `UHD_VERSION` in `setup.sh` to match the installed formula.

## Supported baseline

- Raspberry Pi 5
- Raspberry Pi OS 64-bit (`arm64`)
- Network connection during setup
- Run setup as the normal user with `sudo` access; do **not** run `sudo ./setup.sh`
- LibreSDR B220 Mini connected by USB for the post-install hardware test

## Install on a fresh Pi

1. Flash Raspberry Pi OS 64-bit and complete first-boot setup.
2. Enable SSH (or use a local terminal).
3. Clone this repository:

   ```bash
   git clone https://github.com/YOUR_GITHUB_USER/YOUR_REPO.git
   cd YOUR_REPO
   chmod +x setup.sh collect_*sdr_*channel.sh
   ./setup.sh
   ```

4. Optionally assign distinct EEPROM names to connected SDRs when setup asks.
5. Connect the SDR and test:

   ```bash
   /home/linuxbrew/.linuxbrew/bin/uhd_find_devices
   /home/linuxbrew/.linuxbrew/bin/uhd_usrp_probe --args type=b200,name=<sdr_name>
   ```

Replace `<sdr_name>` with an EEPROM name visible in the discovery listing.

## Start a capture locally

```bash
~/.local/bin/collect_singlesdr_singlechannel <frequency_hz> <sample_rate_sps> <gain_db> <duration_s>
```

All collection settings are required at runtime: frequency in Hz, sample rate in samples/second, gain in dB, and duration in seconds. Each command then lists detected SDRs and prompts for the EEPROM SDR name(s).

```bash
~/.local/bin/collect_dualsdr_singlechannel <frequency_hz> <sample_rate_sps> <gain_db> <duration_s>
~/.local/bin/collect_dualsdr_dualchannel <frequency_hz> <sample_rate_sps> <gain_db> <duration_s>
```

Capture files and metadata are saved under `${B220_CAPTURE_DIR:-${B220_USB_MOUNT:-/mnt/usb-hdd}/sdr-captures}`. The IQ file is raw interleaved complex signed 16-bit I/Q (`sc16`/`short`), which is the default output type of `rx_samples_to_file`.

## Start a capture remotely over SSH

From your computer:

```bash
ssh <user>@<pi-host> '~/.local/bin/collect_singlesdr_singlechannel <frequency_hz> <sample_rate_sps> <gain_db> <duration_s>'
```

The IQ file remains on the Raspberry Pi. To copy a file back later, use `scp`, for example:

```bash
scp <user>@<pi-host>:sdr-captures/b220_YYYYMMDD_HHMMSS.iq .
```

## Important notes

- This starter setup has not been tested against your physical Pi/SDR in this environment. The first hardware probe is the acceptance test.
- The B220 Mini FPGA binary is downloaded from a third-party repository. The script checks that the file exists and is non-empty, but does not independently verify its cryptographic provenance.
- Homebrew is installed under `/home/linuxbrew/.linuxbrew`. On SSH sessions, scripts use absolute paths rather than depending on shell startup files.
- `setup.sh` installs the official UHD udev rules for Ettus B200 USB IDs. If your clone uses a different USB ID, `uhd_find_devices` may require a device-specific udev rule.
- The Pi's storage must have enough free space. At 200 kS/s, one channel, complex int16 and 10 seconds, a normal capture is about 8 MB.
- For sustained high-rate captures, USB mode, storage write speed, and dropped-sample reports matter. Check the capture output and `--stats` report.
