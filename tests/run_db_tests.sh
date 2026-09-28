#!/usr/bin/env bash
# Cria um banco temporário, aplica as migrações e roda o teste do fluxo completo.
set -euo pipefail
cd "$(dirname "$0")/.."
DB=colmeia_test
PSQL="psql -v ON_ERROR_STOP=1 -q"
$PSQL -d postgres -c "drop database if exists $DB" -c "create database $DB"
files=(-f tests/supabase_shim.sql)
for f in supabase/migrations/*.sql; do files+=(-f "$f"); done
$PSQL -d $DB "${files[@]}" 2>&1 | grep -v 'pg_cron indisponível' || true
$PSQL -d $DB -o /dev/null -f tests/test_fluxo.sql 2>&1 | sed "s/^psql:[^ ]* NOTICE:  /  /"
