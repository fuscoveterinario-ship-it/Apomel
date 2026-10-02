// Testes do protocolo e do envio de mensagens (rodar: node --test tests/)
import { test } from "node:test";
import assert from "node:assert/strict";
import { createHmac } from "node:crypto";
import { compactConfig, hmacHex, parseIngestBody, verifySignature } from "../supabase/functions/_shared/protocol.ts";
import { send, smsRequest, whatsappRequest } from "../supabase/functions/_shared/providers.ts";

test("assinatura igual à do firmware (HMAC-SHA256 hex)", async () => {
  const body = '{"events":[{"seq":1,"t":"online"}]}';
  const node = createHmac("sha256", "segredo").update(body).digest("hex");
  assert.equal(await hmacHex("segredo", body), node);
  assert.ok(await verifySignature("segredo", body, node.toUpperCase()));
  assert.ok(!(await verifySignature("segredo", body + " ", node)));
  assert.ok(!(await verifySignature("outro", body, node)));
  assert.ok(!(await verifySignature("segredo", body, null)));
  assert.ok(!(await verifySignature("segredo", body, "abc")));
});

test("valida e ordena eventos", () => {
  const ev = parseIngestBody(JSON.stringify({
    events: [
      { seq: 5, t: "posicao", lat: -25.4, lon: -49.2, bat: 4000, sig: 20, age: 3 },
      { seq: 4, t: "movimento", lat: 0, lon: 0, bat: 4001, ch: "sms" },
    ],
  }));
  assert.deepEqual(ev.map((e) => e.seq), [4, 5]);
  assert.equal(ev[0].lat, null, "0,0 = sem GPS");
  assert.equal(ev[0].channel, "sms");
  assert.equal(ev[1].lat, -25.4);
  assert.deepEqual(ev[1].payload, { age: 3 });
});

test("pesagens da balança: aceita valores válidos e ignora lixo", () => {
  const [ev] = parseIngestBody(JSON.stringify({
    events: [{ seq: 1, t: "vida", w: -1234, ws: [[10800, 512000], [0, 515000], [-5, 1], [3, 9e9], "x", [1]] }],
  }));
  assert.deepEqual(ev.payload, { w: -1234, ws: [[10800, 512000], [0, 515000]] });
  const [ev2] = parseIngestBody(JSON.stringify({ events: [{ seq: 2, t: "vida", w: 1.5, ws: "x" }] }));
  assert.deepEqual(ev2.payload, {});
});

test("recusa corpo inválido", () => {
  for (const bad of ["x", "{}", '{"events":[]}', '{"events":[{"seq":0,"t":"vida"}]}',
                     '{"events":[{"seq":1,"t":"hack"}]}']) {
    assert.throws(() => parseIngestBody(bad), bad);
  }
  assert.throws(() => parseIngestBody(JSON.stringify({ events: Array(21).fill({ seq: 1, t: "vida" }) })));
});

test("resposta compacta para o rastreador", () => {
  assert.deepEqual(
    compactConfig({ ack: 7, mode: "roubo", heartbeat_min: 1440, theft_interval_s: 60, theft_sms_interval_s: 300,
      caixa: "Caixa 12", maintenance: false, alert_open: true, sms: ["+55"] }),
    { ok: true, ack: 7, mode: "roubo", hb: 1440, ti: 60, si: 300, cx: "Caixa 12", mnt: false, al: true, sms: ["+55"] },
  );
});

const n = {
  id: 1, to_phone: "+5541999990001", channel: "sms" as const, template: "alerta_movimento",
  body: "ALERTA", params: { caixa: "Caixa 12", apiario: "Sítio", link: "https://x/alerta.html?t=1" },
};

test("sem credenciais: mensagem simulada", async () => {
  assert.deepEqual(await send(n, () => undefined), { status: "simulado" });
  assert.deepEqual(await send({ ...n, channel: "whatsapp" }, () => undefined), { status: "simulado" });
});

test("WhatsApp: modelo com parâmetros na ordem", async () => {
  const env = (k: string) => ({ WHATSAPP_TOKEN: "t", WHATSAPP_PHONE_ID: "123" } as Record<string, string>)[k];
  const req = whatsappRequest({ ...n, channel: "whatsapp" }, env)!;
  assert.equal(req.url, "https://graph.facebook.com/v21.0/123/messages");
  const body = await req.json();
  assert.equal(body.to, "5541999990001");
  assert.equal(body.template.name, "alerta_movimento");
  assert.deepEqual(body.template.components[0].parameters.map((p: { text: string }) => p.text),
    ["Caixa 12", "Sítio", "https://x/alerta.html?t=1"]);
});

test("SMS Zenvia e Twilio", async () => {
  const z = smsRequest(n, (k) => ({ SMS_PROVIDER: "zenvia", ZENVIA_TOKEN: "z" } as Record<string, string>)[k])!;
  assert.equal((await z.json()).to, "5541999990001");
  const t = smsRequest(n, (k) => ({ SMS_PROVIDER: "twilio", TWILIO_SID: "AC1", TWILIO_TOKEN: "x",
                                     TWILIO_FROM: "+1555" } as Record<string, string>)[k])!;
  assert.match(t.url, /Accounts\/AC1\/Messages\.json$/);
  assert.match(await t.text(), /To=%2B5541999990001/);
});

test("falha do provedor vira 'falhou' com erro", async () => {
  const env = (k: string) => ({ SMS_PROVIDER: "zenvia", ZENVIA_TOKEN: "z" } as Record<string, string>)[k];
  const r = await send(n, env, async () => new Response("quota", { status: 429 }));
  assert.equal(r.status, "falhou");
  assert.match(r.error!, /429/);
  const ok = await send(n, env, async () => new Response("{}", { status: 200 }));
  assert.equal(ok.status, "enviado");
});

test("corpo no formato exato do firmware é aceito", () => {
  // Mesmo formato de buildBody() em firmware/src/main.cpp
  const body = '{"events":[{"seq":41,"t":"movimento","lat":-25.428400,"lon":-49.273300,"bat":4012,"sig":99,' +
    '"age":0,"fw":"0.1.0"},{"seq":42,"t":"posicao","lat":0.000000,"lon":0.000000,"bat":4010,"sig":17,"age":35,' +
    '"fw":"0.1.0"}]}';
  const ev = parseIngestBody(body);
  assert.equal(ev.length, 2);
  assert.equal(ev[0].lat, -25.4284);
  assert.equal(ev[1].lat, null);
  assert.deepEqual(ev[1].payload, { age: 35, fw: "0.1.0" });
});

test("SMS pela Mobizon: chave na URL, número só com dígitos e erro lido do corpo", async () => {
  const n = { id: 1, to_phone: "+55 41 99676-7045", channel: "sms" as const, template: "alerta_movimento",
    body: "ALERTA BEE GUARD: teste", params: {} };
  const env = (k: string) => ({ SMS_PROVIDER: "mobizon", MOBIZON_API_KEY: "k1" } as Record<string, string>)[k];
  const req = smsRequest(n, env)!;
  assert.match(req.url, /^https:\/\/api\.mobizon\.com\.br\/service\/message\/sendsmsmessage\?.*apiKey=k1/);
  const form = new URLSearchParams(await req.text());
  assert.equal(form.get("recipient"), "5541996767045");
  assert.equal(form.get("text"), "ALERTA BEE GUARD: teste");
  assert.equal(form.get("from"), null);
  assert.deepEqual(await send(n, env, async () => new Response('{"code":0,"data":{"messageId":"1"},"message":""}')),
    { status: "enviado" });
  const r = await send(n, env, async () => new Response('{"code":1,"data":[],"message":"saldo insuficiente"}'));
  assert.equal(r.status, "falhou");
  assert.match(r.error!, /saldo insuficiente/);
  const rede = await send(n, env, async () => { throw new Error("error sending request for url (https://api.mobizon.com.br/x?apiKey=k1)"); });
  assert.equal(rede.status, "falhou");
  assert.doesNotMatch(rede.error!, /k1/);
  assert.equal(smsRequest(n, (k) => (k === "SMS_PROVIDER" ? "mobizon" : undefined)), null);
});

test("SMS sai sem acentos (as operadoras estragam os acentos)", async () => {
  const n = { id: 1, to_phone: "+5541996767045", channel: "sms" as const, template: "alerta_movimento",
    body: "ALERTA BEE GUARD: a Caixa 7 (Apiário) foi movimentada às 21:14. Foi você? Responda em até 5 minutos",
    params: {} };
  const req = smsRequest(n, (k) => ({ SMS_PROVIDER: "mobizon", MOBIZON_API_KEY: "k" } as Record<string, string>)[k])!;
  const text = new URLSearchParams(await req.text()).get("text");
  assert.equal(text, "ALERTA BEE GUARD: a Caixa 7 (Apiario) foi movimentada as 21:14. Foi voce? Responda em ate 5 minutos");
});
