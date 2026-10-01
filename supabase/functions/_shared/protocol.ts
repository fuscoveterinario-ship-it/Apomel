// Protocolo entre o rastreador e a plataforma.
//
// O rastreador faz POST em /functions/v1/colmeia-ingest com:
//   cabeçalho  x-device-id: CS-0001
//   cabeçalho  x-signature: HMAC-SHA256(segredo do rastreador, corpo) em hexadecimal
//   corpo      {"events":[{"seq":12,"t":"movimento","lat":-25.4,"lon":-49.2,"bat":4010,"sig":18}]}
//   balança    "w": peso bruto na hora do evento; "ws": [[segundos atrás, peso bruto], ...]
//
// "seq" cresce sempre; mensagens repetidas (seq antigo) são ignoradas, o que
// também impede que alguém reenvie uma mensagem capturada.

export const EVENT_TYPES = ["online", "vida", "movimento", "posicao", "bateria_baixa"] as const;
export const CHANNELS = ["4g", "sms", "satelite", "teste"] as const;
export type EventType = typeof EVENT_TYPES[number];

export interface DeviceEvent {
  seq: number;
  type: EventType;
  lat: number | null;
  lon: number | null;
  battery_mv: number | null;
  signal: number | null;
  channel: string;
  payload: Record<string, unknown>;
}

const MAX_EVENTS = 20;

function num(v: unknown, min: number, max: number): number | null {
  if (typeof v !== "number" || !Number.isFinite(v) || v < min || v > max) return null;
  return v;
}

// Valor bruto do HX711 (24 bits com sinal). A plataforma converte em kg com a calibração.
function rawWeight(v: unknown): number | null {
  return typeof v === "number" && Number.isInteger(v) && v >= -8388608 && v <= 8388607 ? v : null;
}

// Pesagens guardadas pela placa: [[segundos atrás, valor bruto], ...] (até 3 dias).
function weightList(v: unknown): [number, number][] {
  if (!Array.isArray(v)) return [];
  const out: [number, number][] = [];
  for (const item of v.slice(0, 48)) {
    if (!Array.isArray(item) || item.length !== 2) continue;
    const [age, raw] = item;
    if (typeof age !== "number" || !Number.isInteger(age) || age < 0 || age > 7 * 86400) continue;
    const r = rawWeight(raw);
    if (r !== null) out.push([age, r]);
  }
  return out;
}

// Valida o corpo recebido. Lança Error com mensagem curta se estiver inválido.
export function parseIngestBody(raw: string): DeviceEvent[] {
  let body: unknown;
  try {
    body = JSON.parse(raw);
  } catch {
    throw new Error("json inválido");
  }
  const list = (body as { events?: unknown })?.events;
  if (!Array.isArray(list) || list.length === 0 || list.length > MAX_EVENTS) {
    throw new Error("events deve ter de 1 a 20 itens");
  }
  const events = list.map((e: Record<string, unknown>) => {
    const seq = e?.seq;
    if (typeof seq !== "number" || !Number.isSafeInteger(seq) || seq < 1) throw new Error("seq inválido");
    if (!EVENT_TYPES.includes(e.t as EventType)) throw new Error("tipo de evento inválido");
    let lat = num(e.lat, -90, 90);
    let lon = num(e.lon, -180, 180);
    if (lat === null || lon === null || (lat === 0 && lon === 0)) lat = lon = null;
    const channel = CHANNELS.includes(e.ch as typeof CHANNELS[number]) ? String(e.ch) : "4g";
    const payload: Record<string, unknown> = {};
    for (const k of ["age", "fix", "acc", "sats", "fw", "boot"]) if (k in e) payload[k] = e[k];
    const w = rawWeight(e.w);
    if (w !== null) payload.w = w;
    const ws = weightList(e.ws);
    if (ws.length) payload.ws = ws;
    return {
      seq,
      type: e.t as EventType,
      lat,
      lon,
      battery_mv: num(e.bat, 0, 10000),
      signal: num(e.sig, 0, 99),
      channel,
      payload,
    };
  });
  return events.sort((a, b) => a.seq - b.seq);
}

const enc = new TextEncoder();

export async function hmacHex(secret: string, message: string): Promise<string> {
  const key = await crypto.subtle.importKey("raw", enc.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, [
    "sign",
  ]);
  const sig = new Uint8Array(await crypto.subtle.sign("HMAC", key, enc.encode(message)));
  return Array.from(sig, (b) => b.toString(16).padStart(2, "0")).join("");
}

// Comparação em tempo constante para não vazar a assinatura por tempo de resposta.
export async function verifySignature(secret: string, body: string, signatureHex: string | null): Promise<boolean> {
  if (!signatureHex || !/^[0-9a-f]{64}$/i.test(signatureHex)) return false;
  const expected = await hmacHex(secret, body);
  const given = signatureHex.toLowerCase();
  let diff = 0;
  for (let i = 0; i < expected.length; i++) diff |= expected.charCodeAt(i) ^ given.charCodeAt(i);
  return diff === 0;
}

// Resposta compacta para o rastreador (economiza dados e tempo de rádio).
export function compactConfig(cfg: Record<string, unknown>) {
  return {
    ok: true,
    ack: cfg.ack,
    mode: cfg.mode,
    hb: cfg.heartbeat_min,
    ti: cfg.theft_interval_s,
    si: cfg.theft_sms_interval_s,
    cx: cfg.caixa,
    mnt: cfg.maintenance,
    al: cfg.alert_open,
    sms: cfg.sms,
  };
}
