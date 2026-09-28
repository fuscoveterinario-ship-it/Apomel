// Driver mínimo do acelerômetro ADXL345 (I2C, endereço 0x53 com SDO no GND).
#pragma once
#include <Arduino.h>
#include <Wire.h>

struct Accel {
  float x, y, z;  // em g
};

class ADXL345 {
 public:
  bool begin(TwoWire& wire, uint8_t addr = 0x53);
  // Configura o modo de baixo consumo com interrupção de "atividade" no pino INT1.
  // threshold: 62,5 mg por unidade (8 = 0,5 g).
  void armMotionInterrupt(uint8_t threshold);
  // Lê e limpa a interrupção. Retorna true se houve atividade desde a última leitura.
  bool takeActivity();
  bool read(Accel& a);

 private:
  TwoWire* wire_ = nullptr;
  uint8_t addr_ = 0x53;
  void write(uint8_t reg, uint8_t val);
  uint8_t read8(uint8_t reg);
};

// Ângulo (graus) entre duas leituras de gravidade: indica se a caixa foi inclinada.
float tiltBetween(const Accel& a, const Accel& b);
