#include "fpga_spi.h"

#include <stdbool.h>
#include <string.h>
#include "driver/gpio.h"
#include "fpga_pins.h"
#include "esp_log.h"

static const char *TAG = "FPGA_SPI";

esp_err_t fpga_spi_init(fpga_spi_t *spi)
{
    memset(spi, 0, sizeof(*spi));
    spi->host = SPI2_HOST;

    spi_bus_config_t bus = {
        .mosi_io_num = FPGA_SPI_MOSI_GPIO,
        .miso_io_num = FPGA_SPI_MISO_GPIO,
        .sclk_io_num = FPGA_SPI_SCLK_GPIO,
        .quadwp_io_num = -1,
        .quadhd_io_num = -1,
        .max_transfer_sz = FPGA_SPI_BURST_BYTES
    };
    spi_device_interface_config_t device = {
        .mode = 1,
        .spics_io_num = FPGA_SPI_CS_GPIO,
        .clock_speed_hz = 1000000,
        .queue_size = 1,
        .cs_ena_pretrans = 4,
        .cs_ena_posttrans = 1
    };

    esp_err_t err = spi_bus_initialize(spi->host, &bus, SPI_DMA_CH_AUTO);
    if (err != ESP_OK) return err;
    err = spi_bus_add_device(spi->host, &device, &spi->device);
    if (err != ESP_OK) {
        spi_bus_free(spi->host);
        return err;
    }
    ESP_LOGI(TAG, "SPI Mode 1 at 1 MHz initialized");
    return ESP_OK;
}

void fpga_spi_deinit(fpga_spi_t *spi)
{
    if (spi->device) spi_bus_remove_device(spi->device);
    spi_bus_free(spi->host);
    spi->device = NULL;
}

esp_err_t fpga_spi_read(fpga_spi_t *spi, uint8_t *buffer, size_t count)
{
    if (!buffer || count == 0 || count > FPGA_SPI_BURST_BYTES) {
        return ESP_ERR_INVALID_ARG;
    }
    spi_transaction_t tr = {
        .length = count * 8,
        .rxlength = count * 8,
        .rx_buffer = buffer
    };
    return spi_device_polling_transmit(spi->device, &tr);
}

void fpga_acquisition_init(void)
{
    gpio_config_t outputs = {
        .pin_bit_mask = (1ULL << FPGA_ACQ_ENABLE_GPIO) |
                        (1ULL << FPGA_RESET_GPIO),
        .mode = GPIO_MODE_OUTPUT
    };
    gpio_config_t input = {
        .pin_bit_mask = 1ULL << FPGA_DATA_READY_GPIO,
        .mode = GPIO_MODE_INPUT
    };
    ESP_ERROR_CHECK(gpio_config(&outputs));
    ESP_ERROR_CHECK(gpio_config(&input));
    gpio_set_level(FPGA_ACQ_ENABLE_GPIO, 0);
    gpio_set_level(FPGA_RESET_GPIO, 0);
}

void fpga_acquisition_start(void)
{
    gpio_set_level(FPGA_ACQ_ENABLE_GPIO, 1);
}

void fpga_acquisition_stop(void)
{
    gpio_set_level(FPGA_ACQ_ENABLE_GPIO, 0);
}

bool fpga_data_ready(void)
{
    return gpio_get_level(FPGA_DATA_READY_GPIO) != 0;
}
