// Pinos e recursos de cada placa suportada. A placa é escolhida no platformio.ini
// (ambiente t-a7670 ou t-sim7080g-s3). Valores conforme os exemplos oficiais da LILYGO.
#pragma once

#if defined(BOARD_T_SIM7080G_S3)
// ---------------------------------------------------------------------------
// LILYGO T-SIM7080G-S3: ESP32-S3 + SIM7080G (LTE Cat-M / NB-IoT + GNSS) + PMU AXP2101
// Protótipo de baixo consumo. Não tem 2G; GPS e rede não funcionam ao mesmo tempo.
// ---------------------------------------------------------------------------
#define BOARD_NAME           "T-SIM7080G-S3"
#define MODEM_BAUDRATE       115200
#define MODEM_RX_PIN         4    // ESP32 recebe do modem
#define MODEM_TX_PIN         5    // ESP32 envia ao modem
#define BOARD_MODEM_PWR_PIN  41
#define MODEM_DTR_PIN        42
#define MODEM_RING_PIN       3
#define PMU_SDA_PIN          15   // chip de energia AXP2101 (divide o barramento com o ADXL345)
#define PMU_SCL_PIN          7
#define PMU_IRQ_PIN          6
#define HAS_PMU              1
#define GNSS_EXCLUSIVE       1    // desliga os dados para usar o GPS
#define MODEM_GPS_ENABLE_GPIO  (-1)
#define MODEM_GPS_ENABLE_LEVEL (-1)

// ADXL345 (mesmo barramento I2C do chip de energia: endereços diferentes, sem conflito)
#define ACCEL_SDA_PIN        15
#define ACCEL_SCL_PIN        7
#define ACCEL_INT_PIN        8    // provisório: confirmar na foto da placa

// Balança HX711 (só na colmeia sentinela)
#define SCALE_DOUT_PIN       16   // provisório: confirmar na foto da placa
#define SCALE_SCK_PIN        17

#else
// ---------------------------------------------------------------------------
// LILYGO T-A7670SA R2: ESP32 + A7670SA (LTE Cat-1 + 2G + GNSS)
// Modelo das unidades de produção.
// ---------------------------------------------------------------------------
#define BOARD_T_A7670        1
#define BOARD_NAME           "T-A7670SA"
#define MODEM_BAUDRATE       115200
#define MODEM_DTR_PIN        25
#define MODEM_TX_PIN         26
#define MODEM_RX_PIN         27
#define BOARD_PWRKEY_PIN     4
#define BOARD_POWERON_PIN    12   // liga a alimentação do modem
#define MODEM_RESET_PIN      5
#define MODEM_RESET_LEVEL    HIGH
#define MODEM_RING_PIN       33
#define BOARD_BAT_ADC_PIN    35   // tensão da bateria (divisor por 2)
#define MODEM_POWERON_PULSE_WIDTH_MS 100
#define MODEM_GPS_ENABLE_GPIO  (-1)
#define MODEM_GPS_ENABLE_LEVEL (-1)

// ADXL345
#define ACCEL_SDA_PIN        21
#define ACCEL_SCL_PIN        22
#define ACCEL_INT_PIN        32   // INT1 do ADXL345: acorda a placa quando a caixa mexe

// Balança HX711 (só na colmeia sentinela)
#define SCALE_DOUT_PIN       18
#define SCALE_SCK_PIN        19
#endif
