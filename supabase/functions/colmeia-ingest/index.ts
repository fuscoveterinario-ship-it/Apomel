// Recebe as mensagens dos rastreadores (e do celular de teste).
// Publicada sem exigir login (verify_jwt = false): a autenticação é a assinatura HMAC.
import { createClient } from "jsr:@supabase/supabase-js@2";
import { compactConfig, parseIngestBody, verifySignature } from "../_shared/protocol.ts";
import { dispatchQueue } from "../_shared/dispatcher.ts";

const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
  auth: { persistSession: false },
});

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "content-type, x-device-id, x-signature",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const reply = (body: unknown, status = 200) => Response.json(body, { status, headers: cors });

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: cors });
  if (req.method !== "POST") return reply({ ok: false, error: "use POST" }, 405);

  const deviceId = (req.headers.get("x-device-id") ?? "").toUpperCase();
  const raw = await req.text();
  if (!/^[A-Z0-9-]{3,20}$/.test(deviceId) || raw.length > 8000) {
    return reply({ ok: false, error: "requisição inválida" }, 400);
  }

  const { data: secretRow } = await db.from("colmeia_device_secrets").select("secret").eq("device_id", deviceId)
    .maybeSingle();
  // Mesma resposta para rastreador inexistente e assinatura errada.
  if (!secretRow || !(await verifySignature(secretRow.secret, raw, req.headers.get("x-signature")))) {
    return reply({ ok: false, error: "não autorizado" }, 401);
  }

  let events;
  try {
    events = parseIngestBody(raw);
  } catch (e) {
    return reply({ ok: false, error: (e as Error).message }, 400);
  }

  let config: Record<string, unknown> = {};
  for (const ev of events) {
    const { data, error } = await db.rpc("colmeia_ingest_event", {
      p_device_id: deviceId,
      p_seq: ev.seq,
      p_type: ev.type,
      p_lat: ev.lat,
      p_lon: ev.lon,
      p_battery_mv: ev.battery_mv,
      p_signal: ev.signal,
      p_channel: ev.channel,
      p_payload: ev.payload,
    });
    if (error) {
      console.error("colmeia_ingest_event", deviceId, ev.seq, error.message);
      return reply({ ok: false, error: "falha ao registrar" }, 500);
    }
    config = data as Record<string, unknown>;
  }

  // Dispara o envio dos alertas sem atrasar a resposta ao rastreador.
  const job = dispatchQueue(db).catch((e) => console.error("dispatch", e));
  // deno-lint-ignore no-explicit-any
  (globalThis as any).EdgeRuntime?.waitUntil?.(job);

  return reply(compactConfig(config));
});
