#pragma once
// Assinaturas copiadas de lib/TinyGSM (fork LILYGO) usadas pelo firmware.
#include "Arduino.h"
enum SimStatus { SIM_ERROR, SIM_READY, SIM_LOCKED };
enum NetworkMode { MODEM_NETWORK_AUTO = 2, MODEM_NETWORK_LTE = 38 };
enum NetworkPreferred { MODEM_PREFERRED_CATM = 1, MODEM_PREFERRED_NB_IOT = 2, MODEM_PREFERRED_CATM_NBIOT = 3 };
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
  bool setNetworkMode(NetworkMode);
  bool setPreferredMode(NetworkPreferred);
  bool setNetworkDeactivate();
  template <typename... Args> void sendAT(Args...) {}
  int8_t waitResponse(uint32_t, String&);
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
