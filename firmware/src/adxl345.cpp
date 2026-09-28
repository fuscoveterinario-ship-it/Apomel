#include "adxl345.h"
#include <math.h>

namespace {
constexpr uint8_t REG_DEVID = 0x00;
constexpr uint8_t REG_THRESH_ACT = 0x24;
constexpr uint8_t REG_ACT_INACT_CTL = 0x27;
constexpr uint8_t REG_BW_RATE = 0x2C;
constexpr uint8_t REG_POWER_CTL = 0x2D;
constexpr uint8_t REG_INT_ENABLE = 0x2E;
constexpr uint8_t REG_INT_MAP = 0x2F;
constexpr uint8_t REG_INT_SOURCE = 0x30;
constexpr uint8_t REG_DATA_FORMAT = 0x31;
constexpr uint8_t REG_DATAX0 = 0x32;
constexpr uint8_t INT_ACTIVITY = 0x10;
constexpr float G_PER_LSB = 0.0039f;  // resolução total: 3,9 mg por unidade
}  // namespace

bool ADXL345::begin(TwoWire& wire, uint8_t addr) {
  wire_ = &wire;
  addr_ = addr;
  if (read8(REG_DEVID) != 0xE5) return false;
  write(REG_DATA_FORMAT, 0x0B);  // resolução total, ±16 g, INT ativo em nível alto
  write(REG_POWER_CTL, 0x08);    // modo medição
  return true;
}

void ADXL345::armMotionInterrupt(uint8_t threshold) {
  write(REG_INT_ENABLE, 0x00);
  write(REG_BW_RATE, 0x17);          // baixo consumo, 12,5 leituras por segundo
  write(REG_THRESH_ACT, threshold);
  write(REG_ACT_INACT_CTL, 0xF0);    // atividade em X, Y e Z, acoplamento AC (ignora gravidade)
  write(REG_INT_MAP, 0x00);          // tudo no pino INT1
  read8(REG_INT_SOURCE);             // limpa pendências
  write(REG_INT_ENABLE, INT_ACTIVITY);
}

bool ADXL345::takeActivity() {
  return read8(REG_INT_SOURCE) & INT_ACTIVITY;
}

bool ADXL345::read(Accel& a) {
  wire_->beginTransmission(addr_);
  wire_->write(REG_DATAX0);
  if (wire_->endTransmission(false) != 0) return false;
  if (wire_->requestFrom(addr_, (uint8_t)6) != 6) return false;
  int16_t raw[3];
  for (int i = 0; i < 3; i++) {
    uint8_t lo = wire_->read();
    uint8_t hi = wire_->read();
    raw[i] = (int16_t)((hi << 8) | lo);
  }
  a = {raw[0] * G_PER_LSB, raw[1] * G_PER_LSB, raw[2] * G_PER_LSB};
  return true;
}

void ADXL345::write(uint8_t reg, uint8_t val) {
  wire_->beginTransmission(addr_);
  wire_->write(reg);
  wire_->write(val);
  wire_->endTransmission();
}

uint8_t ADXL345::read8(uint8_t reg) {
  wire_->beginTransmission(addr_);
  wire_->write(reg);
  if (wire_->endTransmission(false) != 0) return 0;
  if (wire_->requestFrom(addr_, (uint8_t)1) != 1) return 0;
  return wire_->read();
}

float tiltBetween(const Accel& a, const Accel& b) {
  float na = sqrtf(a.x * a.x + a.y * a.y + a.z * a.z);
  float nb = sqrtf(b.x * b.x + b.y * b.y + b.z * b.z);
  if (na < 0.3f || nb < 0.3f) return 0;  // leitura inválida
  float c = (a.x * b.x + a.y * b.y + a.z * b.z) / (na * nb);
  c = fmaxf(-1.0f, fminf(1.0f, c));
  return acosf(c) * 180.0f / (float)M_PI;
}
