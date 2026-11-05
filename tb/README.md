# RTL Testbenches

Self-checking Verilog testbenches exercise fixed-point arithmetic, control sequencing, and transport behavior independently of the physical FPGA captures.

| Testbench | Primary checks |
|---|---|
| [tb_remove_avg.v](preprocessing/tb_remove_avg.v) | DC-offset calibration and signed centered-sample output |
| [tb_cic_decimator.v](preprocessing/tb_cic_decimator.v) | Decimation timing, modulo arithmetic, valid gaps, reset, and numerical comparison |
| [tb_goertzel_parallel.v](goertzel/tb_goertzel_parallel.v) | Seven-bin recurrence states, scaling, window boundaries, and output timing |
| [tb_goertzel_shared.v](goertzel/tb_goertzel_shared.v) | Shared arithmetic recurrence, sample-ready handshake, window publication, and reset |
| [tb_spi_slave.v](transport/tb_spi_slave.v) | SPI slave data sequencing and interface behavior |
| [tb_transport_integration.v](transport/tb_transport_integration.v) | Packet formatting and transport integration with synthetic samples |

These tests establish the behavior exercised in RTL simulation; the [hardware-validation reports](../results/hardware-validation/) separately document measured FPGA–ESP32 captures. The [architecture documents](../architecture-docs/) describe the corresponding design choices.
