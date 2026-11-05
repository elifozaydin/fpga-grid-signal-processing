# RTL Implementation

Verilog modules for the Arty S7 acquisition, signal-processing, and FPGA–ESP32 transport system.

| Directory or file | Implementation |
|---|---|
| [preprocessing/](preprocessing/) | DC-offset removal and four-stage CIC decimation |
| [goertzel/parallel/](goertzel/parallel/) | Seven independent fixed-point Goertzel processing cores |
| [goertzel/shared/](goertzel/shared/) | Seven-bin Goertzel with a time-multiplexed arithmetic datapath |
| [transport/](transport/) | SPI slave for the FPGA–ESP32 streaming link |
| [goertzel_top_parallel.v](goertzel_top_parallel.v) | Integrated parallel Goertzel capture |
| [goertzel_top_shared.v](goertzel_top_shared.v) | Integrated shared Goertzel capture |
| [validation_only/](validation_only/) | Baseline and CIC integration tops, plus dedicated simulation and hardware-test tops |

### Validation-only tops

| File | Role |
|---|---|
| [base_top.v](validation_only/base_top.v) | Raw XADC capture and transport |
| [cic_top.v](validation_only/cic_top.v) | Offset removal, CIC, and transport |
| [goertzel_sim.v](validation_only/goertzel_sim.v) | Standalone simulation wrapper for the parallel Goertzel path |
| [transport_sim.v](validation_only/transport_sim.v) | Transport simulation with externally provided samples |
| [transport_hw.v](validation_only/transport_hw.v) | Physical transport test using an FPGA pattern generator |

The parallel Goertzel bank processes all bins concurrently; the shared bank trades throughput for reduced arithmetic-resource usage. For design rationale and integration considerations, see the [CIC](../architecture-docs/cic_decimator.md), [Goertzel](../architecture-docs/goertzel.md), and [transport](../architecture-docs/fpga_esp32_transport.md) architecture documents.
