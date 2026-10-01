// Testes do e-mail de código de acesso (rodar: node --experimental-strip-types --test tests/)
import { test } from "node:test";
import assert from "node:assert/strict";
import { loginEmail, normalizeEmail } from "../supabase/functions/_shared/login_email.ts";

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
