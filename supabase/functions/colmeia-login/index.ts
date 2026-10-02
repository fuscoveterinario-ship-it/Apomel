// Login do Bee Guard por código de 6 números, enviado pelo próprio Bee Guard:
//  - por SMS (celular): a conta fica num e-mail interno p<número>@telefone.beeguard.com.br,
//    que o apicultor nunca vê (muitos apicultores não usam e-mail);
//  - por e-mail (Resend), em português e com a marca. Sem RESEND_API_KEY, responde
//    { fallback: true } e o site usa o e-mail padrão do Supabase.
// Não altera os modelos de e-mail do projeto (usados por outros sistemas).
import { createClient } from "jsr:@supabase/supabase-js@2";
import { loginEmail, loginSms, normalizeEmail, phoneLoginEmail, normalizeLoginPhone } from "../_shared/login_email.ts";
import { send } from "../_shared/providers.ts";

const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
  auth: { persistSession: false },
});

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const reply = (body: unknown, status = 200) => Response.json(body, { status, headers: cors });

async function otpFor(email: string): Promise<string | null> {
  let { data, error } = await db.auth.admin.generateLink({ type: "magiclink", email });
  if (error) {
    // Primeiro acesso: cria o usuário (como o login padrão faria) e tenta de novo.
    const created = await db.auth.admin.createUser({ email, email_confirm: true });
    if (created.error) {
      console.error("createUser", created.error.message);
      return null;
    }
    ({ data, error } = await db.auth.admin.generateLink({ type: "magiclink", email }));
  }
  if (error) console.error("generateLink", error.message);
  return data?.properties?.email_otp ?? null;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: cors });
  if (req.method !== "POST") return reply({ ok: false, error: "use POST" }, 405);

  const body = await req.json().catch(() => ({}));

  // Login pelo celular: código por SMS.
  if ((body as { phone?: unknown }).phone !== undefined) {
    const phone = normalizeLoginPhone((body as { phone?: unknown }).phone);
    if (!phone) return reply({ ok: false, error: "Celular inválido. Use DDD + número, ex.: (41) 99999-0001." }, 400);
    const email = phoneLoginEmail(phone);
    const { data: allowed, error: rpcError } = await db.rpc("colmeia_login_allowed", { p_email: email });
    if (rpcError) {
      console.error("colmeia_login_allowed", rpcError.message);
      return reply({ ok: false, error: "Não foi possível enviar o código agora." }, 500);
    }
    if (!allowed) return reply({ ok: false, error: "Muitos pedidos de código. Espere 15 minutos e tente de novo." }, 429);
    const code = await otpFor(email);
    if (!code) return reply({ ok: false, error: "Não foi possível gerar o código agora." }, 500);
    const r = await send({ id: 0, to_phone: phone, channel: "sms", template: "login", body: loginSms(code), params: {} },
      (k) => Deno.env.get(k));
    if (r.status !== "enviado") {
      console.error("sms login", r.status, r.error);
      return reply({ ok: false, error: "Não foi possível enviar o SMS agora. Tente de novo em alguns minutos." }, 502);
    }
    return reply({ ok: true, email });
  }

  const apiKey = Deno.env.get("RESEND_API_KEY");
  if (!apiKey) return reply({ ok: false, fallback: true });

  const email = normalizeEmail((body as { email?: unknown }).email);
  if (!email) return reply({ ok: false, error: "E-mail inválido." }, 400);

  const { data: allowed, error: rpcError } = await db.rpc("colmeia_login_allowed", { p_email: email });
  if (rpcError) {
    console.error("colmeia_login_allowed", rpcError.message);
    return reply({ ok: false, error: "Não foi possível enviar o código agora." }, 500);
  }
  if (!allowed) {
    return reply({ ok: false, error: "Muitos pedidos de código. Espere 15 minutos e tente de novo." }, 429);
  }

  const code = await otpFor(email);
  if (!code) return reply({ ok: false, error: "Não foi possível gerar o código agora." }, 500);

  const site = Deno.env.get("SITE_URL") ?? "https://beeguard.com.br";
  const msg = loginEmail(code, site);
  const res = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: { Authorization: `Bearer ${apiKey}`, "Content-Type": "application/json" },
    body: JSON.stringify({
      from: Deno.env.get("LOGIN_EMAIL_FROM") ?? "Bee Guard <acesso@beeguard.com.br>",
      to: [email],
      subject: msg.subject,
      html: msg.html,
      text: msg.text,
    }),
  });
  if (!res.ok) {
    console.error("resend", res.status, (await res.text()).slice(0, 300));
    // Domínio ainda em verificação ou chave sem permissão: o site usa o e-mail padrão.
    if (res.status === 401 || res.status === 403 || res.status === 422) return reply({ ok: false, fallback: true });
    return reply({ ok: false, error: "Não foi possível enviar o e-mail agora. Tente de novo em alguns minutos." }, 502);
  }
  return reply({ ok: true });
});
