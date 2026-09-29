# Bee Guard

Rastreador antifurto de colmeias com plataforma própria: o apicultor escaneia o QR Code,
cadastra a caixa e os telefones, testa a comunicação e leva a caixa ao apiário. Se a caixa
for mexida, recebe WhatsApp e SMS perguntando se foi manutenção. Sem resposta em 5 minutos,
o contato secundário é avisado e o rastreador entra em **modo roubo** (posição a cada 1 minuto).

## Como as partes se ligam

```
 Rastreador (LILYGO T-A7670SA + ADXL345)
   │  4G/2G  HTTPS assinado (HMAC)      ──►  Supabase  ──►  WhatsApp + SMS
   │  SMS de emergência (sem internet)          │              (fila com reenvio)
   ▼                                            ▼
 Telefones cadastrados                   Site (web/): ativação por QR Code,
                                         resposta ao alerta com mapa, painel
```

| Pasta | O que tem |
|---|---|
| `firmware/` | Programa da placa (PlatformIO), para **T-SIM7080G-S3** (protótipo, Cat-M/NB-IoT) e **T-A7670SA** (produção, 4G + 2G): sono profundo, acorda com movimento, confirma se não foi só uma batida, GPS, envio HTTPS assinado, SMS de emergência, modo roubo. |
| `supabase/` | Banco de dados (tabelas, regras de acesso, alerta e escalonamento em 5 min) e as funções `colmeia-ingest` (recebe o rastreador) e `colmeia-dispatch` (envia WhatsApp/SMS). |
| `web/` | Telas: `ativar.html` (QR Code), `alerta.html` (Sou eu / Possível roubo / mapa), `painel.html` (meus rastreadores), `celular-teste.html` (celular como rastreador de teste). |
| `tools/` | `novo-rastreador.mjs` (gera segredo, código de ativação e link do QR Code) e `simulador.mjs` (finge ser a placa). |
| `tests/` | Testes do banco (fluxo completo de roubo) e do protocolo. |
| `docs/` | Guia de instalação e desenho de ligação da placa. |

## Regras do alerta

| Momento | O que acontece |
|---|---|
| 0 min | WhatsApp + SMS para o telefone principal, com link para responder. |
| até 5 min | "Sou eu" encerra (e ignora movimentos por 2 h). "Possível roubo" avisa o secundário na hora. |
| 5 min sem resposta | Avisa o secundário e o principal; rastreador entra em modo roubo. |
| Rastreador em silêncio | Sem mensagem além do esperado (ex.: destruído): aviso "sem comunicação". |
| Bateria baixa | Um aviso por dia. |

Sem internet no apiário, a placa manda **SMS direto** para os telefones cadastrados e guarda o
evento para reenviar. O mesmo caminho por SMS servirá para a conexão via satélite (Starlink
direto no celular, parceria com a Vivo prevista para 2027), sem trocar a placa.
Wi-Fi e Bluetooth ficam desligados.

## Testes

```bash
bash tests/run_db_tests.sh            # precisa de um PostgreSQL local
node --test tests/protocol.test.ts    # Node 22+
```

Para instalar tudo, siga [docs/INSTALACAO.md](docs/INSTALACAO.md).
