# Goertzel: Parallel vs. Shared Synthesis

Result: The shared seven-bin Goertzel bank used 4 DSP48E1 blocks instead of 28 (85.7% fewer), with a tradeoff in registers and processing cycles.

Both implementations perform the same fixed-point Goertzel recurrence for seven frequency bins. The parallel version has a separate datapath per bin; the shared version reuses arithmetic across bins over multiple clock cycles.

## Resource comparison

*Standalone post-synthesis utilization, Vivado 2024.2, Spartan-7 XC7S50 (`xc7s50csga324-1`).*

| Resource | Parallel | Shared | Shared versus parallel |
|---|---:|---:|---:|
| DSP48E1 | 28 | 4 | 85.7% fewer |
| Slice LUTs | 1,023 | 357 | 65.1% fewer |
| Slice registers | 1,009 | 1,629 | 61.4% more |
| CARRY4 | 140 | 20 | 85.7% fewer |
| Block RAM tiles | 0 | 0 | unchanged |

## Engineering interpretation

The shared bank spends approximately 23 clock cycles per accepted sample updating its seven bins, rather than supporting the parallel bank's one-sample-per-clock processing rate. In exchange, it substantially reduces DSP and LUT requirements, while adding register overhead for scheduling and retained state.

These figures compare isolated Goertzel banks after synthesis. They do not include the complete FPGA system, routing effects, maximum achievable frequency, or measured power consumption. Thus, the table supports a resource-cost comparison, not a blanket claim that the shared system is faster or more power-efficient.

## Examine the implementations

- [Parallel RTL](../../rtl/goertzel/parallel/goertzel_bank.v) · [Shared RTL](../../rtl/goertzel/shared/goertzel_bank_shared.v)
- [Architecture and tradeoff analysis](../../architecture-docs/goertzel.md)
- [FPGA Goertzel hardware measurements](../hardware-validation/goertzel/README.md)
