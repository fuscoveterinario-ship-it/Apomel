// Copie este arquivo para "config.h" e preencha com os dados do rastreador.
// O arquivo config.h NÃO vai para o GitHub (tem o segredo do rastreador).
// Os valores de cada rastreador são gerados por: node tools/novo-rastreador.mjs
#pragma once

// Identificação (igual à do QR Code) e segredo usado para assinar as mensagens.
#define DEVICE_ID      "CS-0001"
#define DEVICE_SECRET  "cole-aqui-o-segredo-gerado"

// Endereço da função que recebe os eventos no Supabase.
#define API_URL        "https://vmzmthtsxiwwjtpupclv.supabase.co/functions/v1/colmeia-ingest"

// APN do chip. Vivo: "zap.vivo.com.br". Claro: "claro.com.br". TIM: "timbrasil.br".
#define NETWORK_APN    "zap.vivo.com.br"

// Valores iniciais; depois a plataforma manda os valores atuais em cada resposta.
#define DEFAULT_HEARTBEAT_MIN     1440  // mensagem de vida 1 vez por dia (24 h)
#define DEFAULT_THEFT_INTERVAL_S  60    // no modo roubo, posição a cada 1 minuto

// Sensibilidade do movimento (ADXL345: 62,5 mg por unidade). 8 = 0,5 g.
#define MOTION_THRESHOLD          8
// Inclinação mínima (graus) para considerar que a caixa foi realmente mexida.
#define TILT_DEGREES              12

// Mostrar os comandos AT do modem no monitor serial (útil para depurar).
// #define DUMP_AT_COMMANDS
