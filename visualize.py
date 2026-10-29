import numpy as np
import matplotlib.pyplot as plt

filename = "/Users/henry.kester/Desktop/dirty_collect.iq"
sample_rate = 200_000

# Read interleaved signed 16-bit I and Q
raw = np.fromfile(filename, dtype=np.int16)
iq = raw[0::2].astype(np.float32) + 1j * raw[1::2].astype(np.float32)

# Plot a spectrum from up to 1 million samples
iq = iq[:min(len(iq), 1_000_000)]
window = np.hanning(len(iq))
spectrum = np.fft.fftshift(np.fft.fft(iq * window))
freq = np.fft.fftshift(np.fft.fftfreq(len(iq), 1 / sample_rate))
power_db = 20 * np.log10(np.abs(spectrum) + 1e-12)

plt.plot(freq / 1e3, power_db)
plt.xlabel("Offset from 5.1 GHz center (kHz)")
plt.ylabel("Relative amplitude (dB)")
plt.title("LibreSDR IQ Capture")
plt.grid(True)
plt.tight_layout()
plt.show()