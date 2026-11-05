# FPGA–ESP32 Transport: Hardware Validation

Result: 286,463 frames captured with no detected sequence, payload, or framing errors.

A dedicated Arty S7 hardware test replaced the ADC stream with eight known 12-bit sample patterns. The FPGA sent framed data through its asynchronous FIFO and SPI slave; the ESP32 received the stream and logged it to an SD card. This tests the physical data-transfer path without depending on analog acquisition or DSP calculations.

## Test setup

```text
FPGA pattern generator (1,000 frames/s)
  → 6-byte packet formatter → asynchronous FIFO → SPI slave
  → ESP32 SPI master → SD-card recording → MATLAB checks
```

Each frame contains a 20-bit incrementing sequence number, a 12-bit pattern value, and two framing bytes. MATLAB checks both the expected eight-pattern cycle and frame ordering. The sequence number helps detect missing and duplicated frames within the captured session.

## Measured results

| Check | Recorded result |
|---|---:|
| Frames decoded | 286,463 |
| Missing sequence numbers between received frames | 0 |
| Duplicate or backward sequence numbers | 0 |
| Unexpected 12-bit payloads | 0 |
| Skipped or misaligned bytes | 0 |
| Unexpected leading/trailing bytes | 0 |
| Initial sequence error | 0 |
| Overall validation | PASS |

The captured frames were continuous, correctly ordered, and matched the generated test pattern. This demonstrates no detected transport corruption in this recorded run; it is not a guarantee of error-free operation under every clock, load, or session condition.

## Verification sources

- [FPGA hardware test top](../../../rtl/top/validation_only/transport_hw.v) — deterministic input generator and transport integration
- [SPI slave RTL](../../../rtl/transport/spi_slave.v) and [ESP32 firmware](../../../firmware/main/) — transfer implementation
- [MATLAB capture parser](../../../matlab/hardware-validation/transport/parser.m) and [pattern checker](../../../matlab/hardware-validation/transport/synthetic_transport_validation.m) — integrity checks
- [Transport architecture](../../../architecture-docs/fpga_esp32_transport.md) — protocol, clock domains, and buffering decisions
