# Engineering Results

Experimental evidence for the FPGA signal-processing pipeline. Each report identifies the test conditions, measured outcomes, and what those outcomes establish.

| Report | Main evidence |
|---|---|
| [FPGA–ESP32 transport](hardware-validation/transport/README.md) | Packet sequencing and payload integrity in a physical FPGA-to-SD-card capture |
| [CIC decimator](hardware-validation/cic/README.md) | Measured frequency response and single-tone alias rejection versus theoretical predictions |
| [Goertzel hardware](hardware-validation/goertzel/README.md) | Exact FPGA/MATLAB recurrence-state comparisons and frequency-estimator agreement |
| [Parallel/shared synthesis](synthesis/README.md) | DSP, LUT, register, and arithmetic scheduling tradeoffs |
| [ENF/ENV calibration](enf-env-calibration/README.md) | Synthetic calibration and evaluation on historical recordings from four locations |

The hardware reports, standalone synthesis figures, and historical-recording MATLAB evaluations describe different experiments. For the engineering decisions behind them, see [architecture-docs](../architecture-docs/).
