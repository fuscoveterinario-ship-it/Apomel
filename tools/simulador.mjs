#!/usr/bin/env node
// Finge ser um rastreador: útil para testar a plataforma antes da placa chegar.
// Uso:
//   node tools/simulador.mjs <evento> [lat lon]
//   eventos: online | vida | movimento | posicao | bateria_baixa
// Variáveis: API_URL, DEVICE_ID, DEVICE_SECRET (as mesmas do config.h)
import { createHmac } from "node:crypto";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

const { API_URL, DEVICE_ID, DEVICE_SECRET } = process.env;
const [type = "vida", lat = "-25.4284", lon = "-49.2733"] = process.argv.slice(2);
if (!API_URL || !DEVICE_ID || !DEVICE_SECRET) {
  console.error("Defina API_URL, DEVICE_ID e DEVICE_SECRET. Ex.:\n" +
    "  API_URL=https://xxx.supabase.co/functions/v1/colmeia-ingest DEVICE_ID=CS-0001 DEVICE_SECRET=... \\\n" +
    "  node tools/simulador.mjs movimento");
  process.exit(1);
}

// O "seq" precisa sempre crescer, como na placa (guardado num arquivo local).
const dir = join(homedir(), ".colmeia-simulador");
const file = join(dir, `${DEVICE_ID}.seq`);
let seq = 0;
try { seq = Number(readFileSync(file, "utf8")) || 0; } catch { /* primeiro uso */ }
seq = Math.max(seq + 1, Math.floor(Date.now() / 1000));
mkdirSync(dir, { recursive: true });
writeFileSync(file, String(seq));

const body = JSON.stringify({
  events: [{ seq, t: type, lat: Number(lat), lon: Number(lon), bat: 4050, sig: 20, ch: "teste" }],
});
const signature = createHmac("sha256", DEVICE_SECRET).update(body).digest("hex");

const res = await fetch(API_URL, {
  method: "POST",
  headers: { "Content-Type": "application/json", "x-device-id": DEVICE_ID, "x-signature": signature },
  body,
});
console.log(`enviado ${type} seq=${seq} → HTTP ${res.status}`);
console.log(await res.text());
