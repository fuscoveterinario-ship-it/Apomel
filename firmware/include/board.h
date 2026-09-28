// Pinos da LILYGO T-A7670 R2 (conforme utilities.h oficial da LILYGO)
// e do acelerômetro ADXL345 ligado pelos fios jumper (ver docs/ligacao-lilygo.png).
#pragma once

#define MODEM_BAUDRATE      115200
#define MODEM_DTR_PIN       25
#define MODEM_TX_PIN        26
#define MODEM_RX_PIN        27
#define BOARD_PWRKEY_PIN    4
#define BOARD_POWERON_PIN   12   // liga a alimentação do modem
#define MODEM_RESET_PIN     5
#define MODEM_RESET_LEVEL   HIGH
#define MODEM_RING_PIN      33
#define BOARD_BAT_ADC_PIN   35   // tensão da bateria (divisor por 2)
#define MODEM_POWERON_PULSE_WIDTH_MS 100
#define MODEM_GPS_ENABLE_GPIO  (-1)
#define MODEM_GPS_ENABLE_LEVEL (-1)

// ADXL345
#define ACCEL_SDA_PIN       21
#define ACCEL_SCL_PIN       22
#define ACCEL_INT_PIN       32   // INT1 do ADXL345: acorda a placa quando a caixa mexe
