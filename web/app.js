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
  if (/violates check constraint.*phone/i.test(m)) return "Telefone inválido. Use DDD + número, ex.: (41) 99999-0001.";
  return m;
}

// Login por código enviado ao e-mail (sem senha).
export async function ensureLogin(container, onReadyOnce) {
  let done = false;
  const onReady = (session) => { if (!done) { done = true; onReadyOnce(session); } };
  const { data } = await sb.auth.getSession();
  if (data.session) return onReady(data.session);
  container.innerHTML = `
    <h2>Entrar</h2>
    <p>Digite seu e-mail. Enviaremos um código de acesso.</p>
    <form id="f-email"><label>E-mail<input type="email" name="email" required autocomplete="email"></label>
      <button>Receber código</button></form>
    <form id="f-code" hidden><label>Código recebido<input name="code" inputmode="numeric" required
      autocomplete="one-time-code"></label><button>Entrar</button></form>
    <p class="msg" id="login-msg"></p>`;
  let email = "";
  container.querySelector("#f-email").onsubmit = async (ev) => {
    ev.preventDefault();
    email = ev.target.email.value.trim();
    const { error } = await sb.auth.signInWithOtp({ email, options: { emailRedirectTo: location.href } });
    container.querySelector("#login-msg").textContent = error ? errorText(error)
      : "Código enviado. Confira seu e-mail (também serve clicar no link).";
    if (!error) show(container.querySelector("#f-code"));
  };
  container.querySelector("#f-code").onsubmit = async (ev) => {
    ev.preventDefault();
    const { data: d, error } = await sb.auth.verifyOtp({ email, token: ev.target.code.value.trim(), type: "email" });
    if (error) container.querySelector("#login-msg").textContent = errorText(error);
    else onReady(d.session);
  };
  sb.auth.onAuthStateChange((_e, session) => { if (session) onReady(session); });
}

export function esc(s) {
  return String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);
}
