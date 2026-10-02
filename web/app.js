// Funções compartilhadas pelas telas.
import { createClient } from "https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2/+esm";
import { SUPABASE_ANON_KEY, SUPABASE_URL } from "./config.js";

export const sb = createClient(SUPABASE_URL, SUPABASE_ANON_KEY);

export const $ = (sel) => document.querySelector(sel);

export function show(el, visible = true) {
  (typeof el === "string" ? $(el) : el).hidden = !visible;
}

// "(41) 99999-0001" → "+5541999990001"
export function normalizePhone(input) {
  const raw = String(input || "").trim();
  if (!raw) return null;
  let d = raw.replace(/\D/g, "");
  if (raw.startsWith("+")) return d.length >= 8 ? `+${d}` : null;
  if (d.startsWith("0")) d = d.replace(/^0+/, "");
  if (d.length === 10 || d.length === 11) return `+55${d}`;
  if ((d.length === 12 || d.length === 13) && d.startsWith("55")) return `+${d}`;
  return null;
}

export function fmtDate(iso) {
  if (!iso) return "nunca";
  return new Date(iso).toLocaleString("pt-BR", { dateStyle: "short", timeStyle: "short" });
}

export function ago(iso) {
  if (!iso) return "nunca";
  const s = Math.round((Date.now() - new Date(iso).getTime()) / 1000);
  if (s < 60) return "agora";
  if (s < 3600) return `há ${Math.round(s / 60)} min`;
  if (s < 86400) return `há ${Math.round(s / 3600)} h`;
  return `há ${Math.round(s / 86400)} dias`;
}

// Bateria de lítio: 3,3 V ≈ vazia, 4,2 V ≈ cheia.
export function batteryPct(mv) {
  if (!mv) return null;
  return Math.max(0, Math.min(100, Math.round(((mv - 3300) / 900) * 100)));
}

export function mapsLink(lat, lon) {
  return `https://www.google.com/maps?q=${lat},${lon}`;
}

// Mensagem de erro amigável a partir do erro do Supabase.
export function errorText(e) {
  const m = (e && (e.message || e.error_description || e.error)) || String(e);
  if (/rate limit/i.test(m)) return "Muitos pedidos de acesso em pouco tempo. Use o último e-mail que chegou ou tente de novo em 1 hora.";
  if (/violates check constraint.*phone/i.test(m)) return "Telefone inválido. Use DDD + número, ex.: (41) 99999-0001.";
  return m;
}

// Login por código de 6 números (sem senha): pelo celular (SMS) ou pelo e-mail.
export async function ensureLogin(container, onReadyOnce) {
  let done = false;
  const onReady = (session) => { if (!done) { done = true; onReadyOnce(session); } };
  const { data } = await sb.auth.getSession();
  if (data.session) return onReady(data.session);
  container.innerHTML = `
    <h2>Entrar</h2>
    <form id="f-login"><p>Digite o seu <b>celular</b> (recebe o código por SMS) <b>ou</b> o seu <b>e-mail</b>.
      O código de acesso tem 6 números, sem senha.</p>
      <label>Celular ou e-mail<input id="login-id" name="id" required autocomplete="username"
        placeholder="(41) 99999-0001 ou nome@email.com"></label>
      <button>Receber código</button></form>
    <form id="f-code" hidden>
      <p class="aviso-email" id="aviso-code"></p>
      <label>Código recebido<input id="login-code" name="code" inputmode="numeric" pattern="[0-9]*" maxlength="10"
        required autocomplete="one-time-code"></label>
      <button>Entrar</button>
      <button type="button" class="secundario" id="voltar-login">Pedir outro código</button></form>
    <div id="enviado" class="aviso-email" hidden>
      <p><b>Pronto! Agora abra o seu e-mail.</b></p>
      <ol>
        <li>Procure a mensagem de <b>Supabase Auth</b> com o assunto <b>“Your sign-in link”</b>
          (é o nosso sistema de acesso; o texto vem em inglês).</li>
        <li>Toque em <b>“Sign in”</b>. Você volta para esta página já conectado.</li>
        <li>Não chegou? Confira a caixa de <b>spam</b> ou <b>promoções</b>. O link vale por pouco tempo
          e funciona uma vez só.</li>
      </ol>
    </div>
    <p class="msg" id="login-msg"></p>`;
  const msg = (t) => { container.querySelector("#login-msg").textContent = t; };
  const fLogin = container.querySelector("#f-login");
  const fCode = container.querySelector("#f-code");
  let email = "";
  const pedirCodigo = (aviso) => {
    msg("");
    show(fLogin, false);
    container.querySelector("#aviso-code").innerHTML = aviso;
    show(fCode);
    fCode.querySelector("input").focus();
  };
  const erroDaFuncao = async (error) => {
    let text = "Não foi possível enviar o código. Tente de novo.";
    try { text = (await error.context.json()).error || text; } catch { /* sem detalhe */ }
    return text;
  };
  // Com "@" é e-mail; sem, é celular (código por SMS).
  fLogin.onsubmit = async (ev) => {
    ev.preventDefault();
    const valor = ev.target.id.value.trim();
    const btn = fLogin.querySelector("button");
    if (!valor.includes("@")) {
      const phone = normalizePhone(valor);
      if (!phone || !phone.startsWith("+55")) return msg("Celular inválido. Use DDD + número, ex.: (41) 99999-0001.");
      btn.disabled = true;
      msg("Enviando…");
      const { data: r, error } = await sb.functions.invoke("colmeia-login", { body: { phone } });
      btn.disabled = false;
      if (error || !r?.ok) return msg(error ? await erroDaFuncao(error) : "Não foi possível enviar o código.");
      email = r.email;
      return pedirCodigo("Enviamos um <b>SMS</b> do <b>Bee Guard</b> com um código de 6 números. Pode levar alguns minutos.");
    }
    email = valor;
    btn.disabled = true;
    msg("Enviando…");
    // Código enviado pelo próprio Bee Guard; sem o serviço de e-mail configurado, usa o link padrão.
    const { data: r, error } = await sb.functions.invoke("colmeia-login", { body: { email } });
    btn.disabled = false;
    if (!error && r?.ok) {
      return pedirCodigo("Enviamos um e-mail de <b>Bee Guard</b> com um código de 6 números. " +
        "Não chegou em 1 minuto? Confira o <b>spam</b> ou <b>promoções</b>.");
    }
    if (error && !r?.fallback) {
      const text = await erroDaFuncao(error);
      if (!(error.context && error.context.status === 404)) return msg(text);
    }
    const { error: e2 } = await sb.auth.signInWithOtp({ email, options: { emailRedirectTo: location.href } });
    msg(e2 ? errorText(e2) : "");
    if (!e2) show(container.querySelector("#enviado"));
  };
  fCode.onsubmit = async (ev) => {
    ev.preventDefault();
    const token = ev.target.code.value.replace(/\D/g, "");
    const { data: d, error } = await sb.auth.verifyOtp({ email, token, type: "email" });
    if (error) msg(/expired|invalid/i.test(error.message) ? "Código errado ou vencido. Confira o número ou peça um novo." : errorText(error));
    else onReady(d.session);
  };
  container.querySelector("#voltar-login").onclick = () => { show(fCode, false); show(fLogin); msg(""); };
  sb.auth.onAuthStateChange((_e, session) => { if (session) onReady(session); });
}

export function esc(s) {
  return String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);
}
