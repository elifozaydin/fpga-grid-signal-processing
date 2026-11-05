#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include "esp_err.h"
#include "driver/spi_master.h"

#define FPGA_SPI_BURST_BYTES 512

typedef struct {
    spi_host_device_t host;
    spi_device_handle_t device;
} fpga_spi_t;

esp_err_t fpga_spi_init(fpga_spi_t *spi);
void fpga_spi_deinit(fpga_spi_t *spi);
esp_err_t fpga_spi_read(fpga_spi_t *spi, uint8_t *buffer, size_t count);
void fpga_acquisition_init(void);
void fpga_acquisition_start(void);
void fpga_acquisition_stop(void);
bool fpga_data_ready(void);
