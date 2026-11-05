// FPGA SPI acquisition and asynchronous SD-card recording.
#include <stdbool.h>
#include <stdint.h>
#include "esp_attr.h"
#include "esp_err.h"
#include "esp_log.h"
#include "esp_timer.h"
#include "esp_vfs_fat.h"
#include "sdmmc_cmd.h"
#include "driver/sdmmc_host.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "fpga_pins.h"
#include "fpga_spi.h"
#include "sd_logger.h"

static const char *TAG = "FPGA_RECORD";
DMA_ATTR static uint8_t tail_byte[4] __attribute__((aligned(4)));

void app_main(void)
{
    sdmmc_host_t host = SDMMC_HOST_DEFAULT();
    sdmmc_slot_config_t slot = SDMMC_SLOT_CONFIG_DEFAULT();
    slot.width = 1;
    esp_vfs_fat_sdmmc_mount_config_t mount = {
        .format_if_mount_failed = false,
        .max_files = 4,
        .allocation_unit_size = 16 * 1024
    };
    sdmmc_card_t *card = NULL;
    ESP_ERROR_CHECK(esp_vfs_fat_sdmmc_mount("/sdcard", &host, &slot, &mount, &card));

    fpga_acquisition_init();
    fpga_spi_t spi;
    ESP_ERROR_CHECK(fpga_spi_init(&spi));

    sd_logger_t logger;
    if (!sd_logger_start(&logger, "/sdcard/fpga_capture.bin")) {
        ESP_LOGE(TAG, "Unable to create recording");
        fpga_spi_deinit(&spi);
        esp_vfs_fat_sdcard_unmount("/sdcard", card);
        return;
    }

    ESP_ERROR_CHECK(spi_device_acquire_bus(spi.device, portMAX_DELAY));
    const int64_t end_us = esp_timer_get_time() +
                           (int64_t)FPGA_RECORD_SECONDS * 1000000LL;
    bool failed = false;
    uint32_t bursts = 0;
    uint32_t tail_bytes = 0;
    fpga_acquisition_start();

    // Receive 512-byte bursts when FPGA FIFO reaches prog_full.
    while (esp_timer_get_time() < end_us) {
        if (!fpga_data_ready()) {
            vTaskDelay(pdMS_TO_TICKS(1));
            continue;
        }
        uint8_t *buffer = NULL;
        if (!sd_logger_get_buffer(&logger, &buffer)) {
            ESP_LOGE(TAG, "SD writer backpressure timeout");
            failed = true;
            break;
        }
        esp_err_t err = fpga_spi_read(&spi, buffer, FPGA_SPI_BURST_BYTES);
        if (err != ESP_OK) {
            ESP_LOGE(TAG, "SPI burst failed: %s", esp_err_to_name(err));
            xQueueSend(logger.free_q, &buffer, portMAX_DELAY);
            failed = true;
            break;
        }
        if (!sd_logger_submit(&logger, buffer, FPGA_SPI_BURST_BYTES)) {
            ESP_LOGE(TAG, "SD buffer queue failed");
            xQueueSend(logger.free_q, &buffer, portMAX_DELAY);
            failed = true;
            break;
        }
        bursts++;
    }

    // Stop acquisition, then drain the final FIFO bytes.
    fpga_acquisition_stop();
    vTaskDelay(pdMS_TO_TICKS(1));

    uint8_t *tail_buffer = NULL;
    size_t tail_len = 0;
    while (fpga_data_ready() && !failed) {
        if (!tail_buffer && !sd_logger_get_buffer(&logger, &tail_buffer)) {
            failed = true;
            break;
        }
        if (fpga_spi_read(&spi, tail_byte, 1) != ESP_OK) {
            failed = true;
            break;
        }
        tail_buffer[tail_len++] = tail_byte[0];
        tail_bytes++;
        if (tail_len == LOGGER_BUFFER_BYTES) {
            if (!sd_logger_submit(&logger, tail_buffer, tail_len)) {
                failed = true;
                break;
            }
            tail_buffer = NULL;
            tail_len = 0;
        }
    }
    if (tail_buffer) {
        if (tail_len != 0 && !sd_logger_submit(&logger, tail_buffer, tail_len))
            failed = true;
        else if (tail_len == 0)
            xQueueSend(logger.free_q, &tail_buffer, portMAX_DELAY);
    }

    spi_device_release_bus(spi.device);
    bool logged = sd_logger_stop(&logger);
    ESP_LOGI(TAG, "bursts=%u tail_bytes=%u status=%s",
             (unsigned)bursts, (unsigned)tail_bytes,
             (!failed && logged) ? "OK" : "FAILED");
    fpga_spi_deinit(&spi);
    esp_vfs_fat_sdcard_unmount("/sdcard", card);
}
