#!/usr/bin/env bash
# Verificação rápida de sintaxe do firmware no PC (sem o compilador do ESP32), para as duas placas.
# Não substitui "pio run": usa declarações simplificadas das bibliotecas (tests/firmware_stubs).
set -euo pipefail
cd "$(dirname "$0")/../firmware"
cfg=include/config.h
[ -f "$cfg" ] || { cp include/config.example.h "$cfg"; trap 'rm -f "$cfg"' EXIT; }
for board in "-DBOARD_T_A7670 -DTINY_GSM_MODEM_A7670" "-DBOARD_T_SIM7080G_S3 -DTINY_GSM_MODEM_SIM7080"; do
  for f in src/*.cpp; do
    g++ -std=gnu++17 -fsyntax-only -Wall -Wextra -Wno-unused-parameter $board \
      -I../tests/firmware_stubs -Iinclude -Isrc "$f"
  done
  echo "ok: ${board%% *}"
done
