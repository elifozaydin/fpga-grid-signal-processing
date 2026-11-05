#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"
#include "freertos/task.h"

#define LOGGER_BUFFER_COUNT 64
#define LOGGER_BUFFER_BYTES 512

typedef struct {
    uint8_t *data;
    size_t len;
} logger_message_t;

typedef struct {
    QueueHandle_t free_q;
    QueueHandle_t full_q;
    TaskHandle_t owner;
    void *file;
    volatile bool write_failed;
    uint64_t bytes_written;
    uint32_t buffers_written;
} sd_logger_t;

bool sd_logger_start(sd_logger_t *ctx, const char *path);
bool sd_logger_get_buffer(sd_logger_t *ctx, uint8_t **buffer);
bool sd_logger_submit(sd_logger_t *ctx, uint8_t *buffer, size_t len);
bool sd_logger_stop(sd_logger_t *ctx);
