#!/usr/bin/env bash
# Verificação rápida de sintaxe do firmware no PC (sem o compilador do ESP32).
# Não substitui "pio run": usa declarações simplificadas das bibliotecas (tests/firmware_stubs).
set -euo pipefail
cd "$(dirname "$0")/../firmware"
cfg=include/config.h
[ -f "$cfg" ] || { cp include/config.example.h "$cfg"; trap 'rm -f "$cfg"' EXIT; }
for f in src/*.cpp; do
  g++ -std=gnu++17 -fsyntax-only -Wall -Wextra -Wno-unused-parameter -I../tests/firmware_stubs -Iinclude -Isrc "$f"
  echo "ok: $f"
done
