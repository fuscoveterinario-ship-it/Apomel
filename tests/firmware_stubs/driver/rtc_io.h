#pragma once
typedef int gpio_num_t;
int rtc_gpio_pulldown_en(gpio_num_t); int gpio_hold_en(gpio_num_t); int gpio_hold_dis(gpio_num_t); void gpio_deep_sleep_hold_en();
