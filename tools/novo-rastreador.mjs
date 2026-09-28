#!/usr/bin/env node
// Cadastra um rastreador novo: gera o segredo e o código de ativação.
// Uso: node tools/novo-rastreador.mjs CS-0001 https://seu-site.com
// Saída: o SQL para rodar no Supabase, o trecho do config.h e o link do QR Code.
import { randomBytes } from "node:crypto";

const [id, site = "https://SEU-SITE"] = process.argv.slice(2);
if (!id || !/^[A-Z0-9-]{3,20}$/i.test(id)) {
  console.error("Uso: node tools/novo-rastreador.mjs CS-0001 https://seu-site.com");
  process.exit(1);
}
const deviceId = id.toUpperCase();
const secret = randomBytes(24).toString("base64url");
// Sem letras/números que confundem (0/O, 1/I/L).
const alphabet = "ABCDEFGHJKMNPQRSTUVWXYZ23456789";
const pick = () => Array.from(randomBytes(4), (b) => alphabet[b % alphabet.length]).join("");
const claim = `${pick()}-${pick()}`;
const url = `${site.replace(/\/$/, "")}/ativar.html?d=${encodeURIComponent(deviceId)}&c=${claim}`;

console.log(`
== 1) Rode no Supabase (SQL Editor) ==
select public.provision_device('${deviceId}', '${secret}', '${claim}');

== 2) Coloque no firmware/include/config.h ==
#define DEVICE_ID      "${deviceId}"
#define DEVICE_SECRET  "${secret}"

== 3) QR Code técnico (cole este link num gerador de QR Code e imprima) ==
${url}

Código de ativação (caso o QR Code apague): ${claim}
Guarde o segredo: ele não aparece em nenhum outro lugar.
`);
