#include "sd_logger.h"

#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include "esp_attr.h"
#include "esp_log.h"
#include "esp_timer.h"

#define FILE_BUFFER_BYTES (64 * 1024)
#define FLUSH_INTERVAL_US (5ULL * 1000000ULL)
#define BACKPRESSURE_WAIT_MS 20
#define BACKPRESSURE_RETRIES 5

static const char *TAG = "SD_LOGGER";
DMA_ATTR static uint8_t rx_pool[LOGGER_BUFFER_COUNT][LOGGER_BUFFER_BYTES] __attribute__((aligned(4)));
static uint8_t file_buffer[FILE_BUFFER_BYTES];

static void writer_task(void *arg)
{
    sd_logger_t *ctx = arg;
    FILE *fp = ctx->file;
    logger_message_t msg;
    uint64_t next_flush_us = esp_timer_get_time() + FLUSH_INTERVAL_US;

    while (xQueueReceive(ctx->full_q, &msg, portMAX_DELAY) == pdTRUE) {
        if (msg.data == NULL) break;

        size_t written = fwrite(msg.data, 1, msg.len, fp);
        ctx->bytes_written += written;
        if (written != msg.len) {
            ctx->write_failed = true;
            ESP_LOGE(TAG, "SD write failed: %u/%u", (unsigned)written, (unsigned)msg.len);
        }
        ctx->buffers_written++;
        if ((uint64_t)esp_timer_get_time() >= next_flush_us) {
            if (fflush(fp) != 0 || fsync(fileno(fp)) != 0) ctx->write_failed = true;
            next_flush_us = esp_timer_get_time() + FLUSH_INTERVAL_US;
        }
        xQueueSend(ctx->free_q, &msg.data, portMAX_DELAY);
    }

    if (fflush(fp) != 0 || fsync(fileno(fp)) != 0) ctx->write_failed = true;
    xTaskNotifyGive(ctx->owner);
    vTaskDelete(NULL);
}

bool sd_logger_start(sd_logger_t *ctx, const char *path)
{
    memset(ctx, 0, sizeof(*ctx));
    FILE *fp = fopen(path, "wb");
    if (!fp) {
        ESP_LOGE(TAG, "Cannot open %s", path);
        return false;
    }
    ctx->file = fp;
    setvbuf(fp, (char *)file_buffer, _IOFBF, sizeof(file_buffer));
    ctx->owner = xTaskGetCurrentTaskHandle();
    ctx->free_q = xQueueCreate(LOGGER_BUFFER_COUNT, sizeof(uint8_t *));
    ctx->full_q = xQueueCreate(LOGGER_BUFFER_COUNT + 1, sizeof(logger_message_t));
    if (!ctx->free_q || !ctx->full_q) goto fail;

    for (int i = 0; i < LOGGER_BUFFER_COUNT; i++) {
        uint8_t *buffer = rx_pool[i];
        xQueueSend(ctx->free_q, &buffer, portMAX_DELAY);
    }
    if (xTaskCreate(writer_task, "sd_writer", 12288, ctx,
                    uxTaskPriorityGet(NULL) + 1, NULL) != pdPASS) goto fail;
    return true;
fail:
    if (ctx->free_q) vQueueDelete(ctx->free_q);
    if (ctx->full_q) vQueueDelete(ctx->full_q);
    fclose(fp);
    memset(ctx, 0, sizeof(*ctx));
    return false;
}

bool sd_logger_get_buffer(sd_logger_t *ctx, uint8_t **buffer)
{
    for (int i = 0; i < BACKPRESSURE_RETRIES; i++) {
        if (xQueueReceive(ctx->free_q, buffer,
                          pdMS_TO_TICKS(BACKPRESSURE_WAIT_MS)) == pdTRUE)
            return true;
    }
    return false;
}

bool sd_logger_submit(sd_logger_t *ctx, uint8_t *buffer, size_t len)
{
    logger_message_t msg = {.data = buffer, .len = len};
    return xQueueSend(ctx->full_q, &msg, portMAX_DELAY) == pdTRUE;
}

bool sd_logger_stop(sd_logger_t *ctx)
{
    logger_message_t stop = {.data = NULL, .len = 0};
    xQueueSend(ctx->full_q, &stop, portMAX_DELAY);
    ulTaskNotifyTake(pdTRUE, portMAX_DELAY);
    bool ok = !ctx->write_failed;
    ESP_LOGI(TAG, "Recorded %llu bytes in %u buffers",
             (unsigned long long)ctx->bytes_written, (unsigned)ctx->buffers_written);
    if (fclose((FILE *)ctx->file) != 0) ok = false;
    vQueueDelete(ctx->free_q);
    vQueueDelete(ctx->full_q);
    memset(ctx, 0, sizeof(*ctx));
    return ok;
}
