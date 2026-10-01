// Leitura da balança: módulo HX711 + 4 células de carga (colmeia sentinela).
// Sem biblioteca externa: o protocolo do HX711 é simples (2 fios: DOUT e SCK).
#pragma once
#include <Arduino.h>

class HX711 {
 public:
  void begin(int doutPin, int sckPin);  // acorda o HX711 (canal A, ganho 128)
  // Mediana de várias leituras (descarta as primeiras, que saem instáveis ao ligar).
  bool readMedian(int32_t& out, int samples);
  void powerDown();  // SCK em nível alto: consumo < 1 µA, mantido durante o sono profundo

 private:
  bool readOne(int32_t& out, uint32_t timeoutMs);
  int dout_ = -1;
  int sck_ = -1;
};
