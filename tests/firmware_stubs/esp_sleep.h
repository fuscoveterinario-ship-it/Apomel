#pragma once
#include <cstdint>
#include "driver/rtc_io.h"
typedef enum { ESP_SLEEP_WAKEUP_UNDEFINED, ESP_SLEEP_WAKEUP_ALL, ESP_SLEEP_WAKEUP_EXT0, ESP_SLEEP_WAKEUP_EXT1, ESP_SLEEP_WAKEUP_TIMER } esp_sleep_wakeup_cause_t;
esp_sleep_wakeup_cause_t esp_sleep_get_wakeup_cause();
int esp_sleep_enable_ext0_wakeup(gpio_num_t, int); int esp_sleep_enable_timer_wakeup(uint64_t); void esp_deep_sleep_start();
