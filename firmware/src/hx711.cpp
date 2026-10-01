#include "hx711.h"

#include <driver/rtc_io.h>

#include <algorithm>

static portMUX_TYPE hxMux = portMUX_INITIALIZER_UNLOCKED;

void HX711::begin(int doutPin, int sckPin) {
  dout_ = doutPin;
  sck_ = sckPin;
  gpio_hold_dis((gpio_num_t)sck_);  // estava preso em nível alto durante o sono
  pinMode(dout_, INPUT_PULLUP);     // sem balança ligada, DOUT fica alto e a leitura desiste
  pinMode(sck_, OUTPUT);
  digitalWrite(sck_, LOW);
}

bool HX711::readOne(int32_t& out, uint32_t timeoutMs) {
  uint32_t t0 = millis();
  while (digitalRead(dout_) == HIGH) {  // DOUT baixo = leitura pronta
    if (millis() - t0 > timeoutMs) return false;
    delay(1);
  }
  uint32_t v = 0;
  // SCK não pode ficar alto mais de 60 µs (o HX711 desligaria): sem interrupções aqui.
  portENTER_CRITICAL(&hxMux);
  for (int i = 0; i < 24; i++) {
    digitalWrite(sck_, HIGH);
    delayMicroseconds(1);
    v = (v << 1) | (uint32_t)digitalRead(dout_);
    digitalWrite(sck_, LOW);
    delayMicroseconds(1);
  }
  digitalWrite(sck_, HIGH);  // 25º pulso: próxima leitura no canal A, ganho 128
  delayMicroseconds(1);
  digitalWrite(sck_, LOW);
  delayMicroseconds(1);
  portEXIT_CRITICAL(&hxMux);
  if (v & 0x800000) v |= 0xFF000000;  // número negativo (24 bits)
  out = (int32_t)v;
  return true;
}

bool HX711::readMedian(int32_t& out, int samples) {
  if (dout_ < 0) return false;
  samples = constrain(samples, 1, 25);
  int32_t vals[25];
  int32_t v;
  // A primeira leitura depois de ligar leva ~400 ms e sai instável: descarta 2.
  for (int i = 0; i < 2; i++) {
    if (!readOne(v, 1000)) return false;
  }
  int n = 0;
  while (n < samples && readOne(v, 500)) vals[n++] = v;
  if (n < (samples + 1) / 2) return false;
  std::sort(vals, vals + n);
  out = vals[n / 2];
  return true;
}

void HX711::powerDown() {
  if (sck_ < 0) return;
  digitalWrite(sck_, HIGH);
  delayMicroseconds(80);
  gpio_hold_en((gpio_num_t)sck_);
}
