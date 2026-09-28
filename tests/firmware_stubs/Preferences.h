#pragma once
#include "Arduino.h"
class Preferences {
 public:
  bool begin(const char*, bool) { return true; }
  uint32_t getUInt(const char*, uint32_t d) { return d; }
  size_t putUInt(const char*, uint32_t) { return 4; }
  String getString(const char*, const String& d) { return d; }
  size_t putString(const char*, const String&) { return 0; }
};
