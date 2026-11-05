# MATLAB: DSP Design, Models, and Validation

MATLAB supported four stages of the FPGA development process, from selecting filter parameters to interpreting physical captures. The fixed-point models provide a software reference for checking the RTL at the arithmetic level.

| Area | Purpose |
|---|---|
| [DSP design](dsp-design/) | Compare CIC filter orders, choose Goertzel frequency bins, and study scaling and precision |
| [Fixed-point models](fixed-point-models/) | Model RTL-style integer arithmetic and test exact numerical behavior |
| [Hardware validation](hardware-validation/) | Parse FPGA–ESP32 recordings and check transport integrity, CIC response, and Goertzel final states |
| [ENF/ENV calibration](enf-env-calibration/) | Evaluate synthetic frequency correction and spectral-power compensation on historical grid recordings |

The hardware-validation scripts analyze physical FPGA captures; the ENF/ENV calibration experiments instead process historical audio recordings through MATLAB fixed-point models. They represent different kinds of evidence.

Design decisions are discussed in [architecture-docs](../architecture-docs/); measured outcomes are reported in [results](../results/).
