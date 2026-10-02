// Testes do e-mail de código de acesso (rodar: node --experimental-strip-types --test tests/)
import { test } from "node:test";
import assert from "node:assert/strict";
import { loginEmail, loginSms, normalizeEmail, normalizeLoginPhone, phoneLoginEmail } from "../supabase/functions/_shared/login_email.ts";

test("normaliza e valida e-mail", () => {
  assert.equal(normalizeEmail("  Fulano@Exemplo.com.br "), "fulano@exemplo.com.br");
  for (const bad of ["", "sem-arroba", "a@b", "a b@c.com", 123, null]) assert.equal(normalizeEmail(bad), null);
});

test("e-mail traz o código em português e só dígitos", () => {
  const m = loginEmail("123456", "https://beeguard.com.br");
  assert.equal(m.subject, "123456 é o seu código de acesso Bee Guard");
  assert.match(m.text, /código de acesso ao Bee Guard é: 123456/);
  assert.match(m.html, /123456/);
  assert.match(m.html, /https:\/\/beeguard\.com\.br\/icone\.png/);
  assert.match(m.html, /wa\.me\/5541996767045/);
  assert.match(m.text, /\(41\) 99676-7045/);
  assert.doesNotMatch(loginEmail("12<b>34", "x").html, /<b>34/);
});

test("login pelo celular: número, conta interna e SMS do código", () => {
  assert.equal(normalizeLoginPhone("(41) 99676-7045"), "+5541996767045");
  assert.equal(normalizeLoginPhone("+55 41 99676-7045"), "+5541996767045");
  assert.equal(normalizeLoginPhone("041996767045"), "+5541996767045");
  for (const bad of ["", "12345", "99676-7045", 41996767045, null]) assert.equal(normalizeLoginPhone(bad), null);
  assert.equal(phoneLoginEmail("+5541996767045"), "p5541996767045@telefone.beeguard.com.br");
  const sms = loginSms("123456");
  assert.equal(sms, "BEE GUARD: seu codigo de acesso e 123456. Nao compartilhe este codigo. Suporte: (41) 99676-7045");
  assert.ok(sms.length <= 160, "cabe em 1 SMS");
});
