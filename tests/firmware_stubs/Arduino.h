// Declarações mínimas para checar a sintaxe do firmware no PC (não executa).
#pragma once
#include <cstdint>
#include <cstring>
#include <cstdio>
#include <cstdarg>
#include <cmath>
#include <string>
#include <algorithm>
#define HIGH 1
#define LOW 0
#define OUTPUT 1
#define RTC_DATA_ATTR
#define SERIAL_8N1 0
#ifndef M_PI
#define M_PI 3.14159265358979
#endif
using std::min; using std::max;
template <class T> T constrain(T x, T a, T b) { return x < a ? a : (x > b ? b : x); }
class String {
  std::string s;
 public:
  String() {}
  String(const char* c) : s(c ? c : "") {}
  String(const std::string& x) : s(x) {}
  const char* c_str() const { return s.c_str(); }
  unsigned length() const { return s.size(); }
  bool isEmpty() const { return s.empty(); }
  String& operator+=(const String& o) { s += o.s; return *this; }
  String& operator+=(const char* o) { s += o; return *this; }
  bool operator!=(const String& o) const { return s != o.s; }
  int indexOf(char c, unsigned from = 0) const { auto p = s.find(c, from); return p == std::string::npos ? -1 : (int)p; }
  String substring(unsigned a, unsigned b) const { return String(s.substr(a, b - a)); }
  void trim() {}
};
struct HardwareSerial {
  void begin(unsigned long, int = 0, int = 0, int = 0) {}
  void printf(const char*, ...) {}
  void flush() {}
};
extern HardwareSerial Serial, Serial1;
void pinMode(int, int); void digitalWrite(int, int); void delay(unsigned long);
unsigned long millis(); uint32_t analogReadMilliVolts(int);
size_t strlcpy(char*, const char*, size_t);
#define INPUT_PULLUP 5
int digitalRead(int); void delayMicroseconds(unsigned);
typedef int portMUX_TYPE;
#define portMUX_INITIALIZER_UNLOCKED 0
inline void portENTER_CRITICAL(portMUX_TYPE*) {}
inline void portEXIT_CRITICAL(portMUX_TYPE*) {}
