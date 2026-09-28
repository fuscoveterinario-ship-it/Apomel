#pragma once
#include "Arduino.h"
class TwoWire {
 public:
  bool begin(int, int) { return true; }
  void beginTransmission(uint8_t) {}
  size_t write(uint8_t) { return 1; }
  uint8_t endTransmission(bool = true) { return 0; }
  uint8_t requestFrom(uint8_t, uint8_t) { return 0; }
  int read() { return 0; }
};
extern TwoWire Wire;
