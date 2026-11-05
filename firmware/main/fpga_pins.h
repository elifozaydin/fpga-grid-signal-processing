#pragma once

// ESP32 GPIO assignments for the FPGA SPI interface.
// Match these values to the actual board wiring.
#define FPGA_SPI_MOSI_GPIO     23
#define FPGA_SPI_MISO_GPIO     19
#define FPGA_SPI_SCLK_GPIO     18
#define FPGA_SPI_CS_GPIO        5
#define FPGA_ACQ_ENABLE_GPIO  26
#define FPGA_DATA_READY_GPIO  27
#define FPGA_RESET_GPIO       25

#define FPGA_RECORD_SECONDS   60
