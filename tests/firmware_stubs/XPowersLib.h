#pragma once
#include "Wire.h"
#define AXP2101_SLAVE_ADDRESS 0x34
class XPowersPMU {
 public:
  bool begin(TwoWire&, uint8_t, int, int);
  bool disableDC3(); bool enableDC3(); bool setDC3Voltage(uint16_t);
  bool disableBLDO2(); bool enableBLDO2(); bool setBLDO2Voltage(uint16_t);
  void disableTSPinMeasure(); void enableBattVoltageMeasure();
  uint16_t getBattVoltage();
};
