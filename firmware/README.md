# ESP32 Firmware: SPI Acquisition and SD Logging

This ESP-IDF application captures FPGA-generated binary packets over SPI and stores the byte stream on an SD card. The FPGA handles packet formation and FIFO buffering; the ESP32 controls acquisition, receives data, and records it for offline MATLAB analysis.

```text
FPGA FIFO → SPI slave → ESP32 SPI master → DMA receive buffers
                                         → FreeRTOS SD writer → SD card
```

| Component | Role |
|---|---|
| [main.c](main/main.c) | Acquisition control, 512-byte SPI bursts, FIFO drain and shutdown |
| [fpga_spi.c](main/fpga_spi.c) | SPI Mode 1 at 1 MHz, DMA-backed reception, GPIO control |
| [sd_logger.c](main/sd_logger.c) | 64 reusable receive buffers, queued SD writes, 64 KiB file buffering |
| [fpga_pins.h](main/fpga_pins.h) | GPIO mapping and acquisition-duration configuration |

During acquisition, the FIFO's data-ready signal requests SPI reads. After acquisition stops, the firmware drains the remaining bytes and flushes the file. The unmodified capture is written to `/sdcard/fpga_capture.bin`.

This is a focused extraction of the recording firmware. Its present version has not been independently rebuilt and retested on the target hardware; configured GPIOs and SDMMC wiring remain board-specific.

For the interface decisions and measured packet integrity, see the [transport architecture](../architecture-docs/fpga_esp32_transport.md) and [hardware results](../results/hardware-validation/transport/README.md).
