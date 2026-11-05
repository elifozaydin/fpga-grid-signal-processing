# Goertzel: FPGA Hardware Validation

Result: All 126 recorded final recurrence states matched the MATLAB integer model in each of two reported nine-window captures. Mean absolute frequency-estimator disagreement with ROOT-MUSIC was 3.297 mHz for the parallel capture and 4.582 mHz for the capture labeled shared.

The FPGA outputs its CIC samples and the final `s1`/`s2` states for seven Goertzel bins. MATLAB replays the captured samples through an independent fixed-point reference, then computes and compares ENF (electrical network frequency) estimates. Exact-state agreement is a digital arithmetic check; frequency comparison is a separate signal-estimation check.

## Hardware configuration and results

Both banks use 32,000-sample nonoverlapping windows, bins 1944–1950, signed 16-bit inputs obtained by shifting CIC samples right by 16 bits, Q2.24 coefficients, and signed 36-bit states. The measured CIC sample rate was approximately 986.193294 samples/s.

| Measurement | Parallel capture | Shared-bank-labeled capture |
|---|---:|---:|
| Captured CIC samples | 295,695 | 295,695 |
| Complete Goertzel windows | 9 | 9 |
| Input sample range after scaling | −8,921 to +9,980 | −8,433 to +9,334 |
| Final states matching MATLAB | 126 / 126 | 126 / 126 |
| Maximum absolute state difference | 0 | 0 |
| Sample alignment offset | 0 | 0 |
| Mean absolute ENF difference vs ROOT-MUSIC | 3.2970 mHz | 4.5819 mHz |
| ENF difference RMSE | 3.7712 mHz | 4.8073 mHz |
| ENF estimate correlation (Pearson r) | 0.95099 | 0.96070 |

Each window generates 14 compared states: an `s1` and `s2` value for each of seven bins. Thus, 126/126 means all 14 final states matched in all nine windows, with no observed numerical difference.

Capture provenance: The second recording was identified as shared-bank hardware by the operator, but both RTL architectures use the same packet format. The binary does not independently identify the programmed bitstream. The two recordings also contain different real-world signals, so their ENF error figures are not a controlled parallel-versus-shared accuracy comparison.

## What the two checks establish

### 1. Bit-exact arithmetic

MATLAB decodes the captured 32-bit CIC outputs, applies the same signed scaling as RTL (`>>> 16`), searches for the sample-window alignment, and recomputes the seven Goertzel recurrences. It compares all captured final states exactly—not within a floating-point tolerance.

The recorded final states agree exactly with the integer reference for these inputs. This test does not separately verify every upstream valid-sample acceptance or exercise every reset and input condition.

### 2. Frequency-estimator agreement

Frequency is reconstructed from the recorded FPGA states using three-point interpolation of neighboring bin powers. ROOT-MUSIC, a higher-resolution MATLAB frequency-estimation algorithm, independently processes the same CIC sample windows. The comparison reports:

- MAE: average absolute difference between the two estimators, in millihertz (mHz)
- RMSE: similar difference metric that gives extra weight to larger mismatches
- Pearson r: whether the estimates rise and fall together; it does not measure their absolute agreement

These are differences between two estimators, not errors measured against a known true grid frequency.

## Validation implementation

The two architectures use the same MATLAB [capture parser](../../../matlab/hardware-validation/goertzel/parser.m) and [integer recurrence reference](../../../matlab/fixed-point-models/goertzel_fixed_model.m). The verification code separates [capture inspection](../../../matlab/hardware-validation/goertzel/capture_analysis.m), [exact-state comparison](../../../matlab/hardware-validation/goertzel/bitexact_hardware_validation.m), and [frequency-estimator comparison](../../../matlab/hardware-validation/goertzel/frequency_validation.m).

The measurements come from previously recorded validation runs; the newer three-function organization has not yet been rerun against both captures.

## Related engineering work

- [Parallel Goertzel RTL](../../../rtl/goertzel/parallel/goertzel_bank.v) · [Shared Goertzel RTL](../../../rtl/goertzel/shared/goertzel_bank_shared.v)
- [Design choices and arithmetic](../../../architecture-docs/goertzel.md)
- [Parallel/shared synthesis results](../../synthesis/README.md)
