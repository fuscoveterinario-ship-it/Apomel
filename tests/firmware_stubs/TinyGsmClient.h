#pragma once
// Assinaturas copiadas de lib/TinyGSM (fork LILYGO) usadas pelo firmware.
#include "Arduino.h"
enum SimStatus { SIM_ERROR, SIM_READY, SIM_LOCKED };
enum RegStatus { REG_NO_RESULT = -1, REG_UNREGISTERED, REG_SEARCHING, REG_DENIED, REG_OK_HOME, REG_OK_ROAMING, REG_UNKNOWN };
class TinyGsm {
 public:
  explicit TinyGsm(HardwareSerial&) {}
  bool testAT(uint32_t = 10000L);
  SimStatus getSimStatus(uint32_t = 10000L);
  RegStatus getRegistrationStatus();
  int16_t getSignalQuality();
  bool setNetworkActive(String apn = "", bool useIPV6 = false);
  bool poweroff();
  bool enableGPS(int8_t = -1, uint8_t = 1);
  bool disableGPS(int8_t = -1, uint8_t = 0);
  bool getGPS(uint8_t*, float*, float*, float* = 0, float* = 0, int* = 0, int* = 0, float* = 0, int* = 0,
              int* = 0, int* = 0, int* = 0, int* = 0, int* = 0);
  bool sendSMS(const String&, const String&);
  bool https_begin(); void https_end();
  bool https_set_url(const String&, int = 0, bool = true);
  bool https_add_header(const char*, const char*);
  bool https_set_content_type(const char*);
  int https_post(const String&);
  String https_body();
};
