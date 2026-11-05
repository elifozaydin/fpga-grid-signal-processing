idf_component_register(
    SRCS "main.c" "fpga_spi.c" "sd_logger.c"
    INCLUDE_DIRS "."
    REQUIRES driver esp_timer fatfs sdmmc
)
