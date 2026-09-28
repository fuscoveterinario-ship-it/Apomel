// Bee Guard — firmware do rastreador de colmeias
// Placa LILYGO T-A7670SA (ESP32 + modem 4G/2G com GPS) + acelerômetro ADXL345.
//
// Funcionamento:
//  - Dorme em sono profundo quase o tempo todo (economia de bateria).
//  - Acorda quando o ADXL345 sente movimento (pino INT1) ou pelo relógio
//    (mensagem de vida 1 vez por dia, ou posição a cada 1 min no modo roubo).
//  - Movimento confirmado: avisa a plataforma na hora com a última posição
//    conhecida, depois liga o GPS e manda a posição atual.
//  - Sem internet: manda SMS direto para os telefones cadastrados e guarda o
//    evento para reenviar depois (o SMS também será o caminho via satélite
//    Starlink/Vivo quando o serviço for liberado).
//  - Sem internet e a caixa continua se movendo: entra sozinho em "modo roubo
//    local" e manda SMS com a posição a cada 5 min até a internet voltar.
//  - Enquanto houver alerta aberto ou modo roubo, fica acordado enviando posição;
//    se a caixa ficar parada 30 min, passa a acordar a cada 30 min.
//  - Wi-Fi e Bluetooth ficam desligados.

#include <Arduino.h>
#include <Preferences.h>
#include <Wire.h>
#include <cJSON.h>
#include <driver/rtc_io.h>
#include <esp_bt.h>
#include <esp_sleep.h>
#include <esp_wifi.h>
#include <mbedtls/md.h>
#include <time.h>

#include <algorithm>

#include "board.h"
#include "config.h"
#include "adxl345.h"

#define SerialAT Serial1
#include <TinyGsmClient.h>
#ifdef DUMP_AT_COMMANDS
#include <StreamDebugger.h>
StreamDebugger debugger(SerialAT, Serial);
TinyGsm modem(debugger);
#else
TinyGsm modem(SerialAT);
#endif

#define FW_VERSION "0.2.0"

#ifndef DEFAULT_THEFT_SMS_INTERVAL_S
#define DEFAULT_THEFT_SMS_INTERVAL_S 300
#endif

// ---------------------------------------------------------------------------
// Estado guardado na memória RTC (sobrevive ao sono profundo, não a um desligamento)
// ---------------------------------------------------------------------------
struct QueuedEvent {
  uint32_t seq;
  char type[14];
  float lat, lon;
  int16_t batteryMv;
  time_t at;
};

constexpr uint32_t STATE_MAGIC = 0xC0151E6B;  // muda quando a estrutura abaixo muda
constexpr uint32_t STILL_SLEEP_S = 30 * 60;   // roubo com a caixa parada: acorda a cada 30 min
constexpr int LOW_BATTERY_MV = 3300;
constexpr int QUEUE_SIZE = 10;

struct State {
  uint32_t magic;
  bool theftMode;       // modo roubo mandado pela plataforma
  bool localTheft;      // modo roubo decidido pela própria placa, sem internet
  time_t localTheftSince;
  time_t lastSmsAt;
  uint16_t smsIntervalS;
  bool alertOpen;
  uint16_t heartbeatMin;
  uint16_t theftIntervalS;
  time_t maintenanceUntil;  // manutenção informada pela plataforma
  time_t nextHeartbeat;
  bool hasFix;
  float lastLat, lastLon;
  bool hasRef;
  Accel ref;  // posição de repouso da caixa (direção da gravidade)
  uint8_t qlen;
  QueuedEvent queue[QUEUE_SIZE];
};
RTC_DATA_ATTR State st;

Preferences prefs;
ADXL345 accel;
bool accelOk = false;
bool modemReady = false;
bool netReady = false;
bool gpsOn = false;
int signalQuality = 99;
uint32_t lastNetFailMs = 0;  // última vez que a internet do chip falhou

bool inTheft() { return st.theftMode || st.localTheft; }

time_t now_s() { return time(nullptr); }

void trace(const char* fmt, ...) {
  char buf[200];
  va_list ap;
  va_start(ap, fmt);
  vsnprintf(buf, sizeof(buf), fmt, ap);
  va_end(ap);
  Serial.printf("[%6lus] %s\n", (unsigned long)(millis() / 1000), buf);
}

// ---------------------------------------------------------------------------
// Bateria, sequência e fila de eventos
// ---------------------------------------------------------------------------
int batteryMv() {
  uint32_t sum = 0;
  for (int i = 0; i < 8; i++) sum += analogReadMilliVolts(BOARD_BAT_ADC_PIN);
  return (int)(sum / 8) * 2;  // divisor resistivo 1:2 na placa
}

// Número sempre crescente, guardado na memória flash (não se perde sem bateria).
uint32_t nextSeq() {
  uint32_t seq = prefs.getUInt("seq", 0) + 1;
  prefs.putUInt("seq", seq);
  return seq;
}

void enqueue(const char* type, bool withPosition) {
  if (st.qlen == QUEUE_SIZE) {
    // Fila cheia: descarta o evento mais antigo que não seja de movimento.
    int drop = 0;
    for (int i = 0; i < st.qlen; i++) {
      if (strcmp(st.queue[i].type, "movimento") != 0) { drop = i; break; }
    }
    memmove(&st.queue[drop], &st.queue[drop + 1], (st.qlen - drop - 1) * sizeof(QueuedEvent));
    st.qlen--;
  }
  QueuedEvent& e = st.queue[st.qlen++];
  e.seq = nextSeq();
  strlcpy(e.type, type, sizeof(e.type));
  e.lat = (withPosition && st.hasFix) ? st.lastLat : 0;
  e.lon = (withPosition && st.hasFix) ? st.lastLon : 0;
  e.batteryMv = batteryMv();
  e.at = now_s();
  trace("evento %s seq=%u", type, e.seq);
}

// ---------------------------------------------------------------------------
// Modem: ligar, rede, desligar
// ---------------------------------------------------------------------------
bool modemOn() {
  if (modemReady) return true;
  SerialAT.begin(MODEM_BAUDRATE, SERIAL_8N1, MODEM_RX_PIN, MODEM_TX_PIN);

  digitalWrite(BOARD_POWERON_PIN, HIGH);
  pinMode(MODEM_RESET_PIN, OUTPUT);
  digitalWrite(MODEM_RESET_PIN, !MODEM_RESET_LEVEL);
  delay(100);
  digitalWrite(MODEM_RESET_PIN, MODEM_RESET_LEVEL);
  delay(2600);
  digitalWrite(MODEM_RESET_PIN, !MODEM_RESET_LEVEL);

  pinMode(MODEM_DTR_PIN, OUTPUT);
  digitalWrite(MODEM_DTR_PIN, LOW);  // modem acordado

  pinMode(BOARD_PWRKEY_PIN, OUTPUT);
  digitalWrite(BOARD_PWRKEY_PIN, LOW);
  delay(100);
  digitalWrite(BOARD_PWRKEY_PIN, HIGH);
  delay(MODEM_POWERON_PULSE_WIDTH_MS);
  digitalWrite(BOARD_PWRKEY_PIN, LOW);

  trace("ligando modem...");
  uint32_t start = millis();
  while (!modem.testAT(1000)) {
    if (millis() - start > 30000) {
      trace("modem não respondeu");
      return false;
    }
  }
  modemReady = true;
  return true;
}

bool networkUp(uint32_t timeoutMs) {
  if (netReady) return true;
  if (!modemOn()) return false;

  uint32_t start = millis();
  while (modem.getSimStatus() != SIM_READY) {
    if (millis() - start > 15000) {
      trace("chip não encontrado");
      return false;
    }
    delay(500);
  }

  trace("procurando rede...");
  RegStatus reg = REG_NO_RESULT;
  while (millis() - start < timeoutMs) {
    reg = modem.getRegistrationStatus();
    if (reg == REG_OK_HOME || reg == REG_OK_ROAMING) break;
    if (reg == REG_DENIED) {
      trace("rede recusou o chip (confira o APN e o plano de dados)");
      return false;
    }
    delay(1000);
  }
  signalQuality = modem.getSignalQuality();
  if (reg != REG_OK_HOME && reg != REG_OK_ROAMING) {
    trace("sem rede (sinal %d)", signalQuality);
    return false;
  }
  trace("rede OK, sinal %d", signalQuality);

  for (int i = 0; i < 3; i++) {
    if (modem.setNetworkActive(NETWORK_APN)) {
      netReady = true;
      return true;
    }
    delay(3000);
  }
  trace("falha ao ativar dados móveis");
  return false;
}

void modemOffAndHold() {
  if (modemReady) {
    if (gpsOn) modem.disableGPS(MODEM_GPS_ENABLE_GPIO, !MODEM_GPS_ENABLE_LEVEL);
    modem.poweroff();
    delay(3000);
  }
  modemReady = netReady = gpsOn = false;
  digitalWrite(BOARD_POWERON_PIN, LOW);
  // O pino de reset precisa ficar baixo durante o sono, senão o modem liga sozinho.
  pinMode(MODEM_RESET_PIN, OUTPUT);
  digitalWrite(MODEM_RESET_PIN, !MODEM_RESET_LEVEL);
  gpio_hold_en((gpio_num_t)MODEM_RESET_PIN);
  gpio_deep_sleep_hold_en();
}

// ---------------------------------------------------------------------------
// GPS
// ---------------------------------------------------------------------------
bool getFix(uint32_t timeoutS) {
  if (!modemOn()) return false;
  if (!gpsOn) {
    gpsOn = modem.enableGPS(MODEM_GPS_ENABLE_GPIO, MODEM_GPS_ENABLE_LEVEL);
    if (!gpsOn) {
      trace("GPS não ligou");
      return false;
    }
  }
  uint32_t start = millis();
  while (millis() - start < timeoutS * 1000UL) {
    uint8_t status = 0;
    float lat = 0, lon = 0, speed = 0, alt = 0, acc = 0;
    int vsat = 0, usat = 0, y, mo, d, h, mi, s;
    if (modem.getGPS(&status, &lat, &lon, &speed, &alt, &vsat, &usat, &acc, &y, &mo, &d, &h, &mi, &s) &&
        (lat != 0 || lon != 0)) {
      st.lastLat = lat;
      st.lastLon = lon;
      st.hasFix = true;
      trace("GPS %.6f, %.6f", lat, lon);
      return true;
    }
    delay(2000);
  }
  trace("GPS sem posição em %us", timeoutS);
  return false;
}

// ---------------------------------------------------------------------------
// Envio para a plataforma (HTTPS com assinatura HMAC-SHA256)
// ---------------------------------------------------------------------------
String hmacHex(const String& msg) {
  uint8_t out[32];
  mbedtls_md_context_t ctx;
  mbedtls_md_init(&ctx);
  mbedtls_md_setup(&ctx, mbedtls_md_info_from_type(MBEDTLS_MD_SHA256), 1);
  mbedtls_md_hmac_starts(&ctx, (const unsigned char*)DEVICE_SECRET, strlen(DEVICE_SECRET));
  mbedtls_md_hmac_update(&ctx, (const unsigned char*)msg.c_str(), msg.length());
  mbedtls_md_hmac_finish(&ctx, out);
  mbedtls_md_free(&ctx);
  char hex[65];
  for (int i = 0; i < 32; i++) sprintf(hex + i * 2, "%02x", out[i]);
  return String(hex);
}

String buildBody() {
  String body = "{\"events\":[";
  char item[200];
  for (int i = 0; i < st.qlen; i++) {
    const QueuedEvent& e = st.queue[i];
    snprintf(item, sizeof(item),
             "%s{\"seq\":%u,\"t\":\"%s\",\"lat\":%.6f,\"lon\":%.6f,\"bat\":%d,\"sig\":%d,\"age\":%ld,\"fw\":\"%s\"}",
             i ? "," : "", e.seq, e.type, e.lat, e.lon, e.batteryMv, signalQuality,
             (long)(now_s() - e.at), FW_VERSION);
    body += item;
  }
  body += "]}";
  return body;
}

// Guarda os telefones que a plataforma mandou (usados no SMS de emergência).
void saveSmsNumbers(cJSON* arr) {
  String list;
  cJSON* it;
  cJSON_ArrayForEach(it, arr) {
    if (cJSON_IsString(it)) {
      if (list.length()) list += ",";
      list += it->valuestring;
    }
  }
  if (list != prefs.getString("sms", "")) prefs.putString("sms", list);
}

void applyConfig(const String& json) {
  cJSON* root = cJSON_Parse(json.c_str());
  if (!root) return;
  cJSON* v;
  if ((v = cJSON_GetObjectItem(root, "mode")) && cJSON_IsString(v)) st.theftMode = strcmp(v->valuestring, "roubo") == 0;
  if ((v = cJSON_GetObjectItem(root, "hb")) && cJSON_IsNumber(v)) st.heartbeatMin = constrain(v->valueint, 15, 1440);
  if ((v = cJSON_GetObjectItem(root, "ti")) && cJSON_IsNumber(v)) st.theftIntervalS = constrain(v->valueint, 30, 3600);
  if ((v = cJSON_GetObjectItem(root, "si")) && cJSON_IsNumber(v)) st.smsIntervalS = constrain(v->valueint, 120, 3600);
  if ((v = cJSON_GetObjectItem(root, "al"))) {
    st.alertOpen = cJSON_IsTrue(v);
    // Alerta encerrado na plataforma ("Sou eu" ou caixa recuperada): fim do roubo local.
    if (!st.alertOpen) st.localTheft = false;
  }
  if ((v = cJSON_GetObjectItem(root, "cx")) && cJSON_IsString(v) && prefs.getString("cx", "") != v->valuestring) {
    prefs.putString("cx", v->valuestring);
  }
  if ((v = cJSON_GetObjectItem(root, "mnt"))) st.maintenanceUntil = cJSON_IsTrue(v) ? now_s() + 30 * 60 : 0;
  if ((v = cJSON_GetObjectItem(root, "sms")) && cJSON_IsArray(v)) saveSmsNumbers(v);
  cJSON_Delete(root);
  trace("config: modo=%s alerta=%d vida=%umin roubo=%us", st.theftMode ? "roubo" : "normal", st.alertOpen,
      st.heartbeatMin, st.theftIntervalS);
}

bool sendQueue() {
  if (st.qlen == 0) return true;
  if (!networkUp(90000)) {
    lastNetFailMs = millis() | 1;
    return false;
  }

  String body = buildBody();
  String sig = hmacHex(body);
  bool ok = false;

  if (modem.https_begin()) {
    modem.https_set_url(API_URL);
    modem.https_add_header("x-device-id", DEVICE_ID);
    modem.https_add_header("x-signature", sig.c_str());
    modem.https_set_content_type("application/json");
    int code = modem.https_post(body);
    trace("envio de %u evento(s): HTTP %d", st.qlen, code);
    if (code == 200) {
      applyConfig(modem.https_body());
      st.qlen = 0;
      ok = true;
    } else if (code == 400 || code == 401) {
      // Recusado pela plataforma (segredo errado ou dado inválido): não adianta repetir.
      trace("plataforma recusou: confira DEVICE_ID/DEVICE_SECRET no config.h");
      st.qlen = 0;
    }
    modem.https_end();
  }
  return ok;
}

// SMS usa o alfabeto básico do celular: tira acentos ("Caixa São João" → "Caixa Sao Joao").
void asciiCopy(const char* in, char* out, size_t n) {
  size_t o = 0;
  for (const unsigned char* p = (const unsigned char*)in; *p && o + 1 < n; p++) {
    if (*p < 0x80) {
      out[o++] = *p;
    } else if (*p == 0xC3 && p[1]) {
      unsigned char c = *++p;
      char r = 0;
      if (c >= 0xA0 && c <= 0xA5) r = 'a'; else if (c == 0xA7) r = 'c';
      else if (c >= 0xA8 && c <= 0xAB) r = 'e'; else if (c >= 0xAC && c <= 0xAF) r = 'i';
      else if (c >= 0xB2 && c <= 0xB6) r = 'o'; else if (c >= 0xB9 && c <= 0xBC) r = 'u';
      else if (c >= 0x80 && c <= 0x85) r = 'A'; else if (c == 0x87) r = 'C';
      else if (c >= 0x88 && c <= 0x8B) r = 'E'; else if (c >= 0x8C && c <= 0x8F) r = 'I';
      else if (c >= 0x92 && c <= 0x96) r = 'O'; else if (c >= 0x99 && c <= 0x9C) r = 'U';
      if (r) out[o++] = r;
    }
  }
  out[o] = 0;
}

void sendSmsToAll(const char* text) {
  String list = prefs.getString("sms", "");
  if (list.isEmpty() || !modemOn()) return;
  int from = 0;
  while (from < (int)list.length()) {
    int comma = list.indexOf(',', from);
    if (comma < 0) comma = list.length();
    String phone = list.substring(from, comma);
    bool sent = modem.sendSMS(phone, text);
    trace("SMS para %s: %s", phone.c_str(), sent ? "enviado" : "falhou");
    from = comma + 1;
  }
}

// SMS com a posição, quando a internet do chip falha (também será o caminho
// da Starlink no celular). theft=false: primeiro aviso; true: acompanhamento do roubo.
void sendPositionSms(bool theft) {
  char caixa[40];
  asciiCopy(prefs.getString("cx", DEVICE_ID).c_str(), caixa, sizeof(caixa));
  int pct = constrain((batteryMv() - 3300) * 100 / 900, 0, 100);
  char where[80];
  if (st.hasFix) snprintf(where, sizeof(where), "https://maps.google.com/?q=%.6f,%.6f", st.lastLat, st.lastLon);
  else strlcpy(where, "posicao ainda desconhecida", sizeof(where));
  char text[200];
  if (theft) {
    snprintf(text, sizeof(text), "BEE GUARD ROUBO %s: %s bateria %d%%", caixa, where, pct);
  } else {
    snprintf(text, sizeof(text), "ALERTA BEE GUARD: %s foi movimentada. Sem internet no local. Posicao: %s bateria %d%%",
             caixa, where, pct);
  }
  sendSmsToAll(text);
  st.lastSmsAt = now_s();
}

// Distância aproximada em metros (suficiente para saber se a caixa saiu do lugar).
float distanceM(float lat1, float lon1, float lat2, float lon2) {
  const float k = 111320.0f;
  float dx = (lon2 - lon1) * k * cosf((lat1 + lat2) * 0.5f * (float)M_PI / 180.0f);
  float dy = (lat2 - lat1) * k;
  return sqrtf(dx * dx + dy * dy);
}

// ---------------------------------------------------------------------------
// Movimento
// ---------------------------------------------------------------------------
bool readAverage(Accel& out) {
  Accel a, sum = {0, 0, 0};
  int n = 0;
  for (int i = 0; i < 5; i++) {
    if (accel.read(a)) {
      sum.x += a.x; sum.y += a.y; sum.z += a.z;
      n++;
    }
    delay(90);
  }
  if (!n) return false;
  out = {sum.x / n, sum.y / n, sum.z / n};
  return true;
}

// Separa "caixa sendo levada" de "uma batida" (vento, animal): observa por 3 s.
// Confirma se a caixa inclinou ou se o movimento continuou em 2 de 3 segundos.
bool confirmMotion() {
  if (!accelOk) return true;  // sem sensor, melhor avisar do que ignorar
  accel.takeActivity();
  int activeSeconds = 0;
  float maxTilt = 0;
  for (int s = 0; s < 3; s++) {
    uint32_t t0 = millis();
    while (millis() - t0 < 1000) {
      Accel a;
      if (st.hasRef && accel.read(a)) maxTilt = fmaxf(maxTilt, tiltBetween(a, st.ref));
      delay(80);
    }
    if (accel.takeActivity()) activeSeconds++;
  }
  trace("movimento: inclinação %.1f°, %d/3 s ativos", maxTilt, activeSeconds);
  return maxTilt >= TILT_DEGREES || activeSeconds >= 2;
}

// ---------------------------------------------------------------------------
// Sono profundo
// ---------------------------------------------------------------------------
void sleepFor(uint32_t seconds, bool wakeOnMotion) {
  modemOffAndHold();
  if (accelOk) {
    Accel rest;
    if (!inTheft() && readAverage(rest)) {
      st.ref = rest;
      st.hasRef = true;
    }
    accel.armMotionInterrupt(MOTION_THRESHOLD);
    delay(200);
    accel.takeActivity();
  }
  if (wakeOnMotion && accelOk) {
    rtc_gpio_pulldown_en((gpio_num_t)ACCEL_INT_PIN);
    esp_sleep_enable_ext0_wakeup((gpio_num_t)ACCEL_INT_PIN, 1);
  }
  seconds = std::max<uint32_t>(seconds, 10);
  esp_sleep_enable_timer_wakeup((uint64_t)seconds * 1000000ULL);
  trace("dormindo %us (acordar com movimento: %s)", seconds, wakeOnMotion ? "sim" : "não");
  Serial.flush();
  esp_deep_sleep_start();
}

void sleepUntilHeartbeat() {
  time_t now = now_s();
  if (st.nextHeartbeat <= now) st.nextHeartbeat = now + (time_t)st.heartbeatMin * 60;
  sleepFor((uint32_t)(st.nextHeartbeat - now), true);
}

// ---------------------------------------------------------------------------
// Vigilância: alerta aberto ou modo roubo → fica acordado enviando posição.
// Sem internet: SMS com a posição a cada 5 min (modo roubo local).
// ---------------------------------------------------------------------------
void watchLoop() {
  const uint32_t alertWatchLimitMs = 15 * 60 * 1000UL;  // alerta sem roubo: vigia até 15 min
  const uint32_t stillLimitMs = STILL_SLEEP_S * 1000UL;  // roubo com caixa parada: dorme entre posições
  const uint32_t netRetryMs = 5 * 60 * 1000UL;           // sem internet: tenta de novo a cada 5 min
  uint32_t start = millis();
  uint32_t lastMove = millis();
  bool haveOrigin = st.hasFix;
  float oLat = st.lastLat, oLon = st.lastLon;

  while (inTheft() || st.alertOpen) {
    if (!inTheft() && millis() - start > alertWatchLimitMs) break;
    if (batteryMv() < LOW_BATTERY_MV) {
      trace("bateria muito baixa: interrompe a vigilância contínua");
      if (inTheft()) sendPositionSms(true);
      break;
    }
    uint32_t interval = inTheft() ? st.theftIntervalS : 60;
    uint32_t t0 = millis();

    // A caixa continua se movendo? (acelerômetro ou mais de 150 m de onde estava)
    bool moved = accelOk && accel.takeActivity();
    if (getFix(std::min<uint32_t>(interval, 45))) {
      if (!haveOrigin) {
        oLat = st.lastLat; oLon = st.lastLon; haveOrigin = true;
      } else if (distanceM(oLat, oLon, st.lastLat, st.lastLon) > 150) {
        moved = true;
        oLat = st.lastLat; oLon = st.lastLon;
      }
    }
    if (moved) lastMove = millis();
    enqueue("posicao", true);

    bool sent = false;
    if (netReady || !lastNetFailMs || millis() - lastNetFailMs >= netRetryMs) sent = sendQueue();

    if (!sent) {
      if (!inTheft() && st.alertOpen && moved) {
        st.localTheft = true;
        st.localTheftSince = now_s();
        trace("sem internet e a caixa continua se movendo: modo roubo local");
      }
      if (inTheft() && now_s() - st.lastSmsAt >= (time_t)st.smsIntervalS) sendPositionSms(true);
    }

    if (inTheft() && millis() - lastMove > stillLimitMs) {
      trace("caixa parada há 30 min: passa a acordar a cada 30 min");
      break;
    }

    uint32_t spent = millis() - t0;
    if (spent < interval * 1000UL) delay(interval * 1000UL - spent);
  }
}

// Depois de falar com a plataforma: decide quanto tempo dormir.
void finishAndSleep() {
  st.nextHeartbeat = 0;  // recomeça a contagem da mensagem de vida
  if (batteryMv() >= LOW_BATTERY_MV && inTheft()) sleepFor(STILL_SLEEP_S, true);
  sleepUntilHeartbeat();
}

// ---------------------------------------------------------------------------
// Programa principal (roda uma vez a cada vez que a placa acorda)
// ---------------------------------------------------------------------------
void setup() {
  Serial.begin(115200);
  // Necessário na T-A7670 com bateria: sem isso a placa reinicia.
  pinMode(BOARD_POWERON_PIN, OUTPUT);
  digitalWrite(BOARD_POWERON_PIN, HIGH);
  gpio_hold_dis((gpio_num_t)MODEM_RESET_PIN);

  esp_wifi_stop();
  esp_bt_controller_disable();

  prefs.begin("colmeia", false);
  Wire.begin(ACCEL_SDA_PIN, ACCEL_SCL_PIN);
  accelOk = accel.begin(Wire);
  if (!accelOk) trace("ADXL345 não encontrado: confira os fios (SDA=21, SCL=22, CS e VCC no 3V3, SDO no GND)");

  esp_sleep_wakeup_cause_t cause = esp_sleep_get_wakeup_cause();
  bool firstBoot = st.magic != STATE_MAGIC;
  if (firstBoot) {
    memset(&st, 0, sizeof(st));
    st.magic = STATE_MAGIC;
    st.heartbeatMin = DEFAULT_HEARTBEAT_MIN;
    st.theftIntervalS = DEFAULT_THEFT_INTERVAL_S;
    st.smsIntervalS = DEFAULT_THEFT_SMS_INTERVAL_S;
  }
  // Roubo local sem nenhum contato com a plataforma há mais de 1 dia: encerra.
  if (st.localTheft && now_s() - st.localTheftSince > 24 * 3600) st.localTheft = false;
  trace("Bee Guard %s | %s | acordou por %d | bateria %d mV", FW_VERSION, DEVICE_ID, cause, batteryMv());

  // 1) Acordou por movimento
  if (cause == ESP_SLEEP_WAKEUP_EXT0 && !inTheft()) {
    if (st.maintenanceUntil > now_s()) {
      trace("em manutenção: movimento ignorado");
      sleepUntilHeartbeat();
    }
    if (!confirmMotion()) {
      trace("foi só uma batida: volta a dormir");
      sleepUntilHeartbeat();
    }
    enqueue("movimento", true);  // última posição conhecida, para avisar já
    bool online = sendQueue();
    if (!online) sendPositionSms(false);
    if (getFix(90)) enqueue("posicao", true);
    if (online) sendQueue();
    st.alertOpen = true;  // vigia até a plataforma dizer que acabou
    watchLoop();
    finishAndSleep();
  }

  // 2) Em roubo (plataforma ou local): segue mandando a posição
  if (inTheft()) {
    watchLoop();
    finishAndSleep();
  }

  // 3) Ligou agora (teste de ativação) ou hora da mensagem de vida
  if (firstBoot || cause == ESP_SLEEP_WAKEUP_UNDEFINED) {
    enqueue("online", false);
    sendQueue();  // resposta rápida para a tela de ativação
    if (getFix(120)) enqueue("posicao", true);
  } else {
    getFix(60);
    enqueue("vida", true);
  }
  sendQueue();
  watchLoop();
  finishAndSleep();
}

void loop() {
  // Nunca chega aqui: setup() sempre termina em sono profundo.
}
